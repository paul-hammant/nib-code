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
            if (t.background.cancel.load(.acquire)) return;
            const json = try messageResult(gpa, job.kind, result);
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
        const progress_id = try t.progress.add(gpa, t.io, kind, prompt, t.run_id, true);
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
            if (job.done.load(.acquire)) if (job.failure) |err| return err;
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
