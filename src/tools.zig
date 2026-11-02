const std = @import("std");
const js = @import("js.zig");
const process = @import("process.zig");
const policy = @import("policy.zig");

const Tool = struct {
    name: []const u8,
    doc: []const u8,
    run: *const fn (t: *Tools, gpa: std.mem.Allocator, args: []const u8) anyerror!js.ToolResult,
};

const all = [_]Tool{
    .{
        .name = "read",
        .run = Tools.read,
        .doc =
        \\  // Read a UTF-8 text file. offset is a 1-based line; if lines remain, the text ends with the next offset.
        \\  async read({ path, offset = 1, limit = 2000 }) {}, // → text
        ,
    },
    .{
        .name = "edit",
        .run = Tools.edit,
        .doc =
        \\  // Replace old_text with new_text in a file. old_text must match exactly once unless all is true.
        \\  async edit({ path, old_text, new_text, all = false }) {}, // → { replaced }
        ,
    },
    .{
        .name = "write",
        .run = Tools.write,
        .doc =
        \\  // Create or overwrite a file, creating parent directories.
        \\  async write({ path, content }) {}, // → { bytes }
        ,
    },
    .{
        .name = "bash",
        .run = Tools.bash,
        .doc =
        \\  // Run bash in the working directory; stderr is merged into output. exit_code is null if killed.
        \\  async bash({ command, timeout_ms = 120000 }) {}, // → { exit_code, output }
        ,
    },
};

pub const names = blk: {
    var n: [all.len][]const u8 = undefined;
    for (all, &n) |t, *name| name.* = t.name;
    const final = n;
    break :blk final;
};

pub const docs = blk: {
    var s: []const u8 = "const tools = {\n";
    for (all) |t| s = s ++ t.doc ++ "\n";
    break :blk s ++
        \\};
        \\// Strings print as-is, other values as JSON.
        \\console.log(...values);
        \\
    ;
};

const max_output = 16 * 1024;

pub const Tools = struct {
    io: std.Io,
    home: []const u8,
    cancel: std.atomic.Value(bool) = .init(false),
    paths_mutex: std.Io.Mutex = .init,
    paths_changed: std.Io.Condition = .init,
    paths: ?*PathLock = null,

    const PathLock = struct { path: []const u8, next: ?*PathLock = null };

    fn lockPath(t: *Tools, lock: *PathLock) void {
        t.paths_mutex.lockUncancelable(t.io);
        defer t.paths_mutex.unlock(t.io);
        while (true) {
            var item = t.paths;
            while (item) |p| : (item = p.next) if (std.mem.eql(u8, p.path, lock.path)) break;
            if (item == null) break;
            t.paths_changed.waitUncancelable(t.io, &t.paths_mutex);
        }
        lock.next = t.paths;
        t.paths = lock;
    }

    fn unlockPath(t: *Tools, lock: *PathLock) void {
        t.paths_mutex.lockUncancelable(t.io);
        defer t.paths_mutex.unlock(t.io);
        var link = &t.paths;
        while (link.* != lock) link = &link.*.?.next;
        link.* = lock.next;
        t.paths_changed.broadcast(t.io);
    }

    pub fn host(t: *Tools) js.Host {
        t.cancel.store(false, .release);
        return .{ .ctx = t, .names = &names, .call = call, .cancel = &t.cancel };
    }

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args: []const u8) js.ToolResult {
        const t: *Tools = @ptrCast(@alignCast(ctx));
        const r = for (all) |tool| {
            if (std.mem.eql(u8, name, tool.name)) break tool.run(t, gpa, args);
        } else fail(gpa, "unknown tool", .{});
        return r catch |err| fail(gpa, "{s}", .{@errorName(err)}) catch .{ .err = &.{} };
    }

    fn read(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !js.ToolResult {
        const A = struct { path: []const u8, offset: usize = 1, limit: usize = 2000 };
        const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
            return fail(gpa, "expected {{ path: string, offset?: number, limit?: number }}", .{});
        defer a.deinit();

        const data = std.Io.Dir.cwd().readFileAlloc(t.io, a.value.path, gpa, .limited(16 * 1024 * 1024)) catch |err|
            return fail(gpa, "{s}: {s}", .{ a.value.path, @errorName(err) });
        defer gpa.free(data);

        var start: usize = 0;
        var line: usize = 1;
        while (line < a.value.offset and start < data.len) : (line += 1) {
            start = if (std.mem.indexOfScalarPos(u8, data, start, '\n')) |nl| nl + 1 else data.len;
        }
        var end = start;
        var n: usize = 0;
        while (n < a.value.limit and end < data.len) : (n += 1) {
            end = if (std.mem.indexOfScalarPos(u8, data, end, '\n')) |nl| nl + 1 else data.len;
        }
        const body = try truncateMiddle(gpa, data[start..end]);
        defer gpa.free(body);
        const more = end < data.len;
        const text = if (more)
            try std.fmt.allocPrint(gpa, "{s}\n[more lines follow; continue with offset {d}]", .{ body, a.value.offset + n })
        else
            try gpa.dupe(u8, body);
        defer gpa.free(text);
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, text, .{}) };
    }

    fn edit(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !js.ToolResult {
        const A = struct { path: []const u8, old_text: []const u8, new_text: []const u8, all: bool = false };
        const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
            return fail(gpa, "expected {{ path: string, old_text: string, new_text: string, all?: boolean }}", .{});
        defer a.deinit();
        const v = a.value;
        const path = try normalizedPath(t.io, gpa, v.path);
        defer gpa.free(path);
        var lock: PathLock = .{ .path = path };
        t.lockPath(&lock);
        defer t.unlockPath(&lock);
        if (t.cancel.load(.acquire)) return error.Canceled;
        if (v.old_text.len == 0) return fail(gpa, "old_text is empty; use write to create a file", .{});

        const dir = std.Io.Dir.cwd();
        const data = dir.readFileAlloc(t.io, v.path, gpa, .limited(16 * 1024 * 1024)) catch |err|
            return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
        defer gpa.free(data);

        const count = std.mem.count(u8, data, v.old_text);
        if (count == 0) return fail(gpa, "old_text not found in {s}", .{v.path});
        if (count > 1 and !v.all)
            return fail(gpa, "old_text matches {d} times in {s}; include more surrounding text or pass all: true", .{ count, v.path });

        const out = try std.mem.replaceOwned(u8, gpa, data, v.old_text, v.new_text);
        defer gpa.free(out);
        dir.writeFile(t.io, .{ .sub_path = v.path, .data = out }) catch |err|
            return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
        return .{ .ok = try std.fmt.allocPrint(gpa, "{{\"replaced\":{d}}}", .{count}) };
    }

    fn write(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !js.ToolResult {
        const A = struct { path: []const u8, content: []const u8 };
        const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
            return fail(gpa, "expected {{ path: string, content: string }}", .{});
        defer a.deinit();
        const v = a.value;
        const path = try normalizedPath(t.io, gpa, v.path);
        defer gpa.free(path);
        var lock: PathLock = .{ .path = path };
        t.lockPath(&lock);
        defer t.unlockPath(&lock);
        if (t.cancel.load(.acquire)) return error.Canceled;

        const dir = std.Io.Dir.cwd();
        if (std.fs.path.dirname(v.path)) |parent| dir.createDirPath(t.io, parent) catch |err|
            return fail(gpa, "{s}: {s}", .{ parent, @errorName(err) });
        dir.writeFile(t.io, .{ .sub_path = v.path, .data = v.content }) catch |err|
            return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
        return .{ .ok = try std.fmt.allocPrint(gpa, "{{\"bytes\":{d}}}", .{v.content.len}) };
    }

    fn bash(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !js.ToolResult {
        const A = struct { command: []const u8, timeout_ms: i64 = 120_000 };
        const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
            return fail(gpa, "expected {{ command: string, timeout_ms?: number }}", .{});
        defer a.deinit();

        switch (policy.check(a.value.command, t.home)) {
            .allow => {},
            .deny => |why| return fail(gpa, "refused by nib: {s}. If it is really needed, ask the user to run it.", .{why}),
        }

        // In-shell redirect keeps stdout/stderr interleaving order.
        const script = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{a.value.command});
        defer gpa.free(script);

        const result = process.run(gpa, t.io, .{
            .argv = &.{ "bash", "-c", script },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }, &t.cancel, a.value.timeout_ms) catch |err| return switch (err) {
            error.TimedOut => fail(gpa, "timed out after {d} ms", .{a.value.timeout_ms}),
            error.Canceled => fail(gpa, "canceled", .{}),
            else => err,
        };
        const stdout = result.output;
        defer gpa.free(stdout);
        const output = try truncateMiddle(gpa, stdout);
        defer gpa.free(output);
        const code: ?u8 = switch (result.term) {
            .exited => |e| e,
            else => null,
        };
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .exit_code = code, .output = output }, .{}) };
    }
};

fn normalizedPath(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const absolute = if (std.fs.path.isAbsolute(path)) try gpa.dupe(u8, path) else try std.fs.path.join(gpa, &.{ cwd, path });
    defer gpa.free(absolute);
    return canonicalPath(io, gpa, absolute);
}

fn canonicalPath(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, path, &buffer) catch |err| {
        if (err != error.FileNotFound) return err;
        if (std.Io.Dir.cwd().readLink(io, path, &buffer)) |n| {
            const target = if (std.fs.path.isAbsolute(buffer[0..n]))
                try gpa.dupe(u8, buffer[0..n])
            else
                try std.fs.path.join(gpa, &.{ std.fs.path.dirname(path).?, buffer[0..n] });
            defer gpa.free(target);
            return canonicalPath(io, gpa, target);
        } else |link_err| switch (link_err) {
            error.FileNotFound, error.NotLink => {},
            else => return link_err,
        }
        const parent = try canonicalPath(io, gpa, std.fs.path.dirname(path) orelse return err);
        defer gpa.free(parent);
        return std.fs.path.resolve(gpa, &.{ parent, std.fs.path.basename(path) });
    };
    return gpa.dupe(u8, buffer[0..len]);
}

fn fail(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !js.ToolResult {
    return .{ .err = try std.fmt.allocPrint(gpa, fmt, args) };
}

pub fn truncateMiddle(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len <= max_output) return gpa.dupe(u8, s);
    const keep = max_output / 2;
    return std.fmt.allocPrint(gpa, "{s}\n[... {d} bytes omitted ...]\n{s}", .{
        trimPartialUtf8End(s[0..keep]), s.len - 2 * keep, trimPartialUtf8Start(s[s.len - keep ..]),
    });
}

fn trimPartialUtf8End(s: []const u8) []const u8 {
    var j = s.len;
    while (j > 0 and s.len - j < 3 and (s[j - 1] & 0xC0) == 0x80) j -= 1;
    if (j == 0) return s;
    const lead = j - 1;
    const len = std.unicode.utf8ByteSequenceLength(s[lead]) catch return s[0..lead];
    return if (lead + len <= s.len) s else s[0..lead];
}

fn trimPartialUtf8Start(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and i < 3 and (s[i] & 0xC0) == 0x80) i += 1;
    return s[i..];
}

const testing = std.testing;

fn callTool(name: []const u8, args: []const u8) !js.ToolResult {
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
    return Tools.call(&t, testing.allocator, name, args);
}

fn freeResult(r: js.ToolResult) void {
    switch (r) {
        inline else => |s| testing.allocator.free(s),
    }
}

test "tool docs are valid JavaScript" {
    // An uncalled function: parsed, never run.
    const src = "() => {\n" ++ docs ++ "}";
    const r = try js.eval(testing.allocator, testing.io, src, .{}, null, null);
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok);
}

test "bash merges stderr and reports exit code" {
    const r = try callTool("bash", "{\"command\":\"echo out; echo err >&2; exit 3\"}");
    defer freeResult(r);
    try testing.expectEqualStrings("{\"exit_code\":3,\"output\":\"out\\nerr\\n\"}", r.ok);
}

test "bash refuses commands denied by policy" {
    const r = try callTool("bash", "{\"command\":\"sudo true\"}");
    defer freeResult(r);
    try testing.expect(std.mem.startsWith(u8, r.err, "refused by nib: privileged"));
}

test "write then edit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/a/b.txt", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const args = struct {
        fn f(comptime fmt: []const u8, a: anytype) ![]u8 {
            return std.fmt.allocPrint(testing.allocator, fmt, a);
        }
    }.f;

    const w = try args("{{\"path\":\"{s}\",\"content\":\"one two two\\n\"}}", .{path});
    defer testing.allocator.free(w);
    const wr = try callTool("write", w);
    defer freeResult(wr);
    try testing.expectEqualStrings("{\"bytes\":12}", wr.ok);

    const ambiguous = try args("{{\"path\":\"{s}\",\"old_text\":\"two\",\"new_text\":\"2\"}}", .{path});
    defer testing.allocator.free(ambiguous);
    const amb = try callTool("edit", ambiguous);
    defer freeResult(amb);
    try testing.expect(std.mem.startsWith(u8, amb.err, "old_text matches 2 times"));

    const all_args = try args("{{\"path\":\"{s}\",\"old_text\":\"two\",\"new_text\":\"2\",\"all\":true}}", .{path});
    defer testing.allocator.free(all_args);
    const ar = try callTool("edit", all_args);
    defer freeResult(ar);
    try testing.expectEqualStrings("{\"replaced\":2}", ar.ok);

    const missing = try args("{{\"path\":\"{s}\",\"old_text\":\"zzz\",\"new_text\":\"\"}}", .{path});
    defer testing.allocator.free(missing);
    const mr = try callTool("edit", missing);
    defer freeResult(mr);
    try testing.expect(std.mem.startsWith(u8, mr.err, "old_text not found"));

    const content = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("one 2 2\n", content);
}

test "bash timeout kills the whole process group" {
    const r = try callTool("bash", "{\"command\":\"(sleep 7.3 &) ; sleep 7.3\",\"timeout_ms\":200}");
    defer freeResult(r);
    try testing.expectEqualStrings("timed out after 200 ms", r.err);
    // SIGKILL is asynchronous: give the orphaned sleep a moment to die.
    for (0..20) |_| {
        const left = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "pgrep", "-f", "sleep 7.3" } });
        defer testing.allocator.free(left.stdout);
        defer testing.allocator.free(left.stderr);
        if (left.stdout.len == 0) return;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(50), .clock = .awake }, testing.io);
    }
    return error.ProcessGroupSurvived;
}

test "bash cancel" {
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .cancel = .init(true) };
    const r = Tools.call(&t, testing.allocator, "bash", "{\"command\":\"sleep 5\"}");
    defer freeResult(r);
    try testing.expectEqualStrings("canceled", r.err);
}

test "bash timeout" {
    const r = try callTool("bash", "{\"command\":\"sleep 5\",\"timeout_ms\":100}");
    defer freeResult(r);
    try testing.expectEqualStrings("timed out after 100 ms", r.err);
}

test "read slices lines and reports errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "a\nb\nc\nd\n" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/f.txt", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const args = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}\",\"offset\":2,\"limit\":2}}", .{path});
    defer testing.allocator.free(args);

    const r = try callTool("read", args);
    defer freeResult(r);
    try testing.expectEqualStrings("\"b\\nc\\n\\n[more lines follow; continue with offset 4]\"", r.ok);

    const missing = try callTool("read", "{\"path\":\"/nonexistent/x\"}");
    defer freeResult(missing);
    try testing.expect(std.mem.endsWith(u8, missing.err, "FileNotFound"));

    const bad = try callTool("read", "{}");
    defer freeResult(bad);
    try testing.expect(std.mem.startsWith(u8, bad.err, "expected"));
}

test "utf8 cut points" {
    try testing.expectEqualStrings("ab", trimPartialUtf8End("ab\xe4\xbd"));
    try testing.expectEqualStrings("ab\xe4\xbd\xa0", trimPartialUtf8End("ab\xe4\xbd\xa0"));
    try testing.expectEqualStrings("cd", trimPartialUtf8Start("\xbd\xa0cd"));
}

test "truncateMiddle keeps head and tail" {
    const big = try testing.allocator.alloc(u8, max_output * 2);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const t = try truncateMiddle(testing.allocator, big);
    defer testing.allocator.free(t);
    try testing.expect(t.len < big.len);
    try testing.expect(std.mem.indexOf(u8, t, "bytes omitted") != null);
}

test "Promise.all runs bash concurrently and await remains sequential" {
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
    const clock = std.Io.Clock.awake;
    const start = clock.now(testing.io);
    const parallel = try js.eval(testing.allocator, testing.io,
        \\await Promise.all([tools.bash({command: "sleep 0.3"}), tools.bash({command: "sleep 0.3"})])
    , .{}, t.host(), null);
    defer parallel.deinit(testing.allocator);
    const middle = clock.now(testing.io);
    const serial = try js.eval(testing.allocator, testing.io,
        \\await tools.bash({command: "sleep 0.3"}); await tools.bash({command: "sleep 0.3"})
    , .{}, t.host(), null);
    defer serial.deinit(testing.allocator);
    const end = clock.now(testing.io);
    try testing.expect(parallel.ok and serial.ok);
    try testing.expect(start.durationTo(middle).toMilliseconds() < 550);
    try testing.expect(middle.durationTo(end).toMilliseconds() >= 600);
}

test "cancel and deadline join running tools and discard queued calls" {
    const Cancel = struct {
        fn work(io: std.Io, flag: *std.atomic.Value(bool)) void {
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(80), .clock = .awake }, io) catch unreachable;
            flag.store(true, .release);
        }
    };
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
    var flag: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Cancel.work, .{ testing.io, &flag });
    defer thread.join();
    const code = "await Promise.all(Array.from({length: 12}, () => tools.bash({command: 'sleep 5'})))";
    const canceled = try js.eval(testing.allocator, testing.io, code, .{}, t.host(), &flag);
    defer canceled.deinit(testing.allocator);
    try testing.expectEqualStrings("Error: run canceled", canceled.text);
    const timed = try js.eval(testing.allocator, testing.io, code, .{ .timeout_ms = 80 }, t.host(), null);
    defer timed.deinit(testing.allocator);
    try testing.expectEqualStrings("Error: run timed out", timed.text);
}

test "parallel edits lock the normalized path through read and write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "abcdefghijklmnop" });
    const code = try std.fmt.allocPrint(testing.allocator,
        \\await Promise.all(Array.from('abcdefghijklmnop', (letter, i) => tools.edit({{
        \\ path: '.zig-cache/tmp/{s}/' + (i % 2 ? './f' : 'f'), old_text: letter, new_text: letter.toUpperCase()
        \\}})))
    , .{tmp.sub_path});
    defer testing.allocator.free(code);
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
    const result = try js.eval(testing.allocator, testing.io, code, .{}, t.host(), null);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    const data = try tmp.dir.readFileAlloc(testing.io, "f", testing.allocator, .limited(100));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", data);
}

test "bash timeout still applies after output pipes close" {
    const result = try callTool("bash", "{\"command\":\"exec 1>&- 2>&-; sleep 5\",\"timeout_ms\":80}");
    defer freeResult(result);
    try testing.expectEqualStrings("timed out after 80 ms", result.err);
}

test "dangling symlink and target share the same path lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(testing.io, "target", "link", .{});
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const link = try std.fs.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(link);
    const target = try std.fs.path.join(testing.allocator, &.{ root, "target" });
    defer testing.allocator.free(target);
    const a = try normalizedPath(testing.io, testing.allocator, link);
    defer testing.allocator.free(a);
    const b = try normalizedPath(testing.io, testing.allocator, target);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}
