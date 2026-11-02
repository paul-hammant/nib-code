//! Tools exposed to Runs. Each takes JSON args and returns JSON.
//! No approval or OS sandbox yet (see ADR 0004).

const std = @import("std");
const js = @import("js.zig");

pub const names = [_][]const u8{ "read", "bash" };

/// TypeScript declarations shown to the model. Keep in sync with `call`.
pub const declarations =
    \\declare const tools: {
    \\  /** Read a UTF-8 text file. `offset` is a 1-based line number; `limit` is a line count (default 2000). */
    \\  read(args: { path: string; offset?: number; limit?: number }): Promise<string>;
    \\  /** Run a bash command in the working directory. stderr is merged into output. */
    \\  bash(args: { command: string; timeout_ms?: number }): Promise<{ exit_code: number | null; output: string }>;
    \\};
    \\declare const console: { log(...args: unknown[]): void };
;

/// Tool output larger than this is cut in the middle before it returns to the script.
const max_output = 64 * 1024;

pub const Tools = struct {
    io: std.Io,

    pub fn host(t: *Tools) js.Host {
        return .{ .ctx = t, .names = &names, .call = call };
    }

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args: []const u8) js.ToolResult {
        const t: *Tools = @ptrCast(@alignCast(ctx));
        const r = if (std.mem.eql(u8, name, "read"))
            t.read(gpa, args)
        else if (std.mem.eql(u8, name, "bash"))
            t.bash(gpa, args)
        else
            fail(gpa, "unknown tool", .{});
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

        // Slice out lines [offset, offset + limit).
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

    fn bash(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !js.ToolResult {
        const A = struct { command: []const u8, timeout_ms: i64 = 120_000 };
        const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
            return fail(gpa, "expected {{ command: string, timeout_ms?: number }}", .{});
        defer a.deinit();

        // Merge stderr into stdout inside the shell so ordering is preserved.
        const script = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{a.value.command});
        defer gpa.free(script);

        const res = std.process.run(gpa, t.io, .{
            .argv = &.{ "bash", "-c", script },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(a.value.timeout_ms), .clock = .awake } },
        }) catch |err| switch (err) {
            error.Timeout => return fail(gpa, "timed out after {d} ms", .{a.value.timeout_ms}),
            error.StreamTooLong => return fail(gpa, "output exceeded 8 MiB", .{}),
            else => return err,
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        const output = try truncateMiddle(gpa, res.stdout);
        defer gpa.free(output);
        const code: ?u8 = switch (res.term) {
            .exited => |e| e,
            else => null,
        };
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .exit_code = code, .output = output }, .{}) };
    }
};

fn fail(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !js.ToolResult {
    return .{ .err = try std.fmt.allocPrint(gpa, fmt, args) };
}

/// Keep the head and tail of oversized text; the middle is usually noise.
pub fn truncateMiddle(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len <= max_output) return gpa.dupe(u8, s);
    const keep = max_output / 2;
    return std.fmt.allocPrint(gpa, "{s}\n[... {d} bytes omitted ...]\n{s}", .{
        utf8Prefix(s[0..keep]), s.len - 2 * keep, utf8Suffix(s[s.len - keep ..]),
    });
}

/// Drop a trailing UTF-8 sequence that was cut short.
fn utf8Prefix(s: []const u8) []const u8 {
    var j = s.len;
    while (j > 0 and s.len - j < 3 and (s[j - 1] & 0xC0) == 0x80) j -= 1;
    if (j == 0) return s;
    const lead = j - 1;
    const len = std.unicode.utf8ByteSequenceLength(s[lead]) catch return s[0..lead];
    return if (lead + len <= s.len) s else s[0..lead];
}

/// Drop leading continuation bytes of a sequence that was cut short.
fn utf8Suffix(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and i < 3 and (s[i] & 0xC0) == 0x80) i += 1;
    return s[i..];
}

// ---- tests ----

const testing = std.testing;

fn callTool(name: []const u8, args: []const u8) !js.ToolResult {
    var t: Tools = .{ .io = testing.io };
    return Tools.call(&t, testing.allocator, name, args);
}

fn freeResult(r: js.ToolResult) void {
    switch (r) {
        inline else => |s| testing.allocator.free(s),
    }
}

test "bash merges stderr and reports exit code" {
    const r = try callTool("bash", "{\"command\":\"echo out; echo err >&2; exit 3\"}");
    defer freeResult(r);
    try testing.expectEqualStrings("{\"exit_code\":3,\"output\":\"out\\nerr\\n\"}", r.ok);
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
    try testing.expectEqualStrings("ab", utf8Prefix("ab\xe4\xbd"));
    try testing.expectEqualStrings("ab\xe4\xbd\xa0", utf8Prefix("ab\xe4\xbd\xa0"));
    try testing.expectEqualStrings("cd", utf8Suffix("\xbd\xa0cd"));
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
