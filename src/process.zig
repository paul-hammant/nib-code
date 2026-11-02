const std = @import("std");

pub const Result = struct {
    term: std.process.Child.Term,
    output: []u8,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, options: std.process.SpawnOptions, cancel: *const std.atomic.Value(bool), timeout_ms: i64) !Result {
    var opts = options;
    opts.pgid = 0;
    var child = try std.process.spawn(io, opts);
    const pid = child.id.?;
    defer child.kill(io);
    defer std.posix.kill(-pid, .KILL) catch {};

    var streams: std.Io.File.MultiReader.Buffer(1) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, streams.toStreams(), &.{child.stdout.?});
    defer mr.deinit();
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
    while (true) {
        try check(io, cancel, deadline);
        mr.fill(4096, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {},
            else => return err,
        };
        if (mr.reader(0).buffered().len > 8 * 1024 * 1024) return error.OutputLimit;
    }
    try mr.checkAnyError();
    const Wait = struct {
        fn work(c: *std.process.Child, i: std.Io, done: *std.Io.Event) !std.process.Child.Term {
            defer done.set(i);
            return c.wait(i);
        }
    };
    var done: std.Io.Event = .unset;
    var waiter = try io.concurrent(Wait.work, .{ &child, io, &done });
    defer _ = waiter.await(io) catch {};
    while (!done.isSet()) {
        check(io, cancel, deadline) catch |err| {
            std.posix.kill(-pid, .KILL) catch {};
            return err;
        };
        done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            else => {
                std.posix.kill(-pid, .KILL) catch {};
                return err;
            },
        };
    }
    return .{ .term = try waiter.await(io), .output = try mr.toOwnedSlice(0) };
}

fn check(io: std.Io, cancel: *const std.atomic.Value(bool), deadline: std.Io.Clock.Timestamp) !void {
    if (cancel.load(.acquire)) return error.Canceled;
    if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return error.TimedOut;
}
