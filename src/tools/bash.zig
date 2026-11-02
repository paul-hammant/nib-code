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
        .deny => |why| return fail(gpa, "refused by nib: {s}. If it is really needed, ask the user to run it.", .{why}),
    }

    // In-shell redirect keeps stdout/stderr interleaving order.
    const script = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{a.value.command});
    defer gpa.free(script);

    const result = try process.run(gpa, t.io, .{ .spawn = .{
        .argv = &.{ "bash", "-c", script },
        .environ_map = t.environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }, .cancel = &t.cancel, .timeout_ms = a.value.timeout_ms });
    const stdout = result.output;
    defer gpa.free(stdout);
    if (result.stop) |err| return switch (err) {
        error.TimedOut => fail(gpa, "timed out after {d} ms", .{a.value.timeout_ms}),
        error.Canceled => fail(gpa, "canceled", .{}),
    };
    const output = try tools.truncateMiddle(gpa, stdout);
    defer gpa.free(output);
    const code: ?u8 = switch (result.term) {
        .exited => |e| e,
        else => null,
    };
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .exit_code = code, .output = output }, .{}) };
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
