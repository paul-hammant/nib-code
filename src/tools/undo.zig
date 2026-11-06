const std = @import("std");
const Tools = @import("../tools.zig").Tools;
const atomic = @import("atomic_file.zig");
const file_state = @import("file_state.zig");

pub const file_limit = 16 * 1024 * 1024;
pub const turn_limit = 64 * 1024 * 1024;
pub const path_limit = 256;
pub const history_limit = 8;

const Entry = struct {
    path: []const u8,
    created: bool,
    hash: [32]u8,
    pending: bool = true,
    tainted: bool = false,
    undone: bool = false,
};

fn hash(data: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &result, .{});
    return result;
}

pub const Write = struct {
    lock: std.Io.File,
    metadata: []const u8,
    snapshot: []const u8,
    entry: Entry,
    previous: ?Entry,
    written: bool = false,

    pub fn deinit(w: *Write, t: *Tools, gpa: std.mem.Allocator) void {
        const protection = t.io.swapCancelProtection(.blocked);
        defer _ = t.io.swapCancelProtection(protection);
        if (!w.written) {
            if (w.previous) |entry| {
                save(t.io, gpa, w.metadata, entry) catch {};
            } else {
                std.Io.Dir.cwd().deleteFile(t.io, w.metadata) catch {};
                std.Io.Dir.cwd().deleteFile(t.io, w.snapshot) catch {};
            }
        }
        gpa.free(w.entry.path);
        gpa.free(w.metadata);
        gpa.free(w.snapshot);
        w.lock.close(t.io);
    }

    pub fn commit(w: *Write, t: *Tools, gpa: std.mem.Allocator, after: []const u8) !void {
        w.written = true;
        const protection = t.io.swapCancelProtection(.blocked);
        defer _ = t.io.swapCancelProtection(protection);
        w.entry.hash = hash(after);
        w.entry.pending = false;
        try save(t.io, gpa, w.metadata, w.entry);
    }
};

fn save(io: std.Io, gpa: std.mem.Allocator, path: []const u8, entry: Entry) !void {
    const data = try std.json.Stringify.valueAlloc(gpa, entry, .{});
    defer gpa.free(data);
    _ = try atomic.replace(io, gpa, path, data, .{ .permissions = .fromMode(0o600) });
}

pub fn prepare(t: *Tools, gpa: std.mem.Allocator, path: []const u8, before: ?[]const u8, after: []const u8) !?Write {
    const directory = t.undo_dir orelse return null;
    if (before != null and std.mem.eql(u8, before.?, after)) return null;
    if (after.len > file_limit or (before != null and before.?.len > file_limit)) return error.UndoFileTooLarge;
    const lock = try file_state.lock(t, gpa, directory);
    errdefer lock.close(t.io);
    const key = std.fmt.bytesToHex(hash(path), .lower);
    const metadata = try std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ directory, key });
    errdefer gpa.free(metadata);
    const snapshot = try std.fmt.allocPrint(gpa, "{s}/{s}.before", .{ directory, key });
    errdefer gpa.free(snapshot);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = std.Io.Dir.cwd();
    const old = dir.readFileAlloc(t.io, metadata, a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const previous = if (old) |data| try std.json.parseFromSliceLeaky(Entry, a, data, .{}) else null;
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    var entry: Entry = previous orelse .{ .path = path, .created = before == null, .hash = hash(before orelse "") };
    entry.path = owned_path;
    errdefer if (previous == null) {
        dir.deleteFile(t.io, metadata) catch {};
        dir.deleteFile(t.io, snapshot) catch {};
    };
    if (old == null) {
        const folder = try dir.openDir(t.io, directory, .{ .iterate = true });
        defer folder.close(t.io);
        var it = folder.iterate();
        var total: u64 = 0;
        var paths: usize = 0;
        while (try it.next(t.io)) |item| {
            if (std.mem.endsWith(u8, item.name, ".json")) paths += 1;
            if (std.mem.endsWith(u8, item.name, ".before")) total += (try folder.statFile(t.io, item.name, .{})).size;
        }
        if (paths >= path_limit or total + (if (before) |data| data.len else @as(usize, 0)) > turn_limit) return error.UndoTurnLimit;
        if (before) |data| _ = try atomic.replace(t.io, gpa, snapshot, data, .{ .permissions = .fromMode(0o600) });
    } else if (before == null or !std.mem.eql(u8, &entry.hash, &hash(before.?))) {
        entry.tainted = true;
    }
    entry.pending = true;
    try save(t.io, gpa, metadata, entry);
    var saved = previous;
    if (saved) |*value| value.path = owned_path;
    return .{ .lock = lock, .metadata = metadata, .snapshot = snapshot, .entry = entry, .previous = saved };
}

pub const History = struct {
    root: ?[]const u8 = null,
    turns: std.ArrayList([]const u8) = .empty,

    pub fn begin(h: *History, t: *Tools, gpa: std.mem.Allocator) !void {
        const root = h.root orelse return;
        var random: [16]u8 = undefined;
        t.io.random(&random);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, std.fmt.bytesToHex(random, .lower) });
        errdefer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(t.io, path);
        try h.turns.append(gpa, path);
        t.undo_dir = path;
    }

    pub fn finish(h: *History, t: *Tools, gpa: std.mem.Allocator) void {
        if (h.root == null) return;
        t.undo_dir = null;
        if (h.turns.items.len == 0) return;
        const path = h.turns.items[h.turns.items.len - 1];
        const dir = std.Io.Dir.cwd().openDir(t.io, path, .{ .iterate = true }) catch return;
        defer dir.close(t.io);
        var it = dir.iterate();
        if ((it.next(t.io) catch return) != null) {
            if (h.turns.items.len > history_limit) {
                const oldest = h.turns.orderedRemove(0);
                std.Io.Dir.cwd().deleteTree(t.io, oldest) catch {};
                gpa.free(oldest);
            }
            return;
        }
        _ = h.turns.pop();
        std.Io.Dir.cwd().deleteTree(t.io, path) catch {};
        gpa.free(path);
    }

    pub fn deinit(h: *History, io: std.Io, gpa: std.mem.Allocator) void {
        if (h.root) |root| std.Io.Dir.cwd().deleteTree(io, root) catch {};
        for (h.turns.items) |path| gpa.free(path);
        h.turns.deinit(gpa);
    }

    pub fn undo(h: *History, t: *Tools, gpa: std.mem.Allocator) ![]u8 {
        if (h.turns.items.len == 0) return gpa.dupe(u8, "Nothing to undo in this process. Restored sessions cannot undo earlier Turns.");
        const path = h.turns.items[h.turns.items.len - 1];
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const folder = try std.Io.Dir.cwd().openDir(t.io, path, .{ .iterate = true });
        defer folder.close(t.io);
        const Item = struct {
            entry: Entry,
            metadata: []const u8,
            before: ?[]const u8,
            lock: ?std.Io.File = null,

            fn lessThan(_: void, left: @This(), right: @This()) bool {
                return std.mem.lessThan(u8, left.entry.path, right.entry.path);
            }
        };
        var items: std.ArrayList(Item) = .empty;
        defer for (items.items) |item| {
            if (item.lock) |lock| lock.close(t.io);
        };
        var report: std.ArrayList(u8) = .empty;
        errdefer report.deinit(gpa);
        var conflicts: std.ArrayList(u8) = .empty;
        defer conflicts.deinit(gpa);
        var it = folder.iterate();
        while (try it.next(t.io)) |file| {
            if (!std.mem.endsWith(u8, file.name, ".json")) continue;
            const data = try folder.readFileAlloc(t.io, file.name, a, .limited(64 * 1024));
            const entry = try std.json.parseFromSliceLeaky(Entry, a, data, .{});
            if (entry.undone) continue;
            const before = if (entry.created) null else try folder.readFileAlloc(t.io, try std.fmt.allocPrint(a, "{s}.before", .{file.name[0 .. file.name.len - 5]}), a, .limited(file_limit + 1));
            try items.append(a, .{ .entry = entry, .metadata = try std.fs.path.join(a, &.{ path, file.name }), .before = before });
        }
        std.mem.sort(Item, items.items, {}, Item.lessThan);
        for (items.items) |*item| {
            const entry = item.entry;
            item.lock = try file_state.lock(t, a, entry.path);
            const canonical = atomic.canonicalPath(t.io, a, entry.path) catch "";
            const stat = std.Io.Dir.cwd().statFile(t.io, entry.path, .{ .follow_symlinks = false }) catch null;
            const current = if (stat != null and stat.?.kind == .file) std.Io.Dir.cwd().readFileAlloc(t.io, entry.path, gpa, .limited(file_limit + 1)) catch null else null;
            defer if (current) |bytes| gpa.free(bytes);
            const conflict = entry.pending or entry.tainted or !std.mem.eql(u8, canonical, entry.path) or current == null or !std.mem.eql(u8, &entry.hash, &hash(current.?));
            if (conflict) try conflicts.print(gpa, "\nskipped (external change or incomplete snapshot): {s}", .{entry.path});
        }
        if (conflicts.items.len > 0) {
            try report.print(gpa, "Undo refused; no files changed. Resolve conflicts before retrying.{s}", .{conflicts.items});
            return report.toOwnedSlice(gpa);
        }
        try report.appendSlice(gpa, "[undo] Restoring files to their contents before the latest edited Turn. Re-read listed files before continuing.");
        for (items.items) |*item| {
            const entry = &item.entry;
            var restored_stat: ?std.Io.File.Stat = null;
            if (item.before) |before| {
                restored_stat = atomic.replace(t.io, gpa, entry.path, before, .{}) catch |err| {
                    try report.print(gpa, "\nfailed: {s}: {s} (retry /undo)", .{ entry.path, @errorName(err) });
                    return report.toOwnedSlice(gpa);
                };
            } else std.Io.Dir.cwd().deleteFile(t.io, entry.path) catch |err| {
                try report.print(gpa, "\nfailed: {s}: {s} (retry /undo)", .{ entry.path, @errorName(err) });
                return report.toOwnedSlice(gpa);
            };
            entry.undone = true;
            t.bash_commands.changed(t.io);
            try report.print(gpa, "\n{s}: {s}", .{ if (entry.created) "deleted" else "restored", entry.path });
            if (restored_stat) |stat| t.file_state.remember(t.io, gpa, entry.path, stat) catch |err| {
                try report.print(gpa, "\nfile observation failed: {s}; re-read files before continuing", .{@errorName(err)});
                return report.toOwnedSlice(gpa);
            };
            save(t.io, gpa, item.metadata, entry.*) catch |err| {
                try report.print(gpa, "\nundo tracking failed: {s}; inspect files before retrying", .{@errorName(err)});
                return report.toOwnedSlice(gpa);
            };
        }
        _ = h.turns.pop();
        std.Io.Dir.cwd().deleteTree(t.io, path) catch {};
        gpa.free(path);
        return report.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    tools: Tools,
    history: History,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        const root = try std.fs.path.join(a, &.{ home, "undo" });
        try std.Io.Dir.cwd().createDirPath(testing.io, root);
        return .{ .tmp = tmp, .arena = arena, .tools = .{ .io = testing.io, .home = home, .data_home = home }, .history = .{ .root = root } };
    }

    fn deinit(f: *Fixture) void {
        f.history.deinit(testing.io, testing.allocator);
        f.tools.file_state.deinit(testing.allocator);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn path(f: *Fixture, name: []const u8) ![]const u8 {
        return atomic.canonicalPath(testing.io, f.arena.allocator(), try std.fs.path.join(f.arena.allocator(), &.{ f.tools.home, name }));
    }

    fn call(f: *Fixture, name: []const u8, args: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(testing.allocator, args, .{});
        defer testing.allocator.free(json);
        const result = Tools.call(&f.tools, testing.allocator, name, json);
        defer @import("../tools.zig").freeResult(result);
        if (result == .err) std.debug.print("{s}\n", .{result.err});
        try testing.expect(result == .ok);
    }

    fn begin(f: *Fixture) !void {
        try f.history.begin(&f.tools, testing.allocator);
    }

    fn finish(f: *Fixture) void {
        f.history.finish(&f.tools, testing.allocator);
    }

    fn undo(f: *Fixture, expected: []const u8) !void {
        const text = try f.history.undo(&f.tools, testing.allocator);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, expected) != null);
    }

    fn content(f: *Fixture, name: []const u8, expected: []const u8) !void {
        const data = try f.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(file_limit + 1));
        defer testing.allocator.free(data);
        try testing.expectEqualSlices(u8, expected, data);
    }
};

test "undo multiple files, first snapshot, binary Chinese paths, creation and consecutive Turns" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "中文", .data = "\x00\xffold\n" });
    const path = try f.path("中文");
    const created = try f.path("new");
    try f.begin();
    try f.call("edit", .{ .path = path, .old_text = "old", .new_text = "new" });
    try f.call("write", .{ .path = path, .content = "first" });
    try f.call("write", .{ .path = created, .content = "" });
    f.finish();
    try f.begin();
    try f.call("write", .{ .path = path, .content = "second" });
    f.finish();
    try f.begin();
    f.finish();
    try f.undo("restored:");
    try f.content("中文", "first");
    try f.content("new", "");
    try f.undo("deleted:");
    try f.content("中文", "\x00\xffold\n");
    try testing.expectError(error.FileNotFound, f.tmp.dir.statFile(testing.io, "new", .{}));
    try f.undo("Nothing to undo");
}

test "undo rejects whole Turn on external edit, deletion, symlink or in-Turn interference" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "old" });
    const path = try f.path("a");
    const created = try f.path("b");
    try f.begin();
    try f.call("write", .{ .path = path, .content = "new" });
    try f.call("write", .{ .path = created, .content = "created" });
    f.finish();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "external" });
    try f.undo("skipped (external change");
    try f.content("a", "external");
    try f.content("b", "created");
    try f.tmp.dir.deleteFile(testing.io, "a");
    try f.undo("no files changed");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "victim", .data = "new" });
    try f.tmp.dir.symLink(testing.io, "victim", "a", .{});
    try f.undo("no files changed");
    try f.content("victim", "new");
    try f.tmp.dir.deleteFile(testing.io, "a");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "new" });
    try f.undo("restored:");
    try f.begin();
    try f.call("write", .{ .path = path, .content = "first" });
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "external" });
    try f.call("edit", .{ .path = path, .old_text = "external", .new_text = "last" });
    f.finish();
    try f.undo("no files changed");
    try f.content("a", "last");
}

test "undo shares parent snapshots with child tools and evicts only edited Turns" {
    var f = try Fixture.init();
    defer f.deinit();
    const path = try f.path("a");
    try f.begin();
    var child: Tools = .{ .io = testing.io, .home = f.tools.home, .data_home = f.tools.data_home, .undo_dir = f.tools.undo_dir };
    defer child.file_state.deinit(testing.allocator);
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = path, .content = "child" }, .{});
    defer testing.allocator.free(args);
    const result = Tools.call(&child, testing.allocator, "write", args);
    defer @import("../tools.zig").freeResult(result);
    try testing.expect(result == .ok);
    f.finish();
    try f.undo("deleted:");
    for (0..history_limit + 1) |i| {
        try f.begin();
        try f.call("write", .{ .path = path, .content = try std.fmt.allocPrint(f.arena.allocator(), "{d}", .{i}) });
        f.finish();
    }
    try testing.expectEqual(history_limit, f.history.turns.items.len);
    for (0..history_limit + 2) |_| {
        try f.begin();
        f.finish();
    }
    try testing.expectEqual(history_limit, f.history.turns.items.len);
    for (0..history_limit) |_| try f.undo("restored:");
    try f.content("a", "0");
    try f.undo("Nothing to undo");
}

test "undo snapshot limits reject before modifying files" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.begin();
    const large = try testing.allocator.alloc(u8, file_limit + 1);
    defer testing.allocator.free(large);
    @memset(large, 'x');
    const path = try f.path("a");
    try testing.expectError(error.UndoFileTooLarge, prepare(&f.tools, testing.allocator, path, null, large));
    const block = large[0..file_limit];
    for (0..4) |i| {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "file{d}", .{i});
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = block });
        try f.call("write", .{ .path = try f.path(name), .content = "small" });
    }
    try testing.expectError(error.UndoTurnLimit, prepare(&f.tools, testing.allocator, path, "x", "y"));
    try testing.expectError(error.FileNotFound, f.tmp.dir.statFile(testing.io, "a", .{}));
    f.finish();
    try f.undo("restored:");
    try f.content("file0", block);
    try f.begin();
    for (0..path_limit) |i| {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "new{d}", .{i});
        try f.call("write", .{ .path = try f.path(name), .content = "" });
    }
    try testing.expectError(error.UndoTurnLimit, prepare(&f.tools, testing.allocator, path, null, ""));
    f.finish();
    try f.undo("deleted:");
}

test "aborted file replacement preserves the prior undo record" {
    var f = try Fixture.init();
    defer f.deinit();
    const path = try f.path("a");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "old" });
    try f.begin();
    try f.call("write", .{ .path = path, .content = "first" });
    var abandoned = (try prepare(&f.tools, testing.allocator, path, "first", "unwritten")).?;
    abandoned.deinit(&f.tools, testing.allocator);
    const fresh_path = try f.path("unwritten");
    var fresh = (try prepare(&f.tools, testing.allocator, fresh_path, null, "unwritten")).?;
    fresh.deinit(&f.tools, testing.allocator);
    f.finish();
    try f.undo("restored:");
    try f.content("a", "old");
}
