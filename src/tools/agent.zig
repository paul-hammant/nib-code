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
    const a = std.json.parseFromSlice(struct { prompt: []const u8, timeout_ms: i64 = 1_800_000, model: ?[]const u8 = null, effort: ?[]const u8 = null }, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ prompt: string, timeout_ms?: number, model?: string, effort?: string }}", .{});
    defer a.deinit();
    if (a.value.timeout_ms <= 0) return fail(gpa, "timeout_ms must be positive", .{});
    var cfg = t.cfg orelse return error.AgentConfigUnavailable;
    if (a.value.model) |model| cfg.model = model;
    if (a.value.effort) |effort| try cfg.setEffort(effort);
    var tracker: Tracker = .{
        .t = t,
        .arena = .init(gpa),
        .value = .{ .agent = try t.progress.add(gpa, t.io, a.value.prompt), .prompt = a.value.prompt },
    };
    defer tracker.arena.deinit();
    defer t.addUsage(tracker.output.usage);
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
    const input = try std.json.Stringify.valueAlloc(gpa, .{ .prompt = a.value.prompt, .config = cfg }, .{});
    defer gpa.free(input);
    const started = std.Io.Clock.awake.now(t.io);
    const result = process.run(gpa, t.io, .{
        .spawn = .{ .argv = &.{ executable, "ask", "--json", "--agent-input", "-" }, .environ_map = &env, .stdout = .pipe, .stderr = .ignore },
        .input = input,
        .cancel = &t.cancel,
        .timeout_ms = a.value.timeout_ms,
        .termination_grace_ms = 500,
        .on_line = .{ .ctx = &tracker, .emit = Tracker.line },
    }) catch |err| {
        if (t.cancel.load(.acquire)) {
            state = .canceled;
            return error.Canceled;
        }
        return tracker.output.result(gpa, started.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds(), @errorName(err), null);
    };
    defer gpa.free(result.output);
    if (result.stop == null) {
        const tail = if (std.mem.lastIndexOfScalar(u8, result.output, '\n')) |last| result.output[last + 1 ..] else result.output;
        if (tail.len > 0) tracker.capture(tail);
    }
    const output = &tracker.output;
    tracker.value.usage = output.usage;
    if (output.steps) |steps| tracker.value.step = steps;
    if (t.cancel.load(.acquire) or (if (result.stop) |stop| stop == error.Canceled else false)) {
        state = .canceled;
        return error.Canceled;
    }
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds();
    const reason: ?[]const u8 = if (if (result.stop) |stop| stop == error.TimedOut else false) reason: {
        state = .timed_out;
        break :reason "stopped due to timeout";
    } else if (!result.term.success())
        output.failure orelse "AgentFailed (process crashed or exited nonzero)"
    else if (output.failure) |failure| failure else if (!output.ended) "MissingAgentResult" else null;
    if (reason == null) state = .done;
    return output.result(gpa, elapsed_ms, reason, if (state == .timed_out) a.value.timeout_ms else null);
}

const Change = struct { path: []const u8, added: usize, removed: usize, created: bool = false };

const Output = struct {
    text: std.ArrayList(u8) = .empty,
    usage: provider.Usage = .{},
    changes: std.ArrayList(Change) = .empty,
    child_id: ?[]const u8 = null,
    steps: ?u32 = null,
    ended: bool = false,
    failure: ?[]const u8 = null,

    fn observe(out: *Output, gpa: std.mem.Allocator, a: std.mem.Allocator, bytes: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, temp, bytes, .{});
        if (value != .object) return error.InvalidAgentOutput;
        const obj = value.object;
        if (obj.contains("start")) {
            if (out.child_id != null) return error.InvalidAgentOutput;
            const event = try std.json.parseFromValueLeaky(JsonEvent, temp, value, .{});
            out.child_id = try a.dupe(u8, event.start.session_id);
        }
        if (obj.get("delta")) |delta| {
            const d = try std.json.parseFromValueLeaky(struct { kind: provider.Kind, text: []const u8 }, temp, delta, .{ .ignore_unknown_fields = true });
            if (d.kind == .text) try out.text.appendSlice(a, d.text);
        }
        if (obj.get("usage")) |usage| out.usage = try std.json.parseFromValueLeaky(provider.Usage, temp, usage, .{ .ignore_unknown_fields = true });
        if (obj.get("run_end")) |run| {
            const r = try std.json.parseFromValueLeaky(struct { changes: []const Change = &.{} }, temp, run, .{ .ignore_unknown_fields = true });
            for (r.changes) |change| {
                for (out.changes.items) |*known| {
                    if (!std.mem.eql(u8, known.path, change.path)) continue;
                    known.added += change.added;
                    known.removed += change.removed;
                    known.created = known.created or change.created;
                    break;
                } else {
                    var summary = change;
                    summary.path = try a.dupe(u8, change.path);
                    try out.changes.append(a, summary);
                }
            }
        }
        if (obj.contains("end") or obj.contains("error")) {
            if (out.ended) return error.InvalidAgentOutput;
            const event = try std.json.parseFromValueLeaky(JsonEvent, temp, value, .{ .ignore_unknown_fields = true });
            out.ended = true;
            switch (event) {
                .end => |end| {
                    out.text.clearRetainingCapacity();
                    try out.text.appendSlice(a, end.text);
                    out.usage = end.usage;
                    out.steps = end.steps;
                },
                .@"error" => |err| {
                    out.failure = try a.dupe(u8, err.message);
                    out.usage = err.usage;
                    out.steps = err.steps;
                },
                else => return error.InvalidAgentOutput,
            }
        }
    }

    fn result(out: *const Output, gpa: std.mem.Allocator, elapsed_ms: i64, reason: ?[]const u8, timeout_ms: ?i64) !sandbox.ToolResult {
        if (reason) |message| {
            const detail = if (timeout_ms) |limit|
                try std.fmt.allocPrint(gpa, "subagent stopped due to timeout after {d} ms (limit {d} ms); child session id: {s}. Files it changed may be incomplete; inspect them before continuing.", .{ elapsed_ms, limit, out.child_id orelse "unavailable (no start event)" })
            else
                try std.fmt.allocPrint(gpa, "subagent: {s} after {d} ms; child session id: {s}. Files it changed may be incomplete; inspect them before continuing.", .{ message, elapsed_ms, out.child_id orelse "unavailable (no start event)" });
            defer gpa.free(detail);
            return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .@"error" = detail, .text = out.text.items, .usage = out.usage, .changes = out.changes.items }, .{}) };
        }
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .text = out.text.items, .usage = out.usage, .changes = out.changes.items }, .{}) };
    }
};

const Tracker = struct {
    t: *Tools,
    arena: std.heap.ArenaAllocator,
    value: Progress,
    completed_steps: u32 = 0,
    reply_started: bool = false,
    pending_reply: bool = false,
    post_run_usage: bool = false,
    output: Output = .{},

    fn publish(tr: *Tracker) void {
        tr.t.progress.update(tr.arena.child_allocator, tr.t.io, tr.value) catch {};
    }

    fn line(ctx: *anyopaque, bytes: []const u8) void {
        const tr: *Tracker = @ptrCast(@alignCast(ctx));
        tr.capture(bytes);
        tr.observe(bytes) catch {};
    }

    fn capture(tr: *Tracker, bytes: []const u8) void {
        tr.output.observe(tr.arena.child_allocator, tr.arena.allocator(), bytes) catch |err| {
            tr.output.failure = @errorName(err);
        };
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

test "agent output retains only returned data and terminal text overrides deltas" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Output = .{};
    for (0..500) |_| try out.observe(testing.allocator, arena.allocator(), "{\"delta\":{\"kind\":\"reasoning\",\"text\":\"ignored reasoning\"}}");
    try testing.expectEqual(@as(usize, 0), arena.queryCapacity());
    try out.observe(testing.allocator, arena.allocator(), "{\"delta\":{\"kind\":\"text\",\"text\":\"partial\"}}");
    try testing.expectEqualStrings("partial", out.text.items);
    try out.observe(testing.allocator, arena.allocator(), "{\"run_end\":{\"changes\":[{\"path\":\"a\",\"added\":2,\"removed\":1,\"created\":true,\"diff\":\"not retained\"}]}}");
    try testing.expectEqualStrings("a", out.changes.items[0].path);
    try out.observe(testing.allocator, arena.allocator(), "{\"end\":{\"text\":\"final\",\"usage\":{\"prompt_tokens\":10},\"steps\":2}}");
    try testing.expectEqualStrings("final", out.text.items);
    try testing.expectEqual(@as(u64, 10), out.usage.prompt_tokens);
}

test "agent failure without output is data and queued user cancellation rejects" {
    const testing = std.testing;
    const out: Output = .{};
    const result = try out.result(testing.allocator, 12, "AgentFailed", null);
    defer tools.freeResult(result);
    try testing.expect(result == .ok);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.ok, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("ok").?.bool);
    try testing.expectEqualStrings("", obj.get("text").?.string);
    try testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, "unavailable (no start event)") != null);
    var t: Tools = .{ .io = testing.io, .home = "/unused", .cfg = .{ .model = "m", .base_url = "", .api_key = "" }, .agents_active = 4 };
    defer t.progress.clear(testing.allocator);
    t.cancel.store(true, .release);
    try testing.expectError(error.Canceled, agent(&t, testing.allocator, "{\"prompt\":\"cancelled\"}"));
    try testing.expectEqual(@as(usize, 4), t.agents_active);
}
