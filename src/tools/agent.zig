const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const provider = @import("../provider.zig");
const JsonEvent = @import("../session/events.zig").JsonEvent;
const process = @import("process.zig");
const Progress = @import("../session/events.zig").Progress;

pub fn agent(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const a = std.json.parseFromSlice(struct { prompt: []const u8, timeout_ms: i64 = 1_800_000 }, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ prompt: string, timeout_ms?: number }}", .{});
    defer a.deinit();
    if (a.value.timeout_ms <= 0) return fail(gpa, "timeout_ms must be positive", .{});
    var tracker: Tracker = .{
        .t = t,
        .arena = .init(gpa),
        .value = .{ .agent = try t.progress.add(gpa, t.io, a.value.prompt), .prompt = a.value.prompt },
    };
    defer tracker.arena.deinit();
    var state: @FieldType(Progress, "state") = .failed;
    defer {
        tracker.value.state = state;
        tracker.publish();
    }
    t.agents_mutex.lockUncancelable(t.io);
    while (t.agents_active >= 4 and !t.cancel.load(.acquire))
        t.agents_changed.waitTimeout(t.io, &t.agents_mutex, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
    const canceled = t.cancel.load(.acquire);
    if (!canceled) t.agents_active += 1;
    t.agents_mutex.unlock(t.io);
    if (canceled) {
        state = .canceled;
        return error.Canceled;
    }
    tracker.publish();
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
        .on_line = .{ .ctx = &tracker, .emit = Tracker.line },
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
    tracker.value.usage = usage;
    if (terminal) |parsed| tracker.value.step = switch (parsed.value) {
        .end => |end| end.steps,
        .@"error" => |err| err.steps,
        else => tracker.value.step,
    };
    if (result.stop) |err| {
        state = if (err == error.TimedOut) .timed_out else .canceled;
        return switch (err) {
            error.TimedOut => fail(gpa, "subagent stopped due to timeout after {d} ms (limit {d} ms); child session id: {s}. Files it changed may be incomplete; inspect them before continuing.", .{ elapsed_ms, a.value.timeout_ms, child_id orelse "unavailable (no start event)" }),
            error.Canceled => error.Canceled,
        };
    }
    const event = (terminal orelse return error.MissingAgentResult).value;
    if (event == .end and result.term.success()) state = .done;
    return switch (event) {
        .end => |end| if (result.term.success()) .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .text = end.text, .usage = end.usage }, .{}) } else error.AgentFailed,
        .@"error" => |err| fail(gpa, "subagent: {s}", .{err.message}),
        else => error.InvalidAgentOutput,
    };
}

const Tracker = struct {
    t: *Tools,
    arena: std.heap.ArenaAllocator,
    value: Progress,
    completed_steps: u32 = 0,
    reply_started: bool = false,
    pending_reply: bool = false,
    post_run_usage: bool = false,

    fn publish(tr: *Tracker) void {
        tr.t.progress.update(tr.arena.child_allocator, tr.t.io, tr.value) catch {};
    }

    fn line(ctx: *anyopaque, bytes: []const u8) void {
        const tr: *Tracker = @ptrCast(@alignCast(ctx));
        tr.observe(bytes) catch {};
    }

    fn observe(tr: *Tracker, bytes: []const u8) !void {
        const gpa = tr.arena.child_allocator;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const a = tr.arena.allocator();
        if (obj.contains("notice")) {
            tr.pending_reply = false;
            return;
        }
        if (obj.contains("delta")) {
            if (tr.reply_started) return;
            tr.value.step = tr.completed_steps + 1;
            tr.reply_started = true;
        } else if (!obj.contains("run_start") and !obj.contains("usage") and !obj.contains("run_end")) return;
        if (obj.get("run_start")) |code| {
            if (code != .string) return;
            if (tr.pending_reply) {
                tr.completed_steps += 1;
                tr.value.step = tr.completed_steps;
                tr.pending_reply = false;
            }
            var used: std.ArrayList([]const u8) = .empty;
            var rest = code.string;
            while (std.mem.indexOf(u8, rest, "tools.")) |i| {
                rest = rest[i + 6 ..];
                var end: usize = 0;
                while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
                if (end == 0) continue;
                const name = rest[0..end];
                var call = end;
                while (call < rest.len and std.ascii.isWhitespace(rest[call])) call += 1;
                if (call == rest.len or rest[call] != '(') continue;
                for (used.items) |known| {
                    if (std.mem.eql(u8, name, known)) break;
                } else try used.append(a, try a.dupe(u8, name));
            }
            tr.value.tools = used.items;
            tr.value.files = &.{};
        }
        if (obj.get("run_end")) |run| {
            const r = try std.json.parseFromValue(struct { changes: []const struct { path: []const u8 } = &.{} }, gpa, run, .{ .ignore_unknown_fields = true });
            defer r.deinit();
            var files: std.ArrayList([]const u8) = .empty;
            for (r.value.changes) |change| try files.append(a, try a.dupe(u8, change.path));
            tr.value.files = files.items;
            tr.post_run_usage = true;
        }
        if (obj.get("usage")) |snapshot| {
            const u = try std.json.parseFromValue(provider.Usage, gpa, snapshot, .{ .ignore_unknown_fields = true });
            defer u.deinit();
            tr.value.usage = u.value;
            // Each Run repeats the Step's usage; compaction usage has no following Run.
            if (tr.post_run_usage) {
                tr.post_run_usage = false;
            } else if (tr.reply_started) {
                tr.completed_steps = tr.value.step;
                tr.reply_started = false;
            } else tr.pending_reply = true;
        }
        tr.publish();
    }
};

test "child progress counts Steps rather than Runs and ignores compaction snapshots" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/unused" };
    defer t.progress.clear(testing.allocator);
    var tr: Tracker = .{
        .t = &t,
        .arena = .init(testing.allocator),
        .value = .{ .agent = try t.progress.add(testing.allocator, testing.io, "child"), .prompt = "child" },
    };
    defer tr.arena.deinit();
    try tr.observe("{\"delta\":{}}");
    try tr.observe("{\"delta\":{}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":100}}");
    try tr.observe("{\"run_start\":\"await tools.edit({}); await tools.edit({}); await tools.read({}); typeof tools.agent\"}");
    try testing.expectEqual(@as(u32, 1), tr.value.step);
    try testing.expectEqual(@as(usize, 2), tr.value.tools.len);
    try testing.expectEqualStrings("edit", tr.value.tools[0]);
    try tr.observe("{\"run_end\":{\"changes\":[{\"path\":\"a.zig\",\"diff\":\"unused\"}]}}");
    try testing.expectEqualStrings("a.zig", tr.value.files[0]);
    try tr.observe("{\"usage\":{\"prompt_tokens\":100}}");
    try tr.observe("{\"run_start\":\"await tools.bash({})\"}");
    try testing.expectEqual(@as(u32, 1), tr.value.step);
    try testing.expectEqual(@as(usize, 0), tr.value.files.len);
    try tr.observe("{\"run_end\":{}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":100}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":150}}");
    try tr.observe("{\"notice\":\"compacted\"}");
    try tr.observe("{\"delta\":{}}");
    try testing.expectEqual(@as(u32, 2), tr.value.step);
    try tr.observe("{\"usage\":{\"prompt_tokens\":250}}");
    try tr.observe("{\"run_start\":\"tools.read({})\"}");
    try tr.observe("{\"run_end\":{}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":250}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":350}}");
    try tr.observe("{\"run_start\":\"tools.read({})\"}");
    try testing.expectEqual(@as(u32, 3), tr.value.step);
    try testing.expectEqual(@as(u64, 350), tr.value.usage.prompt_tokens);
}
