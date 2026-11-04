const std = @import("std");
const Tools = @import("../tools.zig").Tools;
const agent = @import("agent.zig");
const Inbox = @import("../session/inbox.zig").Inbox;
const Log = @import("../session/log.zig").Log;
const BackgroundEvent = @import("../session/events.zig").Background;
const output = @import("../session/output.zig");

pub const Background = struct {
    mutex: std.Io.Mutex = .init,
    jobs: std.ArrayList(*Job) = .empty,
    cancel: std.atomic.Value(bool) = .init(false),
    inbox: ?*Inbox = null,
    log: ?*Log = null,
    turn_step: u32 = 0,
    bash_active: usize = 0,

    pub const bash_limit = @import("../sandbox.zig").tool_concurrency;

    const Job = struct {
        t: *Tools,
        gpa: std.mem.Allocator,
        args: []u8,
        prompt: []u8,
        id: []u8,
        kind: BackgroundEvent.Kind,
        run: usize,
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        announced: bool = false,
        delivered: bool = false,
        failure: ?anyerror = null,

        fn work(job: *Job) void {
            job.finish() catch |err| {
                if (job.kind == .agent) job.t.agent_sessions.release(job.t.io, job.id);
                job.failure = err;
            };
            if (job.kind == .bash) {
                const bg = &job.t.background;
                bg.mutex.lockUncancelable(job.t.io);
                bg.bash_active -= 1;
                bg.mutex.unlock(job.t.io);
            }
            job.done.store(true, .release);
        }

        fn finish(job: *Job) !void {
            const gpa = job.gpa;
            const t = job.t;
            const result = switch (job.kind) {
                .agent => agent.execute(t, gpa, job.args, &t.background.cancel, job.id, job.run, true),
                .bash => @import("bash.zig").executeBackground(t, gpa, job.args, &t.background.cancel, .{ .id = job.id, .run = job.run, .background = true, .kind = .bash, .prompt = "" }),
            } catch |err| try @import("../tools.zig").fail(gpa, "{s}", .{@errorName(err)});
            defer switch (result) {
                inline else => |bytes| gpa.free(bytes),
            };
            try job.deliver(result);
        }

        fn deliver(job: *Job, result: @import("../sandbox.zig").ToolResult) !void {
            const t = job.t;
            const gpa = job.gpa;
            if (t.background.cancel.load(.acquire)) {
                if (job.kind == .agent) t.agent_sessions.release(t.io, job.id);
                return;
            }
            const json = try messageResult(gpa, job.kind, job.id, result);
            defer gpa.free(json);
            const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
            defer parsed.deinit();
            const ok = switch (job.kind) {
                .agent => parsed.value.object.get("ok").?.bool,
                .bash => if (parsed.value.object.get("exit_code")) |code| code == .integer and code.integer == 0 else false,
            };
            const prefix = try std.fmt.allocPrint(gpa, "[background {s} {s} finished]\n", .{ @tagName(job.kind), job.id });
            defer gpa.free(prefix);
            const formatted = try output.formatMessage(gpa, prefix, json);
            defer gpa.free(formatted);
            if (job.kind == .agent) {
                t.agent_sessions.mutex.lockUncancelable(t.io);
                defer t.agent_sessions.mutex.unlock(t.io);
                _ = try t.background.inbox.?.enqueueBackground(gpa, t.io, job.id, job.kind, .finished, ok, formatted);
                t.agent_sessions.releaseLocked(job.id);
            } else _ = try t.background.inbox.?.enqueueBackground(gpa, t.io, job.id, job.kind, .finished, ok, formatted);
        }
    };

    pub fn start(bg: *Background, t: *Tools, gpa: std.mem.Allocator, kind: BackgroundEvent.Kind, args: []const u8, prompt: []const u8) ![]u8 {
        return bg.startWithId(t, gpa, kind, args, prompt, null);
    }

    pub fn startAgent(bg: *Background, t: *Tools, gpa: std.mem.Allocator, args: []const u8, prompt: []const u8, id: []const u8) ![]u8 {
        return bg.startWithId(t, gpa, .agent, args, prompt, id);
    }

    fn startWithId(bg: *Background, t: *Tools, gpa: std.mem.Allocator, kind: BackgroundEvent.Kind, args: []const u8, prompt: []const u8, task_id: ?[]const u8) ![]u8 {
        bg.mutex.lockUncancelable(t.io);
        defer bg.mutex.unlock(t.io);
        if (bg.cancel.load(.acquire)) return error.Canceled;
        if (bg.inbox == null) return error.BackgroundUnavailable;
        if (kind == .bash and bg.bash_active >= bash_limit) return error.BackgroundBashLimit;
        const log = bg.log orelse return error.BackgroundUnavailable;
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        const progress_id = task_id orelse try t.progress.add(gpa, t.io, kind, prompt, t.run_id, true);
        const id = try gpa.dupe(u8, progress_id);
        errdefer gpa.free(id);
        const copy = try gpa.dupe(u8, args);
        errdefer gpa.free(copy);
        const prompt_copy = try gpa.dupe(u8, prompt);
        errdefer gpa.free(prompt_copy);
        const result = try std.json.Stringify.valueAlloc(gpa, .{ .id = id }, .{});
        errdefer gpa.free(result);
        try bg.jobs.ensureUnusedCapacity(gpa, 1);
        job.* = .{ .t = t, .gpa = gpa, .args = copy, .prompt = prompt_copy, .id = id, .kind = kind, .run = t.run_id };
        try log.background(t.io, gpa, .{ .id = id, .kind = kind, .state = .started }, bg.turn_step);
        @import("../sandbox.zig").tool_identity = .{ .id = progress_id, .background = true };
        bg.jobs.appendAssumeCapacity(job);
        errdefer _ = bg.jobs.pop();
        if (kind == .bash) bg.bash_active += 1;
        job.thread = std.Thread.spawn(.{}, Job.work, .{job}) catch |err| {
            if (kind == .bash) bg.bash_active -= 1;
            try t.progress.update(gpa, t.io, .{ .id = id, .run = job.run, .kind = kind, .background = true, .prompt = prompt, .state = .failed });
            try job.deliver(.{ .err = @constCast(@errorName(err)) });
            job.done.store(true, .release);
            return result;
        };
        return result;
    }

    pub fn setTurnStep(bg: *Background, io: std.Io, step: u32) void {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        bg.turn_step = step;
    }

    pub fn pending(bg: *Background, io: std.Io) bool {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| if (!job.delivered) return true;
        return false;
    }

    pub fn pendingNames(bg: *Background, gpa: std.mem.Allocator, io: std.Io) ![]u8 {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        var names: std.ArrayList(u8) = .empty;
        errdefer names.deinit(gpa);
        for (bg.jobs.items) |job| {
            if (job.delivered) continue;
            if (names.items.len > 0) try names.appendSlice(gpa, ", ");
            try names.print(gpa, "{s} {s}", .{ @tagName(job.kind), job.id });
        }
        return names.toOwnedSlice(gpa);
    }

    pub fn delivered(bg: *Background, io: std.Io, id: []const u8) void {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| if (!job.delivered and std.mem.eql(u8, job.id, id)) {
            job.delivered = true;
            return;
        };
    }

    pub fn poll(bg: *Background, io: std.Io, ctx: *anyopaque, emit: *const fn (*anyopaque, BackgroundEvent) anyerror!void) !void {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| {
            if (!job.announced) {
                try emit(ctx, .{ .id = job.id, .kind = job.kind, .state = .started });
                job.announced = true;
            }
            if (job.done.load(.acquire)) if (job.failure) |err| {
                job.failure = null;
                // No inbox result will arrive after an internal worker failure.
                job.delivered = true;
                return err;
            };
        }
    }

    pub fn stop(bg: *Background, gpa: std.mem.Allocator) void {
        bg.cancel.store(true, .release);
        for (bg.jobs.items) |job| {
            if (job.thread) |thread| thread.join();
            gpa.free(job.args);
            gpa.free(job.prompt);
            gpa.free(job.id);
            gpa.destroy(job);
        }
        bg.jobs.clearAndFree(gpa);
        bg.inbox = null;
        bg.log = null;
    }
};

fn messageResult(gpa: std.mem.Allocator, kind: BackgroundEvent.Kind, id: []const u8, result: @import("../sandbox.zig").ToolResult) ![]u8 {
    if (result == .err) return if (kind == .agent)
        std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .id = id, .text = "", .changes = @as([]const struct {}, &.{}), .@"error" = result.err }, .{})
    else
        std.json.Stringify.valueAlloc(gpa, .{ .@"error" = result.err }, .{});
    if (kind == .bash) return gpa.dupe(u8, result.ok);
    const Parsed = struct { ok: bool, id: ?[]const u8 = null, text: []const u8, changes: std.json.Value, @"error": ?[]const u8 = null };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, result.ok, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(gpa, parsed.value, .{ .emit_null_optional_fields = false });
}

test "background worker failures are reported once and stop being pending" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/tmp" };
    defer t.background.jobs.deinit(testing.allocator);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var jobs: [2]Background.Job = undefined;
    for (&jobs, [_]BackgroundEvent.Kind{ .agent, .bash }, [_][]const u8{ "a1", "b2" }) |*job, kind, id| {
        job.* = .{
            .t = &t,
            .gpa = failing.allocator(),
            .args = @constCast("{}"),
            .prompt = @constCast("test"),
            .id = @constCast(id),
            .kind = kind,
            .run = 1,
        };
        try t.background.jobs.append(testing.allocator, job);
    }
    t.background.bash_active = 1;
    const Sink = struct {
        starts: usize = 0,

        fn emit(ctx: *anyopaque, event: BackgroundEvent) !void {
            const sink: *@This() = @ptrCast(@alignCast(ctx));
            try testing.expectEqual(.started, event.state);
            sink.starts += 1;
        }
    };
    var sink: Sink = .{};
    try testing.expect(t.background.pending(testing.io));
    try t.background.poll(testing.io, &sink, Sink.emit);
    try testing.expectEqual(@as(usize, 2), sink.starts);
    for (&jobs) |*job| {
        const thread = try std.Thread.spawn(.{}, Background.Job.work, .{job});
        thread.join();
        try testing.expect(job.done.load(.acquire));
        try testing.expectEqual(error.OutOfMemory, job.failure.?);
    }
    try testing.expectEqual(@as(usize, 0), t.background.bash_active);
    try testing.expectError(error.OutOfMemory, t.background.poll(testing.io, &sink, Sink.emit));
    try testing.expectEqual(null, jobs[0].failure);
    try testing.expect(jobs[0].delivered);
    try testing.expect(!jobs[1].delivered);
    try testing.expect(t.background.pending(testing.io));
    try testing.expectError(error.OutOfMemory, t.background.poll(testing.io, &sink, Sink.emit));
    try testing.expect(!t.background.pending(testing.io));
    try t.background.poll(testing.io, &sink, Sink.emit);
    try t.background.poll(testing.io, &sink, Sink.emit);
    try testing.expectEqual(@as(usize, 2), sink.starts);
}

test "background starts share per-kind foreground counters and leave terminal progress" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/session.jsonl", .{tmp.sub_path});
    defer testing.allocator.free(path);
    var log = try Log.create(testing.io, path);
    defer log.close(testing.io);
    var inbox: Inbox = .{};
    defer inbox.batch.deinit(testing.allocator);
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .cfg = .{ .model = "m", .base_url = "", .api_key = "" } };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    defer t.background.stop(testing.allocator);
    t.background.inbox = &inbox;
    t.background.log = &log;
    _ = try t.progress.add(testing.allocator, testing.io, .agent, "foreground", 1, false);
    var timing: @import("../sandbox.zig").RunTiming = .init(testing.io, .now(testing.io, .awake));
    var host = t.host();
    host.timing = &timing;
    const result = try @import("../sandbox.zig").eval(testing.allocator, testing.io, "[await tools.bash({command: 'true', background: true}), await tools.agent({prompt: 'child', background: true})]", .{}, host, null);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("[{\"id\":\"b1\"},{\"id\":\"a2\"}]", result.text);
    for (t.background.jobs.items) |job| {
        if (job.thread) |thread| thread.join();
        job.thread = null;
        try testing.expect(job.done.load(.acquire));
    }
    try testing.expectEqual(@as(usize, 2), timing.count);
    try testing.expectEqualStrings("b1", timing.entries[0].id.?);
    try testing.expectEqualStrings("a2", timing.entries[1].id.?);
    for (timing.entries[0..timing.count]) |call| try testing.expectEqual(@as(?bool, true), call.background);
    try testing.expectEqualStrings("a1", t.progress.slots.items[0].value.id);
    try testing.expectEqual(.done, t.progress.slots.items[1].value.state);
    try testing.expectEqual(.failed, t.progress.slots.items[2].value.state);
    try testing.expectEqual(@as(usize, 2), inbox.batch.items.items.len);
    t.background.stop(testing.allocator);
    try testing.expectEqualStrings("b1", timing.entries[0].id.?);
}

test "background agent completion publishes the task ID and releases its reservation" {
    const testing = std.testing;
    var inbox: Inbox = .{};
    defer inbox.batch.deinit(testing.allocator);
    var t: Tools = .{ .io = testing.io, .home = "/unused" };
    defer t.agent_sessions.deinit(testing.allocator);
    t.background.inbox = &inbox;
    try t.agent_sessions.add(testing.allocator, testing.io, "a1", "child", true);
    var job: Background.Job = .{ .t = &t, .gpa = testing.allocator, .args = @constCast("{}"), .prompt = @constCast("child"), .id = @constCast("a1"), .kind = .agent, .run = 1 };
    try job.deliver(.{ .err = @constCast("AgentFailed") });
    try testing.expectEqualStrings("a1", try t.agent_sessions.reserve(testing.io, "a1"));
    const result = try messageResult(testing.allocator, .agent, "a1", .{ .err = @constCast("AgentFailed") });
    defer testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a1", parsed.value.object.get("id").?.string);
    try testing.expect(!parsed.value.object.contains("session"));
    try testing.expect(!parsed.value.object.get("ok").?.bool);
}
