const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const provider = @import("../provider.zig");
const JsonEvent = @import("../session/events.zig").JsonEvent;
const process = @import("process.zig");

pub fn agent(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const a = std.json.parseFromSlice(struct { prompt: []const u8, timeout_ms: i64 = 1_800_000 }, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ prompt: string, timeout_ms?: number }}", .{});
    defer a.deinit();
    if (a.value.timeout_ms <= 0) return fail(gpa, "timeout_ms must be positive", .{});
    t.agents_mutex.lockUncancelable(t.io);
    while (t.agents_active >= 4 and !t.cancel.load(.acquire))
        t.agents_changed.waitTimeout(t.io, &t.agents_mutex, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
    const canceled = t.cancel.load(.acquire);
    if (!canceled) t.agents_active += 1;
    t.agents_mutex.unlock(t.io);
    if (canceled) return error.Canceled;
    defer {
        t.agents_mutex.lockUncancelable(t.io);
        t.agents_active -= 1;
        t.agents_changed.signal(t.io);
        t.agents_mutex.unlock(t.io);
    }
    var env = try (t.environ orelse return error.AgentEnvironmentUnavailable).clone(gpa);
    defer env.deinit();
    const depth = try std.fmt.allocPrint(gpa, "{d}", .{t.depth + 1});
    defer gpa.free(depth);
    try env.put("NIB_AGENT_DEPTH", depth);
    try env.put("NIB_PARENT_SESSION_ID", t.session_id orelse return error.MissingSessionId);
    const executable = try std.process.executablePathAlloc(t.io, gpa);
    defer gpa.free(executable);
    const input = try std.json.Stringify.valueAlloc(gpa, .{ .prompt = a.value.prompt, .config = t.cfg orelse return error.AgentConfigUnavailable }, .{});
    defer gpa.free(input);
    const started = std.Io.Clock.awake.now(t.io);
    const result = try process.run(gpa, t.io, .{
        .spawn = .{ .argv = &.{ executable, "ask", "--json", "--agent-input", "-" }, .environ_map = &env, .stdout = .pipe, .stderr = .ignore },
        .input = input,
        .cancel = &t.cancel,
        .timeout_ms = a.value.timeout_ms,
        .termination_grace_ms = 500,
    });
    defer gpa.free(result.output);
    var usage: provider.Usage = .{};
    defer {
        t.agents_mutex.lockUncancelable(t.io);
        t.agent_usage.add(usage);
        t.agents_mutex.unlock(t.io);
    }
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds();
    var child_id: ?[]u8 = null;
    defer if (child_id) |id| gpa.free(id);
    var terminal: ?std.json.Parsed(JsonEvent) = null;
    defer if (terminal) |parsed| parsed.deinit();
    var lines = std.mem.splitScalar(u8, result.output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (result.stop != null and lines.rest().len == 0 and !std.mem.endsWith(u8, result.output, "\n")) break;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidAgentOutput;
        if (parsed.value.object.contains("start")) {
            if (child_id != null) return error.InvalidAgentOutput;
            const start = try std.json.parseFromSlice(JsonEvent, gpa, line, .{});
            defer start.deinit();
            child_id = try gpa.dupe(u8, start.value.start.session_id);
        }
        if (parsed.value.object.get("usage")) |snapshot| {
            const u = try std.json.parseFromValue(provider.Usage, gpa, snapshot, .{ .ignore_unknown_fields = true });
            defer u.deinit();
            usage = u.value;
        }
        if (!parsed.value.object.contains("end") and !parsed.value.object.contains("error")) continue;
        if (terminal != null) return error.InvalidAgentOutput;
        terminal = try std.json.parseFromSlice(JsonEvent, gpa, line, .{ .ignore_unknown_fields = true });
    }
    if (terminal) |parsed| usage = switch (parsed.value) {
        .end => |end| end.usage,
        .@"error" => |err| err.usage,
        else => return error.InvalidAgentOutput,
    };
    if (result.stop) |err| return switch (err) {
        error.TimedOut => fail(gpa, "subagent stopped due to timeout after {d} ms (limit {d} ms); child session id: {s}. Files it changed may be incomplete; inspect them before continuing.", .{ elapsed_ms, a.value.timeout_ms, child_id orelse "unavailable (no start event)" }),
        error.Canceled => error.Canceled,
    };
    const event = (terminal orelse return error.MissingAgentResult).value;
    return switch (event) {
        .end => |end| if (result.term.success()) .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .text = end.text, .usage = end.usage }, .{}) } else error.AgentFailed,
        .@"error" => |err| fail(gpa, "subagent: {s}", .{err.message}),
        else => error.InvalidAgentOutput,
    };
}
