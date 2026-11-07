const std = @import("std");
const walk = @import("../tools/walk.zig");

pub const max_entries = 50_000;
pub const max_hits = 8;
const refresh_ns = 5 * std.time.ns_per_s;

pub const Entry = struct { path: []const u8, dir: bool };

/// An `@` word ending at the cursor; `query` is the path typed so far, without quotes.
pub const Mention = struct { start: usize, query: []const u8 };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn boundaryBefore(text: []const u8, i: usize) bool {
    return i == 0 or isSpace(text[i - 1]);
}

/// `@` at the start of the text or after whitespace, with no whitespace between it and `cursor`
/// unless the path is quoted (`@"my file`).
pub fn mention(text: []const u8, cursor: usize) ?Mention {
    const before = text[0..cursor];
    if (std.mem.lastIndexOf(u8, before, "@\"")) |q| {
        if (boundaryBefore(text, q) and std.mem.indexOfScalar(u8, before[q + 2 ..], '"') == null and std.mem.indexOfScalar(u8, before[q + 2 ..], '\n') == null)
            return .{ .start = q, .query = before[q + 2 ..] };
    }
    var w = cursor;
    while (w > 0 and !isSpace(text[w - 1])) w -= 1;
    if (w == cursor or text[w] != '@') return null;
    return .{ .start = w, .query = before[w + 1 ..] };
}

/// The text accepting `path` leaves behind: directories keep completing, files end with a space.
pub fn insertion(a: std.mem.Allocator, path: []const u8, dir: bool) ![]u8 {
    const quoted = std.mem.indexOfAny(u8, path, " \t") != null;
    return std.fmt.allocPrint(a, "@{s}{s}{s}{s}", .{
        if (quoted) "\"" else "",
        path,
        if (dir) "/" else "",
        if (dir) "" else if (quoted) "\" " else " ",
    });
}

pub const Hit = struct { index: usize, tier: u8, len: usize };

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    if (prefix.len > s.len) return false;
    for (prefix, s[0..prefix.len]) |p, c| if (lower(p) != lower(c)) return false;
    return true;
}

fn subsequenceFold(s: []const u8, query: []const u8) bool {
    var q: usize = 0;
    for (s) |c| {
        if (q < query.len and lower(c) == lower(query[q])) q += 1;
    }
    return q == query.len;
}

fn tier(e: Entry, query: []const u8) ?u8 {
    if (query.len == 0) return 0;
    const base = std.fs.path.basename(e.path);
    if (startsWithFold(base, query)) return 0;
    if (startsWithFold(e.path, query)) return 1;
    if (subsequenceFold(e.path, query)) return 2;
    return null;
}

fn better(a: Hit, b: Hit, entries: []const Entry) bool {
    if (a.tier != b.tier) return a.tier < b.tier;
    if (a.len != b.len) return a.len < b.len;
    return std.mem.lessThan(u8, entries[a.index].path, entries[b.index].path);
}

/// The best matches of `query` among `entries`, best first.
pub fn top(entries: []const Entry, query: []const u8, out: *[max_hits]Hit) []Hit {
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        const t = tier(e, query) orelse continue;
        const hit: Hit = .{ .index = i, .tier = t, .len = e.path.len };
        var at = n;
        while (at > 0 and better(hit, out[at - 1], entries)) at -= 1;
        if (at >= max_hits) continue;
        if (n < max_hits) n += 1;
        var j = n - 1;
        while (j > at) : (j -= 1) out[j] = out[j - 1];
        out[at] = hit;
    }
    return out[0..n];
}

const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
};

/// Project paths below the working directory, listed on a background thread.
/// Must not move once `start` has run.
pub const Index = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    snapshot: ?*Snapshot = null,
    generation: u64 = 0,
    built_ns: ?i96 = null,
    building: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    wake: ?Wake = null,

    pub const Wake = struct {
        ctx: *anyopaque,
        call: *const fn (*anyopaque) void,
    };

    const Job = struct {
        index: *Index,
        arena: std.heap.ArenaAllocator,
        deny: []const []const u8,
    };

    pub fn deinit(ix: *Index) void {
        ix.cancel.store(true, .release);
        if (ix.thread) |t| t.join();
        if (ix.snapshot) |s| {
            s.arena.deinit();
            ix.gpa.destroy(s);
        }
    }

    fn now(ix: *const Index) i96 {
        return std.Io.Clock.real.now(ix.io).nanoseconds;
    }

    /// Lists in the background when nothing was listed yet or the listing is a few seconds old.
    pub fn refresh(ix: *Index, deny_source: anytype) void {
        if (ix.building.load(.acquire)) return;
        if (ix.built_ns) |at| if (ix.now() - at < refresh_ns) return;
        if (ix.thread) |t| {
            t.join();
            ix.thread = null;
        }
        const job = ix.gpa.create(Job) catch return;
        job.* = .{ .index = ix, .arena = .init(ix.gpa), .deny = &.{} };
        job.deny = deny_source.credentialPaths(job.arena.allocator()) catch &.{};
        ix.building.store(true, .release);
        ix.thread = std.Thread.spawn(.{}, work, .{job}) catch {
            ix.building.store(false, .release);
            job.arena.deinit();
            ix.gpa.destroy(job);
            return;
        };
    }

    fn work(job: *Job) void {
        const ix = job.index;
        defer {
            const gpa = ix.gpa;
            job.arena.deinit();
            gpa.destroy(job);
        }
        defer ix.building.store(false, .release);
        const found = walk.files(ix.io, job.arena.allocator(), ".", .{
            .deny = job.deny,
            .cancel = &ix.cancel,
            .max = max_entries,
            .dirs = true,
        }) catch return;
        const snap = ix.gpa.create(Snapshot) catch return;
        snap.arena = .init(ix.gpa);
        const kept = @min(found.len, max_entries);
        const entries = snap.arena.allocator().alloc(Entry, kept) catch {
            snap.arena.deinit();
            ix.gpa.destroy(snap);
            return;
        };
        for (found[0..kept], entries) |f, *e| {
            e.* = .{ .path = snap.arena.allocator().dupe(u8, f.path) catch {
                snap.arena.deinit();
                ix.gpa.destroy(snap);
                return;
            }, .dir = f.dir };
        }
        snap.entries = entries;
        ix.publish(snap);
        if (ix.wake) |w| w.call(w.ctx);
    }

    pub fn publish(ix: *Index, snap: *Snapshot) void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        if (ix.snapshot) |old| {
            old.arena.deinit();
            ix.gpa.destroy(old);
        }
        ix.snapshot = snap;
        ix.generation += 1;
        ix.built_ns = ix.now();
    }

    /// Replaces the listing; for tests.
    pub fn setEntries(ix: *Index, paths: []const []const u8) !void {
        const snap = try ix.gpa.create(Snapshot);
        snap.arena = .init(ix.gpa);
        const a = snap.arena.allocator();
        const entries = try a.alloc(Entry, paths.len);
        for (paths, entries) |p, *e| {
            const dir = std.mem.endsWith(u8, p, "/");
            e.* = .{ .path = try a.dupe(u8, if (dir) p[0 .. p.len - 1] else p), .dir = dir };
        }
        snap.entries = entries;
        ix.publish(snap);
    }

    /// Calls `f(entries)` with the listing locked, or with nothing before the first listing.
    pub fn withEntries(ix: *Index, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const Entry) void) void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        f(ctx, if (ix.snapshot) |s| s.entries else &.{});
    }
};

const testing = std.testing;

fn expectMention(text: []const u8, cursor: usize, start: ?usize, query: []const u8) !void {
    const m = mention(text, cursor);
    if (start) |s| {
        try testing.expectEqual(s, m.?.start);
        try testing.expectEqualStrings(query, m.?.query);
    } else try testing.expect(m == null);
}

test "mention triggers at the start and after whitespace but not inside words" {
    try expectMention("@sr", 3, 0, "sr");
    try expectMention("@", 1, 0, "");
    try expectMention("look at @src/ma", 15, 8, "src/ma");
    try expectMention("a\n@x", 4, 2, "x");
    try expectMention("mail a@b.com", 12, null, "");
    try expectMention("a@b", 3, null, "");
    try expectMention("@sr and more", 12, null, "");
    try expectMention("hello ", 6, null, "");
    try expectMention("@src/ done", 5, 0, "src/");
}

test "quoted mentions span spaces until the closing quote" {
    try expectMention("see @\"my dir/fi", 15, 4, "my dir/fi");
    try expectMention("see @\"my file.txt\" ok", 21, null, "");
    try expectMention("x@\"a b", 6, null, "");
}

test "insertion quotes paths with spaces and keeps directories open" {
    const a = testing.allocator;
    const file = try insertion(a, "src/main.zig", false);
    defer a.free(file);
    try testing.expectEqualStrings("@src/main.zig ", file);
    const dir = try insertion(a, "src", true);
    defer a.free(dir);
    try testing.expectEqualStrings("@src/", dir);
    const spaced = try insertion(a, "my file.txt", false);
    defer a.free(spaced);
    try testing.expectEqualStrings("@\"my file.txt\" ", spaced);
    const spaced_dir = try insertion(a, "my dir", true);
    defer a.free(spaced_dir);
    try testing.expectEqualStrings("@\"my dir/", spaced_dir);
    try testing.expectEqualStrings("my dir/", mention(spaced_dir, spaced_dir.len).?.query);
}

fn hitPaths(entries: []const Entry, query: []const u8, buf: *[max_hits][]const u8) [][]const u8 {
    var hits: [max_hits]Hit = undefined;
    const found = top(entries, query, &hits);
    for (found, 0..) |h, i| buf[i] = entries[h.index].path;
    return buf[0..found.len];
}

test "ranking: basename prefix, then path prefix, then subsequence, shorter first" {
    const entries = [_]Entry{
        .{ .path = "docs/session.md", .dir = false },
        .{ .path = "src/session.zig", .dir = false },
        .{ .path = "src", .dir = true },
        .{ .path = "session", .dir = true },
        .{ .path = "a/s/e/s/s/ion", .dir = false },
        .{ .path = "src/tools/search.zig", .dir = false },
    };
    var buf: [max_hits][]const u8 = undefined;
    const found = hitPaths(&entries, "ses", &buf);
    try testing.expectEqual(@as(usize, 4), found.len);
    try testing.expectEqualStrings("session", found[0]);
    try testing.expectEqualStrings("docs/session.md", found[1]);
    try testing.expectEqualStrings("src/session.zig", found[2]);
    try testing.expectEqualStrings("a/s/e/s/s/ion", found[3]);

    const by_path = hitPaths(&entries, "src/s", &buf);
    try testing.expectEqualStrings("src/session.zig", by_path[0]);
    try testing.expectEqualStrings("src/tools/search.zig", by_path[1]);
    try testing.expectEqual(@as(usize, 2), by_path.len);

    const inside = hitPaths(&entries, "src/", &buf);
    try testing.expectEqualStrings("src/session.zig", inside[0]);
    try testing.expectEqualStrings("src/tools/search.zig", inside[1]);

    const all = hitPaths(&entries, "", &buf);
    try testing.expectEqualStrings("src", all[0]);
    try testing.expectEqual(@as(usize, 6), all.len);
}

test "ranking keeps at most eight hits and ignores case" {
    var entries: [20]Entry = undefined;
    var names: [20][8]u8 = undefined;
    for (&entries, &names, 0..) |*e, *n, i| {
        const s = std.fmt.bufPrint(n, "File{d:0>2}", .{i}) catch unreachable;
        e.* = .{ .path = s, .dir = false };
    }
    var hits: [max_hits]Hit = undefined;
    const found = top(&entries, "file", &hits);
    try testing.expectEqual(@as(usize, max_hits), found.len);
    try testing.expectEqualStrings("File00", entries[found[0].index].path);
    try testing.expectEqualStrings("File07", entries[found[7].index].path);
}

test "index lists files and directories, skips ignored paths and .git" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src/inner");
    try tmp.dir.createDirPath(testing.io, "build");
    try tmp.dir.createDirPath(testing.io, ".git");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "build/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build/out", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".git/config", .data = "" });
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try walk.files(testing.io, arena.allocator(), root, .{ .dirs = true });
    var seen: std.ArrayList([]const u8) = .empty;
    for (found) |f| try seen.append(arena.allocator(), if (f.dir) try std.fmt.allocPrint(arena.allocator(), "{s}/", .{f.path}) else f.path);
    const expect = [_][]const u8{ ".gitignore", "src/", "src/inner/", "src/main.zig" };
    try testing.expectEqual(expect.len, seen.items.len);
    for (expect, seen.items) |want, got| try testing.expect(std.mem.endsWith(u8, got, want));
}
