const std = @import("std");
const p = @import("../provider.zig");

pub fn run(io: std.Io, cancel: *const std.atomic.Value(bool), comptime request: anytype, args: anytype) !p.Reply {
    if (cancel.load(.acquire)) return error.Canceled;
    const Result = union(enum) { reply: anyerror!p.Reply, canceled: void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    // Join the request before its borrowed allocators, sink and detail can be reused.
    defer select.cancelDiscard();
    try select.concurrent(.reply, request, args);
    try select.concurrent(.canceled, watch, .{ io, cancel });
    const result = try select.await();
    if (cancel.load(.acquire)) return error.Canceled;
    return switch (result) {
        .reply => |reply| reply,
        .canceled => error.Canceled,
    };
}

fn watch(io: std.Io, cancel: *const std.atomic.Value(bool)) void {
    while (!cancel.load(.acquire)) {
        std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, io) catch return;
    }
}

test "stream cancellation skips pre-canceled requests and joins active requests without losing deltas" {
    const State = struct {
        cancel: std.atomic.Value(bool) = .init(true),
        text: []const u8 = "",
        called: bool = false,
        cleaned: bool = false,

        fn delta(ctx: *anyopaque, _: p.Kind, text: []const u8) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.text = text;
            state.cancel.store(true, .release);
        }

        fn request(io: std.Io, state: *@This(), sink: p.Sink) anyerror!p.Reply {
            state.called = true;
            defer state.cleaned = true;
            try sink.onDelta(sink.ctx, .text, "partial answer");
            try std.Io.Clock.Duration.sleep(.{ .raw = .fromSeconds(30), .clock = .awake }, io);
            return error.UnexpectedEndOfRequest;
        }
    };
    var state: State = .{};
    const sink: p.Sink = .{ .ctx = &state, .onDelta = State.delta };
    try std.testing.expectError(error.Canceled, run(std.testing.io, &state.cancel, State.request, .{ std.testing.io, &state, sink }));
    try std.testing.expect(!state.called);
    state.cancel.store(false, .release);
    const start = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expectError(error.Canceled, run(std.testing.io, &state.cancel, State.request, .{ std.testing.io, &state, sink }));
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds() < 2000);
    try std.testing.expect(state.called and state.cleaned);
    try std.testing.expectEqualStrings("partial answer", state.text);
}

test "completed stream cancels its watcher" {
    const Request = struct {
        fn request() anyerror!p.Reply {
            return .{ .text = "complete", .tool_calls = &.{}, .usage = .{} };
        }
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    const reply = try run(std.testing.io, &cancel, Request.request, .{});
    try std.testing.expectEqualStrings("complete", reply.text);
}
