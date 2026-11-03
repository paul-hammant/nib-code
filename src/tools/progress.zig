const std = @import("std");
const Progress = @import("../session/events.zig").Progress;

pub const Queue = struct {
    mutex: std.Io.Mutex = .init,
    slots: std.ArrayList(Slot) = .empty,
    sink: ?struct { ctx: *anyopaque, emit: *const fn (*anyopaque, Progress) anyerror!void } = null,

    const Slot = struct { value: Progress, dirty: bool = true, sent: ?std.Io.Timestamp = null };

    pub fn add(q: *Queue, gpa: std.mem.Allocator, io: std.Io, prompt: []const u8) !usize {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const id = q.slots.items.len + 1;
        var value = try (Progress{ .agent = id, .prompt = prompt, .state = .queued }).clone(gpa);
        errdefer value.deinit(gpa);
        try q.slots.append(gpa, .{ .value = value });
        return id;
    }

    pub fn update(q: *Queue, gpa: std.mem.Allocator, io: std.Io, value: Progress) !void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const copy = try value.clone(gpa);
        const slot = &q.slots.items[value.agent - 1];
        slot.value.deinit(gpa);
        slot.value = copy;
        slot.dirty = true;
    }

    // Only the Run thread calls the sink; tool threads only replace owned snapshots.
    pub fn drain(q: *Queue, io: std.Io) !void {
        try q.drainAt(io, std.Io.Clock.awake.now(io));
    }

    fn drainAt(q: *Queue, io: std.Io, now: std.Io.Timestamp) !void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const sink = q.sink orelse return;
        for (q.slots.items) |*slot| {
            if (!slot.dirty) continue;
            if (slot.sent) |sent| if (sent.durationTo(now).toMilliseconds() < 1000) continue;
            try sink.emit(sink.ctx, slot.value);
            slot.sent = now;
            slot.dirty = false;
        }
    }

    // Called before/after eval, when all tool threads have been joined.
    pub fn clear(q: *Queue, gpa: std.mem.Allocator) void {
        for (q.slots.items) |*slot| slot.value.deinit(gpa);
        q.slots.clearAndFree(gpa);
    }
};

test "progress coalesces per child for a second, including terminal updates" {
    const testing = std.testing;
    const Capture = struct {
        calls: usize = 0,
        step: u32 = 0,
        state: @FieldType(Progress, "state") = .queued,
        fn emit(ctx: *anyopaque, value: Progress) !void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.calls += 1;
            c.step = value.step;
            c.state = value.state;
        }
    };
    var capture: Capture = .{};
    var q: Queue = .{ .sink = .{ .ctx = &capture, .emit = Capture.emit } };
    defer q.clear(testing.allocator);
    try testing.expectEqual(@as(usize, 1), try q.add(testing.allocator, testing.io, "one"));
    try q.drainAt(testing.io, .zero);
    try testing.expectEqual(@as(usize, 1), capture.calls);
    try q.update(testing.allocator, testing.io, .{ .agent = 1, .prompt = "one", .step = 2 });
    try q.update(testing.allocator, testing.io, .{ .agent = 1, .prompt = "one", .step = 3, .state = .done });
    try q.drainAt(testing.io, .fromNanoseconds(999 * std.time.ns_per_ms));
    try testing.expectEqual(@as(usize, 1), capture.calls);
    try testing.expectEqual(@as(usize, 2), try q.add(testing.allocator, testing.io, "two"));
    try q.drainAt(testing.io, .fromNanoseconds(999 * std.time.ns_per_ms));
    try testing.expectEqual(@as(usize, 2), capture.calls);
    try q.drainAt(testing.io, .fromNanoseconds(std.time.ns_per_s));
    try testing.expectEqual(@as(usize, 3), capture.calls);
    try testing.expectEqual(@as(u32, 3), capture.step);
    try testing.expectEqual(.done, capture.state);
    try q.drainAt(testing.io, .fromNanoseconds(2 * std.time.ns_per_s));
    try testing.expectEqual(@as(usize, 3), capture.calls);
}
