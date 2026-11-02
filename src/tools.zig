const std = @import("std");
const js = @import("js.zig");
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

const max_output = 64 * 1024;

pub const Tools = struct {
    io: std.Io,
    home: []const u8,
    cancel: ?*const std.atomic.Value(bool) = null,

    pub fn host(t: *Tools) js.Host {
        return .{ .ctx = t, .names = &names, .call = call };
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

        var child = try std.process.spawn(t.io, .{
            .argv = &.{ "bash", "-c", script },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        });
        defer child.kill(t.io);

        var streams: std.Io.File.MultiReader.Buffer(1) = undefined;
        var mr: std.Io.File.MultiReader = undefined;
        mr.init(gpa, t.io, streams.toStreams(), &.{child.stdout.?});
        defer mr.deinit();

        const deadline: std.Io.Clock.Timestamp = .fromNow(t.io, .{ .raw = .fromMilliseconds(a.value.timeout_ms), .clock = .awake });
        while (true) {
            mr.fill(4096, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch |err| switch (err) {
                error.EndOfStream => break,
                error.Timeout => {},
                else => return err,
            };
            const stop: ?[]const u8 = if (t.cancel != null and t.cancel.?.load(.acquire))
                "canceled"
            else if (std.Io.Clock.Timestamp.now(t.io, .awake).compare(.gte, deadline))
                "timed out"
            else if (mr.reader(0).buffered().len > 8 * 1024 * 1024)
                "output exceeded 8 MiB"
            else
                null;
            if (stop) |why| {
                // The whole process group, so children of the command die too.
                if (child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
                return if (std.mem.eql(u8, why, "timed out"))
                    fail(gpa, "timed out after {d} ms", .{a.value.timeout_ms})
                else
                    fail(gpa, "{s}", .{why});
            }
        }
        try mr.checkAnyError();
        const term = try child.wait(t.io);
        const stdout = try mr.toOwnedSlice(0);
        defer gpa.free(stdout);

        const output = try truncateMiddle(gpa, stdout);
        defer gpa.free(output);
        const code: ?u8 = switch (term) {
            .exited => |e| e,
            else => null,
        };
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .exit_code = code, .output = output }, .{}) };
    }
};

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
    var flag: std.atomic.Value(bool) = .init(true);
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .cancel = &flag };
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
