const std = @import("std");

pub const Token = struct { path: []const u8, line: u32 = 1 };

/// One screen grapheme: its first column, cell width and text ("" or " " is blank).
pub const Gr = struct { col: u16, width: u16, text: []const u8 };

/// A file token on one screen row; `x1` is the last covered column.
pub const Found = struct { x0: u16, x1: u16, token: Token };

fn isLead(c: u8) bool {
    return switch (c) {
        '(', '[', '<', '"', '\'', '`' => true,
        else => false,
    };
}

fn isTrail(c: u8) bool {
    return switch (c) {
        ')', ']', '>', '"', '\'', '`', ',', ';', '.', ':', '!', '?' => true,
        else => false,
    };
}

fn blank(g: Gr) bool {
    return g.text.len == 0 or (g.text.len == 1 and g.text[0] == ' ');
}

fn single(g: Gr, comptime f: fn (u8) bool) bool {
    return g.text.len == 1 and f(g.text[0]);
}

/// `path`, `path:line` or `path:line:col`; the column is ignored.
pub fn parseToken(text: []const u8) ?Token {
    var path = text;
    var nums: [2]u32 = undefined;
    var n: usize = 0;
    while (n < 2) {
        const i = std.mem.lastIndexOfScalar(u8, path, ':') orelse break;
        const tail = path[i + 1 ..];
        if (tail.len == 0 or tail.len > 9 or std.mem.indexOfNone(u8, tail, "0123456789") != null) break;
        nums[n] = std.fmt.parseInt(u32, tail, 10) catch break;
        n += 1;
        path = path[0..i];
    }
    if (path.len == 0 or path.len > 1024 or std.mem.indexOf(u8, path, "://") != null) return null;
    for (path) |c| if (c < 0x20 or c == 0x7f) return null;
    return .{ .path = path, .line = if (n == 0) 1 else @max(1, nums[n - 1]) };
}

fn word(grs: []const Gr, col: u16) ?[2]usize {
    const at = for (grs, 0..) |g, i| {
        if (col >= g.col and col < g.col + @max(1, g.width)) break i;
    } else return null;
    if (blank(grs[at])) return null;
    var lo = at;
    while (lo > 0 and !blank(grs[lo - 1])) lo -= 1;
    var hi = at + 1;
    while (hi < grs.len and !blank(grs[hi])) hi += 1;
    return .{ lo, hi };
}

fn build(grs: []const Gr, lo_in: usize, hi_in: usize, out: []u8) ?Found {
    var lo = lo_in;
    var hi = hi_in;
    while (lo < hi and single(grs[lo], isLead)) lo += 1;
    while (hi > lo and single(grs[hi - 1], isTrail)) hi -= 1;
    if (lo == hi) return null;
    var len: usize = 0;
    for (grs[lo..hi]) |g| {
        if (len + g.text.len > out.len) return null;
        @memcpy(out[len..][0..g.text.len], g.text);
        len += g.text.len;
    }
    const token = parseToken(out[0..len]) orelse return null;
    return .{ .x0 = grs[lo].col, .x1 = grs[hi - 1].col + @max(1, grs[hi - 1].width) - 1, .token = token };
}

/// The file-like word under `col` in prose; `out` backs the token's path.
pub fn tokenAt(grs: []const Gr, col: u16, out: []u8) ?Found {
    const range = word(grs, col) orelse return null;
    return build(grs, range[0], range[1], out);
}

fn isCount(w: []const u8) bool {
    const digits = if (std.mem.startsWith(u8, w, "+")) w[1..] else if (std.mem.startsWith(u8, w, "−")) w["−".len..] else return false;
    return digits.len > 0 and std.mem.indexOfNone(u8, digits, "0123456789") == null;
}

/// True for `[(new)] +N [−M]` or `[(new)] −M`: what follows a path on a changes row.
pub fn countsOnly(rest: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, rest, ' ');
    var n: usize = 0;
    while (words.next()) |w| : (n += 1) {
        if (n == 0 and std.mem.eql(u8, w, "(new)")) continue;
        if (!isCount(w)) return false;
    }
    return n > 0;
}

/// The path starting a changes row (`  src/a.zig  +3 −1`); null when the row has another shape.
pub fn changeRowAt(grs: []const Gr, col: u16, out: []u8) ?Found {
    const range = word(grs, col) orelse return null;
    for (grs[0..range[0]]) |g| if (!blank(g)) return null;
    const found = build(grs, range[0], range[1], out) orelse return null;
    var rest: [128]u8 = undefined;
    var len: usize = 0;
    for (grs[range[1]..]) |g| {
        const text = if (g.text.len == 0) " " else g.text;
        if (len + text.len > rest.len) return null;
        @memcpy(rest[len..][0..text.len], text);
        len += text.len;
    }
    if (!countsOnly(rest[0..len])) return null;
    return found;
}

/// Splits on whitespace into an argv (no shell); `{path}` and `{line}` are substituted in every word.
pub fn argv(a: std.mem.Allocator, template: []const u8, path: []const u8, line: u32) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var number: [16]u8 = undefined;
    const line_text = std.fmt.bufPrint(&number, "{d}", .{line}) catch unreachable;
    var words = std.mem.tokenizeAny(u8, template, " \t");
    while (words.next()) |w| {
        const with_path = try std.mem.replaceOwned(u8, a, w, "{path}", path);
        try out.append(a, try std.mem.replaceOwned(u8, a, with_path, "{line}", line_text));
    }
    if (out.items.len == 0) return error.EmptyTemplate;
    return out.items;
}

/// Absolute path of `path` (relative to `cwd`) when it lies inside `project`; lexical, no filesystem access.
pub fn resolve(a: std.mem.Allocator, cwd: []const u8, project: []const u8, path: []const u8) !?[]u8 {
    const full = try std.fs.path.resolve(a, &.{ cwd, path });
    const inside = std.mem.startsWith(u8, full, project) and full.len > project.len and (full[project.len] == '/' or project[project.len -| 1] == '/');
    if (!inside) {
        a.free(full);
        return null;
    }
    return full;
}

/// Existence of candidate files, so drawing and hovering never repeat filesystem work.
pub const Files = struct {
    cache: std.StringHashMapUnmanaged(bool) = .empty,

    const max_entries = 4096;

    pub fn deinit(f: *Files, gpa: std.mem.Allocator) void {
        f.clear(gpa);
        f.cache.deinit(gpa);
    }

    pub fn clear(f: *Files, gpa: std.mem.Allocator) void {
        var keys = f.cache.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        f.cache.clearRetainingCapacity();
    }

    /// The absolute path when `path` is an existing regular file inside `project`.
    pub fn find(f: *Files, gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, project: []const u8, path: []const u8, out: []u8) ?[]const u8 {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const full = (resolve(arena.allocator(), cwd, project, path) catch return null) orelse return null;
        if (full.len > out.len) return null;
        const ok = f.cache.get(full) orelse blk: {
            const stat = std.Io.Dir.cwd().statFile(io, full, .{}) catch null;
            const is_file = if (stat) |s| s.kind == .file else false;
            if (f.cache.count() >= max_entries) f.clear(gpa);
            const key = gpa.dupe(u8, full) catch return null;
            f.cache.put(gpa, key, is_file) catch {
                gpa.free(key);
                return null;
            };
            break :blk is_file;
        };
        if (!ok) return null;
        @memcpy(out[0..full.len], full);
        return out[0..full.len];
    }
};

/// Starts the command detached from the terminal and reaps it on a helper thread.
pub fn launch(io: std.Io, env: *const std.process.Environ.Map, command: []const []const u8) !void {
    const child = try std.process.spawn(io, .{ .argv = command, .environ_map = env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const thread = std.Thread.spawn(.{}, reap, .{ io, child }) catch return;
    thread.detach();
}

fn reap(io: std.Io, child: std.process.Child) void {
    var c = child;
    _ = c.wait(io) catch {};
}

const testing = std.testing;

fn cells(buf: []Gr, text: []const u8) []const Gr {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepointSlice()) |cp| : (n += 1) buf[n] = .{ .col = @intCast(n), .width = 1, .text = cp };
    return buf[0..n];
}

test "token detection strips punctuation and reads :line[:col]" {
    var grs: [96]Gr = undefined;
    var out: [128]u8 = undefined;
    const row = cells(&grs, "see (src/tui.zig:42:7), then `a.zig`.");
    const first = tokenAt(row, 8, &out).?;
    try testing.expectEqualStrings("src/tui.zig", first.token.path);
    try testing.expectEqual(@as(u32, 42), first.token.line);
    try testing.expectEqual(@as(u16, 5), first.x0);
    try testing.expectEqual(@as(u16, 20), first.x1);
    const second = tokenAt(row, 31, &out).?;
    try testing.expectEqualStrings("a.zig", second.token.path);
    try testing.expectEqual(@as(u32, 1), second.token.line);
    try testing.expect(tokenAt(row, 3, &out) == null);
    try testing.expect(tokenAt(row, 4, &out) != null);
    try testing.expect(tokenAt(cells(&grs, "go to https://example.com/a.zig now"), 12, &out) == null);
    try testing.expectEqualStrings("a.zig", parseToken("a.zig:0").?.path);
    try testing.expectEqual(@as(u32, 1), parseToken("a.zig:0").?.line);
    try testing.expect(parseToken(":12") == null);
}

test "changes rows accept only a leading path followed by counts" {
    var grs: [96]Gr = undefined;
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings("src/a.zig", changeRowAt(cells(&grs, "  src/a.zig       +30 −4"), 5, &out).?.token.path);
    try testing.expectEqualStrings("b.zig", changeRowAt(cells(&grs, "  b.zig (new) +3 −0"), 3, &out).?.token.path);
    try testing.expectEqualStrings("c.zig", changeRowAt(cells(&grs, "c.zig         −5"), 0, &out).?.token.path);
    try testing.expect(changeRowAt(cells(&grs, "  src/a.zig is changed"), 5, &out) == null);
    try testing.expect(changeRowAt(cells(&grs, "  see src/a.zig +3"), 8, &out) == null);
    try testing.expect(changeRowAt(cells(&grs, "  src/a.zig"), 5, &out) == null);
}

test "open template splits without a shell and substitutes path and line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const words = try argv(a, "zed  {path}:{line}", "/p/my file.zig", 12);
    try testing.expectEqual(@as(usize, 2), words.len);
    try testing.expectEqualStrings("zed", words[0]);
    try testing.expectEqualStrings("/p/my file.zig:12", words[1]);
    const plain = try argv(a, "code --goto {path}:{line}:1", "/p/a", 1);
    try testing.expectEqualStrings("/p/a:1:1", plain[2]);
    try testing.expectError(error.EmptyTemplate, argv(a, "  ", "/p", 1));
}

test "only existing regular files inside the project resolve, once per path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "project/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project/src/a.zig", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "x" });
    const base = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ try std.process.currentPathAlloc(testing.io, a), tmp.sub_path });
    const project = try std.fmt.allocPrint(a, "{s}/project", .{base});
    const cwd = try std.fmt.allocPrint(a, "{s}/src", .{project});
    var files: Files = .{};
    defer files.deinit(testing.allocator);
    var out: [1024]u8 = undefined;
    const expected = try std.fmt.allocPrint(a, "{s}/src/a.zig", .{project});
    try testing.expectEqualStrings(expected, files.find(testing.allocator, testing.io, cwd, project, "a.zig", &out).?);
    try testing.expectEqualStrings(expected, files.find(testing.allocator, testing.io, cwd, project, "../src/a.zig", &out).?);
    try testing.expectEqualStrings(expected, files.find(testing.allocator, testing.io, cwd, project, expected, &out).?);
    try testing.expect(files.find(testing.allocator, testing.io, cwd, project, "missing.zig", &out) == null);
    try testing.expect(files.find(testing.allocator, testing.io, cwd, project, "..", &out) == null);
    try testing.expect(files.find(testing.allocator, testing.io, cwd, project, "../../outside.txt", &out) == null);
    try testing.expect(files.cache.count() >= 2);
    try testing.expect(files.find(testing.allocator, testing.io, cwd, project, "a.zig", &out) != null);
}
