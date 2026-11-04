const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const process = @import("process.zig");
const policy = @import("policy.zig");

pub fn bash(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const A = struct { command: []const u8, timeout_ms: i64 = 120_000 };
    const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ command: string, timeout_ms?: number }}", .{});
    defer a.deinit();

    switch (policy.checkCredentials(a.value.command, t.codexHome())) {
        .allow => {},
        .deny => |why| return fail(gpa, "refused by nib: {s}", .{why}),
    }
    switch (policy.check(a.value.command, t.home)) {
        .allow => {},
        .deny => |why| return if (std.mem.eql(u8, why, policy.too_long))
            fail(gpa, "refused by nib: {s}", .{why})
        else
            fail(gpa, "refused by nib: {s}. If it is really needed, ask the user to run it.", .{why}),
    }

    // In-shell redirect keeps stdout/stderr interleaving order.
    const script = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{a.value.command});
    defer gpa.free(script);

    const result = process.run(gpa, t.io, .{ .spawn = .{
        .argv = &.{ "bash", "-c", script },
        .environ_map = t.environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }, .cancel = &t.cancel, .timeout_ms = a.value.timeout_ms, .max_output_bytes = 16 * 1024 * 1024 }) catch |err| return switch (err) {
        error.OutputLimit => fail(gpa, "output exceeds 16 MiB; redirect output to a file", .{}),
        else => err,
    };
    const stdout = result.output;
    defer gpa.free(stdout);
    if (result.stop) |err| return switch (err) {
        error.TimedOut => fail(gpa, "timed out after {d} ms", .{a.value.timeout_ms}),
        error.Canceled => fail(gpa, "canceled", .{}),
    };
    const code: ?u8 = switch (result.term) {
        .exited => |e| e,
        else => null,
    };
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .exit_code = code, .output = stdout }, .{}) };
}

const testing = std.testing;
const callTool = tools.callTool;
const freeResult = tools.freeResult;

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

test "bash executes a 300-line Python heredoc" {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(testing.allocator);
    try script.appendSlice(testing.allocator, "python3 - <<'EOF'\nx = 0\n");
    for (0..298) |_| try script.appendSlice(testing.allocator, "x += 1\n");
    try script.appendSlice(testing.allocator, "print(x)\nEOF\n");
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .command = script.items }, .{});
    defer testing.allocator.free(args);
    const r = try callTool("bash", args);
    defer freeResult(r);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"298\\n\"}", r.ok);
}

test "bash rejects more than 256 shell words in the command portion" {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(testing.allocator);
    try command.appendSlice(testing.allocator, "echo");
    for (0..256) |_| try command.appendSlice(testing.allocator, " x");
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .command = command.items }, .{});
    defer testing.allocator.free(args);
    const r = try callTool("bash", args);
    defer freeResult(r);
    try testing.expectEqualStrings("refused by nib: " ++ policy.too_long, r.err);
    try testing.expectEqualStrings("refused by nib: command portion has more than 256 shell words; write long scripts to a file with tools.write and run that file", r.err);
}

test "bash refuses credential references inside heredoc bodies" {
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .command = "python3 - <<'EOF'\nprint('~/.codex/auth.json')\nEOF\n" }, .{});
    defer testing.allocator.free(args);
    const r = try callTool("bash", args);
    defer freeResult(r);
    try testing.expectEqualStrings("refused by nib: access to Codex credentials", r.err);
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

test "bash timeout still applies after output pipes close" {
    const result = try callTool("bash", "{\"command\":\"exec 1>&- 2>&-; sleep 5\",\"timeout_ms\":80}");
    defer freeResult(result);
    try testing.expectEqualStrings("timed out after 80 ms", result.err);
}

test "bash receives ordinary environment without API keys" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NIB_API_KEY", "fictional-secret");
    try env.put("NIB_TEST_ORDINARY", "kept");
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .environ = &env };
    const result = Tools.call(&t, testing.allocator, "bash", "{\"command\":\"printf '%s:%s' \\\"${NIB_API_KEY-unset}\\\" \\\"$NIB_TEST_ORDINARY\\\"\"}");
    defer freeResult(result);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"unset:kept\"}", result.ok);
}

test "bash returns output up to 16 MiB verbatim" {
    const r = try callTool("bash", "{\"command\":\"head -c 16777216 /dev/zero | tr '\\\\0' x\"}");
    defer freeResult(r);
    const parsed = try std.json.parseFromSlice(struct { exit_code: u8, output: []const u8 }, testing.allocator, r.ok, .{});
    defer parsed.deinit();
    try testing.expectEqual(0, parsed.value.exit_code);
    try testing.expectEqual(16 * 1024 * 1024, parsed.value.output.len);
    for (parsed.value.output) |byte| try testing.expectEqual(@as(u8, 'x'), byte);
}

test "bash rejects output over 16 MiB and kills the process group" {
    const start = std.Io.Clock.awake.now(testing.io);
    const r = try callTool("bash", "{\"command\":\"head -c 16777217 /dev/zero; sleep 30\"}");
    defer freeResult(r);
    try testing.expectEqualStrings("output exceeds 16 MiB; redirect output to a file", r.err);
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() < 5000);
}
