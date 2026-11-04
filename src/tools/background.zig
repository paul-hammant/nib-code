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
    next_id: u64 = 1,
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
        progress: usize,
        run: usize,
        started: std.Io.Clock.Timestamp,
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        announced: bool = false,
        delivered: bool = false,
        failure: ?anyerror = null,

        fn work(job: *Job) void {
            job.finish() catch |err| {
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
                .agent => agent.execute(t, gpa, job.args, &t.background.cancel, job.progress, job.run, job.id),
                .bash => @import("bash.zig").executeBackground(t, gpa, job.args, &t.background.cancel, .{ .agent = job.progress, .run = job.run, .background_id = job.id, .kind = .bash, .prompt = "" }),
            } catch |err| try @import("../tools.zig").fail(gpa, "{s}", .{@errorName(err)});
            defer switch (result) {
                inline else => |bytes| gpa.free(bytes),
            };
            try job.deliver(result);
        }

        fn deliver(job: *Job, result: @import("../sandbox.zig").ToolResult) !void {
            const t = job.t;
            const gpa = job.gpa;
            if (t.background.cancel.load(.acquire)) return;
            const json = try messageResult(gpa, job.kind, result);
            defer gpa.free(json);
            const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
            defer parsed.deinit();
            const ok = switch (job.kind) {
                .agent => parsed.value.object.get("ok").?.bool,
                .bash => if (parsed.value.object.get("exit_code")) |code| code == .integer and code.integer == 0 else false,
            };
            if (job.kind == .bash) try t.progress.update(gpa, t.io, .{ .agent = job.progress, .run = job.run, .kind = .bash, .background_id = job.id, .prompt = job.prompt, .elapsed_ms = @intCast(@max(job.started.untilNow(t.io).raw.toMilliseconds(), 0)), .state = if (ok) .done else .failed });
            const prefix = try std.fmt.allocPrint(gpa, "[background {s} {s} finished]\n", .{ @tagName(job.kind), job.id });
            defer gpa.free(prefix);
            const formatted = try output.formatMessage(gpa, prefix, json);
            defer gpa.free(formatted);
            _ = try t.background.inbox.?.enqueueBackground(gpa, t.io, job.id, job.kind, .finished, ok, formatted);
        }
    };

    pub fn start(bg: *Background, t: *Tools, gpa: std.mem.Allocator, kind: BackgroundEvent.Kind, args: []const u8, prompt: []const u8) ![]u8 {
        bg.mutex.lockUncancelable(t.io);
        defer bg.mutex.unlock(t.io);
        if (bg.cancel.load(.acquire)) return error.Canceled;
        if (bg.inbox == null) return error.BackgroundUnavailable;
        if (kind == .bash and bg.bash_active >= bash_limit) return error.BackgroundBashLimit;
        const log = bg.log orelse return error.BackgroundUnavailable;
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        const id = try std.fmt.allocPrint(gpa, "{s}{d}", .{ if (kind == .agent) "a" else "b", bg.next_id });
        errdefer gpa.free(id);
        const copy = try gpa.dupe(u8, args);
        errdefer gpa.free(copy);
        const prompt_copy = try gpa.dupe(u8, prompt);
        errdefer gpa.free(prompt_copy);
        const result = try std.json.Stringify.valueAlloc(gpa, .{ .id = id }, .{});
        errdefer gpa.free(result);
        try bg.jobs.ensureUnusedCapacity(gpa, 1);
        const progress = try t.progress.add(gpa, t.io, prompt);
        job.* = .{ .t = t, .gpa = gpa, .args = copy, .prompt = prompt_copy, .id = id, .kind = kind, .progress = progress, .run = t.run_id, .started = .now(t.io, .awake) };
        try t.progress.update(gpa, t.io, .{ .agent = progress, .run = t.run_id, .kind = kind, .background_id = id, .prompt = prompt, .state = .queued });
        try log.background(t.io, gpa, .{ .id = id, .kind = kind, .state = .started }, bg.turn_step);
        bg.next_id += 1;
        bg.jobs.appendAssumeCapacity(job);
        errdefer _ = bg.jobs.pop();
        if (kind == .bash) bg.bash_active += 1;
        job.thread = std.Thread.spawn(.{}, Job.work, .{job}) catch |err| {
            if (kind == .bash) bg.bash_active -= 1;
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

    pub fn delivered(bg: *Background, io: std.Io, id: []const u8) void {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| if (std.mem.eql(u8, job.id, id)) {
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

fn messageResult(gpa: std.mem.Allocator, kind: BackgroundEvent.Kind, result: @import("../sandbox.zig").ToolResult) ![]u8 {
    if (result == .err) return if (kind == .agent)
        std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .text = "", .changes = @as([]const struct {}, &.{}), .@"error" = result.err }, .{})
    else
        std.json.Stringify.valueAlloc(gpa, .{ .@"error" = result.err }, .{});
    if (kind == .bash) return gpa.dupe(u8, result.ok);
    const Parsed = struct { ok: bool, text: []const u8, changes: std.json.Value, @"error": ?[]const u8 = null };
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
            .progress = 0,
            .run = 1,
            .started = .now(testing.io, .awake),
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
