const std = @import("std");
const Progress = @import("../session/events.zig").Progress;

pub const Queue = struct {
    mutex: std.Io.Mutex = .init,
    slots: std.ArrayList(Slot) = .empty,
    ids: std.ArrayList([]const u8) = .empty,
    next_agent_id: u64 = 1,
    next_bash_id: u64 = 1,
    sink: ?struct { ctx: *anyopaque, emit: *const fn (*anyopaque, Progress) anyerror!void } = null,

    const Slot = struct { value: Progress, dirty: bool = true, sent: ?std.Io.Timestamp = null };

    // IDs outlive cleared progress slots because Step call logs can span several Runs.
    pub fn add(q: *Queue, gpa: std.mem.Allocator, io: std.Io, kind: @FieldType(Progress, "kind"), prompt: []const u8, run: usize, background: bool) ![]const u8 {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const next = if (kind == .agent) &q.next_agent_id else &q.next_bash_id;
        if (next.* == std.math.maxInt(u64)) return error.IdExhausted;
        const id = try std.fmt.allocPrint(gpa, "{s}{d}", .{ if (kind == .agent) "a" else "b", next.* });
        errdefer gpa.free(id);
        var value = try (Progress{ .id = id, .kind = kind, .prompt = prompt, .run = run, .background = background, .state = .queued }).clone(gpa);
        errdefer value.deinit(gpa);
        try q.ids.ensureUnusedCapacity(gpa, 1);
        try q.slots.append(gpa, .{ .value = value });
        q.ids.appendAssumeCapacity(id);
        next.* += 1;
        return id;
    }

    pub fn update(q: *Queue, gpa: std.mem.Allocator, io: std.Io, value: Progress) !void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        for (q.slots.items) |*slot| {
            if (!std.mem.eql(u8, slot.value.id, value.id)) continue;
            const copy = try value.clone(gpa);
            slot.value.deinit(gpa);
            slot.value = copy;
            slot.dirty = true;
            return;
        }
        return error.UnknownProgressId;
    }

    // Session serializes sink calls; tool threads only replace owned snapshots.
    pub fn drain(q: *Queue, io: std.Io) !void {
        try q.drainAt(io, std.Io.Clock.awake.now(io));
    }

    fn drainAt(q: *Queue, io: std.Io, now: std.Io.Timestamp) !void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const sink = q.sink orelse return;
        for (q.slots.items) |*slot| {
            if (!slot.dirty) continue;
            if (slot.value.state == .queued or slot.value.state == .working)
                if (slot.sent) |sent| if (sent.durationTo(now).toMilliseconds() < 1000) continue;
            try sink.emit(sink.ctx, slot.value);
            slot.sent = now;
            slot.dirty = false;
        }
    }

    pub fn highWater(q: *Queue, io: std.Io) @import("../session/events.zig").TaskIds {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return .{ .agent = q.next_agent_id - 1, .bash = q.next_bash_id - 1 };
    }

    pub fn deinit(q: *Queue, gpa: std.mem.Allocator) void {
        q.clear(gpa);
        for (q.ids.items) |id| gpa.free(id);
        q.ids.deinit(gpa);
    }

    // Called after tool joins, or once every background result has reached the inbox.
    pub fn clear(q: *Queue, gpa: std.mem.Allocator) void {
        for (q.slots.items) |*slot| slot.value.deinit(gpa);
        q.slots.clearAndFree(gpa);
    }
};

test "progress IDs have independent session counters and updates preserve creation order" {
    const t = std.testing;
    var q: Queue = .{};
    defer q.deinit(t.allocator);
    const a1 = try q.add(t.allocator, t.io, .agent, "first", 1, false);
    const b1 = try q.add(t.allocator, t.io, .bash, "second", 1, true);
    const a2 = try q.add(t.allocator, t.io, .agent, "third", 2, true);
    try t.expectEqualStrings("a1", a1);
    try t.expectEqualStrings("b1", b1);
    try t.expectEqualStrings("a2", a2);
    try q.update(t.allocator, t.io, .{ .id = a2, .prompt = "updated", .run = 2, .background = true, .state = .done });
    try q.update(t.allocator, t.io, .{ .id = b1, .kind = .bash, .prompt = "second", .background = true, .elapsed_ms = 1000 });
    try t.expectEqualStrings(a1, q.slots.items[0].value.id);
    try t.expectEqualStrings(b1, q.slots.items[1].value.id);
    try t.expectEqualStrings(a2, q.slots.items[2].value.id);
    try t.expectEqualStrings("updated", q.slots.items[2].value.prompt);
    try t.expect(q.slots.items[2].value.background);
    try t.expectEqual(@as(usize, 2), q.slots.items[2].value.run);
    try t.expectError(error.UnknownProgressId, q.update(t.allocator, t.io, .{ .id = "a99", .prompt = "missing" }));
    q.clear(t.allocator);
    try t.expectEqualStrings("a1", a1);
    try t.expectEqualStrings("a3", try q.add(t.allocator, t.io, .agent, "next turn", 1, false));
    try t.expectEqualStrings("b2", try q.add(t.allocator, t.io, .bash, "next run", 1, false));
}

test "progress coalesces working updates per second but delivers terminal snapshots immediately" {
    const t = std.testing;
    const Capture = struct {
        calls: usize = 0,
        step: u32 = 0,
        state: @FieldType(Progress, "state") = .queued,
        fn emit(ctx: *anyopaque, value: Progress) !void {
            const capture: *@This() = @ptrCast(@alignCast(ctx));
            capture.calls += 1;
            capture.step = value.step;
            capture.state = value.state;
        }
    };
    var capture: Capture = .{};
    var q: Queue = .{ .sink = .{ .ctx = &capture, .emit = Capture.emit } };
    defer q.deinit(t.allocator);
    const id = try q.add(t.allocator, t.io, .agent, "one", 1, false);
    try q.drainAt(t.io, .zero);
    try t.expectEqual(@as(usize, 1), capture.calls);
    try q.update(t.allocator, t.io, .{ .id = id, .prompt = "one", .step = 2 });
    try q.update(t.allocator, t.io, .{ .id = id, .prompt = "one", .step = 3 });
    try q.drainAt(t.io, .fromNanoseconds(999 * std.time.ns_per_ms));
    try t.expectEqual(@as(usize, 1), capture.calls);
    try q.drainAt(t.io, .fromNanoseconds(std.time.ns_per_s));
    try t.expectEqual(@as(usize, 2), capture.calls);
    try t.expectEqual(@as(u32, 3), capture.step);
    try q.update(t.allocator, t.io, .{ .id = id, .prompt = "one", .step = 4, .state = .done });
    try q.drainAt(t.io, .fromNanoseconds(std.time.ns_per_s));
    try t.expectEqual(@as(usize, 3), capture.calls);
    try t.expectEqual(.done, capture.state);
    try q.drainAt(t.io, .fromNanoseconds(2 * std.time.ns_per_s));
    try t.expectEqual(@as(usize, 3), capture.calls);
}
