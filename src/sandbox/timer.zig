const std = @import("std");

pub const Timer = struct {
    deadline: std.Io.Clock.Timestamp,

    pub fn init(io: std.Io, ms: u31) Timer {
        return .{ .deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromMilliseconds(ms), .clock = .awake }) };
    }

    pub fn remaining(t: Timer, io: std.Io) i64 {
        const ns = std.Io.Clock.Timestamp.now(io, .awake).durationTo(t.deadline).raw.toNanoseconds();
        return @intCast(@divFloor(@max(0, ns) + std.time.ns_per_ms - 1, std.time.ns_per_ms));
    }

    pub fn before(t: Timer, other: Timer) bool {
        return t.deadline.compare(.lt, other.deadline);
    }
};
