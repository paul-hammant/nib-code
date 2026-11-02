const std = @import("std");
const walk = @import("walk.zig");
const regex = @import("regex.zig");

pub const Options = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    glob: ?[]const u8 = null,
    ignore_case: bool = false,
    literal: bool = false,
    context: usize = 0,
    limit: usize = 100,
};

pub const Match = struct {
    path: []const u8,
    line: usize,
    text: []const u8,
    before: ?[]const []const u8 = null,
    after: ?[]const []const u8 = null,
};

pub const Result = struct {
    matches: []const Match,
    /// More matches may exist beyond `limit`.
    truncated: bool,
};

const max_line = 500;
const max_file = 16 * 1024 * 1024;
const max_workers = 8;

/// Owns everything in `result`.
pub const Search = struct {
    arena: std.heap.ArenaAllocator,
    result: Result,

    pub fn deinit(s: *Search) void {
        s.arena.deinit();
    }
};

/// `message` receives the reason for error.InvalidPattern.
pub fn search(io: std.Io, gpa: std.mem.Allocator, options: Options, walk_options: walk.Options, message: *[128]u8) !Search {
    var s: Search = .{ .arena = .init(gpa), .result = undefined };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    var engine: regex.Engine = undefined;
    try engine.init(walk_options.cancel);
    defer engine.deinit();
    const source = try a.dupeSentinel(u8, if (options.literal) try escape(a, options.pattern) else options.pattern, 0);
    const compiled = try regex.Regex.compile(&engine, source, options.ignore_case, message);
    defer compiled.deinit(&engine);

    var walk_filtered = walk_options;
    walk_filtered.filter = options.glob;
    const files = try walk.files(io, a, options.path, walk_filtered);
    const limit = @max(options.limit, 1);
    var shared: Shared = .{
        .io = io,
        .gpa = gpa,
        .files = files,
        .slots = try a.alloc([]const Match, files.len),
        .regex = compiled,
        .needle = if (options.literal and !options.ignore_case) options.pattern else null,
        .context = options.context,
        .limit = limit,
        .cancel = walk_options.cancel,
    };
    @memset(shared.slots, &.{});

    const workers = @min(max_workers, files.len, std.Thread.getCpuCount() catch 1);
    var threads: [max_workers]?std.Thread = @splat(null);
    var arenas: [max_workers]std.heap.ArenaAllocator = undefined;
    for (arenas[0..@max(workers, 1)]) |*arena| arena.* = .init(gpa);
    defer for (arenas[0..@max(workers, 1)]) |*arena| arena.deinit();
    if (workers <= 1) {
        shared.work(&arenas[0], &engine);
    } else {
        for (threads[0..workers], arenas[0..workers]) |*thread, *arena|
            thread.* = std.Thread.spawn(.{}, Shared.workOwnEngine, .{ &shared, arena }) catch null;
        for (threads[0..workers]) |thread| if (thread) |t| t.join();
    }
    if (shared.failure) |err| return err;

    var matches: std.ArrayList(Match) = .empty;
    const processed = @min(shared.next.load(.acquire), files.len);
    for (shared.slots[0..processed]) |slot| {
        for (slot) |m| {
            if (matches.items.len == limit) break;
            try matches.append(a, try copyMatch(a, m));
        }
    }
    const found = shared.found.load(.acquire);
    s.result = .{ .matches = matches.items, .truncated = found > limit or (found >= limit and processed < files.len) };
    return s;
}

const Shared = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    files: []const walk.File,
    /// Indexed like `files`; each slot is written by the one worker that claimed the file.
    slots: [][]const Match,
    regex: regex.Regex,
    needle: ?[]const u8,
    context: usize,
    limit: usize,
    cancel: ?*const std.atomic.Value(bool),
    next: std.atomic.Value(usize) = .init(0),
    found: std.atomic.Value(usize) = .init(0),
    failure_mutex: std.Io.Mutex = .init,
    failure: ?anyerror = null,

    fn workOwnEngine(s: *Shared, arena: *std.heap.ArenaAllocator) void {
        var engine: regex.Engine = undefined;
        engine.init(s.cancel) catch |err| return s.fail(err);
        defer engine.deinit();
        s.work(arena, &engine);
    }

    /// Files are claimed in index order, so the claimed ones always form a prefix
    /// and the first `limit` matches are the same as in a sequential scan.
    fn work(s: *Shared, arena: *std.heap.ArenaAllocator, engine: *regex.Engine) void {
        const scratch = arena.allocator().alloc(?[*]u8, @max(s.regex.captures * 2, 2)) catch |err| return s.fail(err);
        while (s.found.load(.acquire) < s.limit) {
            if (s.cancel) |c| if (c.load(.acquire)) return s.fail(error.Canceled);
            const i = s.next.fetchAdd(1, .acq_rel);
            if (i >= s.files.len) return;
            const matches = s.scan(arena.allocator(), engine, s.files[i], scratch) catch |err| return s.fail(err);
            s.slots[i] = matches;
            _ = s.found.fetchAdd(matches.len, .acq_rel);
        }
    }

    fn fail(s: *Shared, err: anyerror) void {
        s.failure_mutex.lockUncancelable(s.io);
        defer s.failure_mutex.unlock(s.io);
        if (s.failure == null) s.failure = err;
        s.next.store(s.files.len, .release);
    }

    fn scan(s: *Shared, a: std.mem.Allocator, engine: *regex.Engine, file: walk.File, scratch: []?[*]u8) ![]const Match {
        const data = std.Io.Dir.cwd().readFileAlloc(s.io, file.absolute, s.gpa, .limited(max_file)) catch return &.{};
        defer s.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) return &.{};

        var lines: std.ArrayList(usize) = .empty;
        defer lines.deinit(s.gpa);
        if (s.needle) |needle| {
            try matchLines(u8, s.gpa, data, s.limit, &lines, Literal{ .needle = needle });
        } else if (isAscii(data) or !std.unicode.utf8ValidateSlice(data)) {
            try matchLines(u8, s.gpa, data, s.limit, &lines, Pattern(u8){ .regex = s.regex, .engine = engine, .scratch = scratch });
        } else {
            const wide = try std.unicode.utf8ToUtf16LeAlloc(s.gpa, data);
            defer s.gpa.free(wide);
            try matchLines(u16, s.gpa, wide, s.limit, &lines, Pattern(u16){ .regex = s.regex, .engine = engine, .scratch = scratch });
        }
        if (lines.items.len == 0) return &.{};

        var starts: std.ArrayList(usize) = .empty;
        defer starts.deinit(s.gpa);
        try starts.append(s.gpa, 0);
        for (data, 0..) |ch, i| if (ch == '\n') try starts.append(s.gpa, i + 1);
        const count = if (data.len > 0 and data[data.len - 1] == '\n') starts.items.len - 1 else starts.items.len;
        const lineText = struct {
            fn get(text: []const u8, st: []const usize, n: usize) []const u8 {
                const start = st[n - 1];
                const end = if (n < st.len) st[n] - 1 else text.len;
                return clip(std.mem.trimEnd(u8, text[start..end], "\r"));
            }
        }.get;

        const out = try a.alloc(Match, lines.items.len);
        for (lines.items, out) |n, *m| {
            m.* = .{ .path = file.path, .line = n, .text = try a.dupe(u8, lineText(data, starts.items, n)) };
            if (s.context == 0) continue;
            const first = if (n > s.context) n - s.context else 1;
            const last = @min(n + s.context, count);
            const before = try a.alloc([]const u8, n - first);
            for (before, first..) |*t, k| t.* = try a.dupe(u8, lineText(data, starts.items, k));
            const after = try a.alloc([]const u8, last - n);
            for (after, n + 1..) |*t, k| t.* = try a.dupe(u8, lineText(data, starts.items, k));
            m.before = before;
            m.after = after;
        }
        return out;
    }
};

const Literal = struct {
    needle: []const u8,
    fn find(l: Literal, comptime T: type, text: []const T, from: usize) !?usize {
        return std.mem.indexOfPos(T, text, from, l.needle);
    }
};

fn Pattern(comptime T: type) type {
    return struct {
        regex: regex.Regex,
        engine: *regex.Engine,
        scratch: []?[*]u8,
        fn find(p: @This(), comptime U: type, text: []const U, from: usize) !?usize {
            comptime std.debug.assert(U == T);
            return p.regex.find(p.engine, T, text, from, p.scratch);
        }
    };
}

/// 1-based numbers of lines where a match starts, at most `limit`.
fn matchLines(comptime T: type, gpa: std.mem.Allocator, text: []const T, limit: usize, out: *std.ArrayList(usize), finder: anytype) !void {
    var line: usize = 1;
    var counted: usize = 0;
    var from: usize = 0;
    while (out.items.len < limit) {
        const at = (try finder.find(T, text, from)) orelse return;
        line += std.mem.count(T, text[counted..at], &.{'\n'});
        try out.append(gpa, line);
        const nl = std.mem.indexOfScalarPos(T, text, at, '\n') orelse return;
        line += 1;
        counted = nl + 1;
        from = nl + 1;
        if (from >= text.len) return;
    }
}

fn isAscii(data: []const u8) bool {
    for (data) |ch| if (ch >= 0x80) return false;
    return true;
}

fn clip(line: []const u8) []const u8 {
    if (line.len <= max_line) return line;
    var end: usize = max_line;
    while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
    return line[0..end];
}

fn copyMatch(a: std.mem.Allocator, m: Match) !Match {
    var out: Match = .{ .path = m.path, .line = m.line, .text = try a.dupe(u8, m.text) };
    if (m.before) |lines| out.before = try copyLines(a, lines);
    if (m.after) |lines| out.after = try copyLines(a, lines);
    return out;
}

fn copyLines(a: std.mem.Allocator, lines: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, lines.len);
    for (lines, out) |l, *o| o.* = try a.dupe(u8, l);
    return out;
}

fn escape(a: std.mem.Allocator, literal: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (std.mem.indexOfScalar(u8, "\\^$.*+?()[]{}|/", ch) != null) try out.append(a, '\\');
        try out.append(a, ch);
    }
    return out.items;
}

const testing = std.testing;

fn fixture(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "out/\n" });
    try tmp.dir.createDirPath(io, "out");
    try tmp.dir.writeFile(io, .{ .sub_path = "out/gen.zig", .data = "fn hidden() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const a = 1;\nfn alpha() void {}\r\n// 注释 TODO 中文\nfn beta() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.py", .data = "def alpha():\n    pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin.dat", .data = "fn \x00 binary\n" });
}

fn run(root: []const u8, options: Options) !Search {
    var message: [128]u8 = undefined;
    var o = options;
    o.path = root;
    return search(testing.io, testing.allocator, o, .{}, &message);
}

test "grep finds regex matches in path order, skipping ignored and binary files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);

    var s = try run(root, .{ .pattern = "^(fn|def) \\w+" });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.result.matches.len);
    try testing.expect(std.mem.endsWith(u8, s.result.matches[0].path, "src/a.zig"));
    try testing.expectEqual(@as(usize, 2), s.result.matches[0].line);
    try testing.expectEqualStrings("fn alpha() void {}", s.result.matches[0].text);
    try testing.expectEqual(@as(usize, 4), s.result.matches[1].line);
    try testing.expect(std.mem.endsWith(u8, s.result.matches[2].path, "src/b.py"));
    try testing.expect(!s.result.truncated);

    var limited = try run(root, .{ .pattern = "alpha", .limit = 1, .glob = "*.zig" });
    defer limited.deinit();
    try testing.expectEqual(@as(usize, 1), limited.result.matches.len);
    try testing.expect(!limited.result.truncated);

    var capped = try run(root, .{ .pattern = "alpha", .limit = 1 });
    defer capped.deinit();
    try testing.expect(capped.result.truncated);
}

test "grep handles UTF-8, literals, case and context" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/src/a.zig", .{tmp.sub_path});
    defer testing.allocator.free(root);

    var zh = try run(root, .{ .pattern = "注释.*中文", .context = 1 });
    defer zh.deinit();
    try testing.expectEqual(@as(usize, 1), zh.result.matches.len);
    try testing.expectEqual(@as(usize, 3), zh.result.matches[0].line);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"fn alpha() void {}"}), zh.result.matches[0].before.?);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"fn beta() void {}"}), zh.result.matches[0].after.?);

    var literal = try run(root, .{ .pattern = "alpha()", .literal = true });
    defer literal.deinit();
    try testing.expectEqual(@as(usize, 1), literal.result.matches.len);

    var folded = try run(root, .{ .pattern = "TODO", .literal = true, .ignore_case = true });
    defer folded.deinit();
    try testing.expectEqual(@as(usize, 1), folded.result.matches.len);
    var lower = try run(root, .{ .pattern = "todo" });
    defer lower.deinit();
    try testing.expectEqual(@as(usize, 0), lower.result.matches.len);

    try testing.expectError(error.InvalidPattern, run(root, .{ .pattern = "(" }));
}
