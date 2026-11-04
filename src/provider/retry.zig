const std = @import("std");
const p = @import("../provider.zig");
const codex = @import("codex.zig");

pub const max_attempts = 5;

/// Reason slices are valid only during the callback.
pub const Event = union(enum) {
    started,
    finished,
    retry: struct { attempt: u32, delay_ms: u64, reason: []const u8 },
    failed: struct { attempt: u32, err: anyerror, reason: []const u8 },
};

pub const Sink = struct {
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, event: Event) anyerror!void,

    fn emit(s: ?Sink, event: Event) !void {
        if (s) |target| try target.onEvent(target.ctx, event);
    }
};

/// Reply uses `out`; error detail uses `gpa` and is caller-owned.
pub fn complete(
    gpa: std.mem.Allocator,
    out: std.mem.Allocator,
    client: *std.http.Client,
    cfg: p.Config,
    cache_key: []const u8,
    messages: []const p.Message,
    tools_json: []const u8,
    max_tokens: ?u32,
    sink: p.Sink,
    cancel: *const std.atomic.Value(bool),
    detail: *?[]u8,
    attempts: *u32,
    retry_sink: ?Sink,
) !p.Reply {
    return completeWith(p.stream, sleep, gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, sink, cancel, detail, attempts, retry_sink);
}

const Forward = struct {
    sink: p.Sink,
    emitted: bool = false,

    fn onData(ctx: *anyopaque) !void {
        const f: *@This() = @ptrCast(@alignCast(ctx));
        try f.sink.received();
    }

    fn onDelta(ctx: *anyopaque, kind: p.Kind, text: []const u8) !void {
        const f: *@This() = @ptrCast(@alignCast(ctx));
        f.emitted = true;
        try f.sink.onDelta(f.sink.ctx, kind, text);
    }
};

fn completeWith(
    comptime request: anytype,
    comptime wait: anytype,
    gpa: std.mem.Allocator,
    out: std.mem.Allocator,
    client: *std.http.Client,
    cfg: p.Config,
    cache_key: []const u8,
    messages: []const p.Message,
    tools_json: []const u8,
    max_tokens: ?u32,
    sink: p.Sink,
    cancel: *const std.atomic.Value(bool),
    detail: *?[]u8,
    attempts: *u32,
    retry_sink: ?Sink,
) !p.Reply {
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        attempts.* = attempt;
        var fwd: Forward = .{ .sink = sink };
        const forwarded: p.Sink = .{ .ctx = &fwd, .onDelta = Forward.onDelta, .onData = Forward.onData, .timing = sink.timing };
        return response: {
            try Sink.emit(retry_sink, .started);
            defer Sink.emit(retry_sink, .finished) catch {};
            break :response request(gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, forwarded, cancel, detail);
        } catch |err| {
            if (err == error.Canceled or cancel.load(.acquire)) return err;
            const is_codex = cfg.provider == .codex;
            if ((!is_codex and fwd.emitted and !sink.replay_safe) or attempt == max_attempts or !transient(err)) {
                try Sink.emit(retry_sink, .{ .failed = .{ .attempt = attempt, .err = err, .reason = detail.* orelse @errorName(err) } });
                return err;
            }
            var delay_ms = @as(u64, 1000) << @intCast(attempt - 1);
            if (is_codex and err == error.RateLimited) if (detail.*) |message| {
                delay_ms = codex.retryDelayMs(message) orelse delay_ms;
            };
            try Sink.emit(retry_sink, .{ .retry = .{ .attempt = attempt, .delay_ms = delay_ms, .reason = detail.* orelse @errorName(err) } });
            if (detail.*) |d| gpa.free(d);
            detail.* = null;
            try wait(client.io, delay_ms, cancel);
            continue;
        };
    }
}

fn transient(err: anyerror) bool {
    return switch (err) {
        error.HttpStatus, error.InvalidCredentials, error.ProviderFailed, error.Canceled, error.OutOfMemory, error.TooManyToolCalls => false,
        else => true,
    };
}

fn sleep(io: std.Io, ms: u64, cancel: *const std.atomic.Value(bool)) !void {
    var left = ms;
    while (left > 0) {
        if (cancel.load(.acquire)) return error.Canceled;
        const step = @min(left, 100);
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(@intCast(step)), .clock = .awake }, io);
        left -= step;
    }
}

const TestRequest = struct {
    calls: u32 = 0,
    failures: u32 = 1,
    failure: anyerror = error.HttpTransient,
    message: []const u8 = "temporary failure",
    emit_delta: bool = false,
    deltas: usize = 0,
    received: usize = 0,
    retries: usize = 0,
    delays: [max_attempts - 1]u64 = undefined,
    failed: ?anyerror = null,
    events: std.ArrayList(std.meta.Tag(Event)) = .empty,
    cancel: std.atomic.Value(bool) = .init(false),
    cancel_on_retry: bool = false,
    replay_safe: bool = false,

    fn request(gpa: std.mem.Allocator, _: std.mem.Allocator, _: *std.http.Client, _: p.Config, _: []const u8, _: []const p.Message, tools_json: []const u8, _: ?u32, sink: p.Sink, _: *const std.atomic.Value(bool), detail: *?[]u8) !p.Reply {
        const state: *@This() = @ptrCast(@alignCast(sinkContext(sink)));
        state.calls += 1;
        try std.testing.expectEqualStrings("[]", tools_json);
        try sink.received();
        if (state.emit_delta) try sink.onDelta(sink.ctx, .text, "delta");
        if (state.calls <= state.failures) {
            detail.* = try gpa.dupe(u8, state.message);
            return state.failure;
        }
        return .{ .text = "done", .tool_calls = &.{}, .usage = .{ .completion_tokens = 7 } };
    }

    fn sinkContext(sink: p.Sink) *anyopaque {
        const forward: *Forward = @ptrCast(@alignCast(sink.ctx));
        return forward.sink.ctx;
    }

    fn delta(ctx: *anyopaque, _: p.Kind, _: []const u8) !void {
        const state: *@This() = @ptrCast(@alignCast(ctx));
        state.deltas += 1;
    }

    fn data(ctx: *anyopaque) !void {
        const state: *@This() = @ptrCast(@alignCast(ctx));
        state.received += 1;
    }

    fn event(ctx: *anyopaque, value: Event) !void {
        const state: *@This() = @ptrCast(@alignCast(ctx));
        switch (value) {
            .retry => |retry| {
                try std.testing.expectEqual(.finished, state.events.items[state.events.items.len - 1]);
                try std.testing.expectEqual(state.calls, retry.attempt);
                try std.testing.expectEqualStrings(state.message, retry.reason);
                state.delays[state.retries] = retry.delay_ms;
                state.retries += 1;
                if (state.cancel_on_retry) state.cancel.store(true, .release);
            },
            .failed => |failure| {
                try std.testing.expectEqual(.finished, state.events.items[state.events.items.len - 1]);
                try std.testing.expectEqual(state.calls, failure.attempt);
                try std.testing.expectEqualStrings(state.message, failure.reason);
                state.failed = failure.err;
            },
            else => {},
        }
        try state.events.append(std.testing.allocator, value);
    }

    fn noWait(_: std.Io, _: u64, cancel: *const std.atomic.Value(bool)) !void {
        if (cancel.load(.acquire)) return error.Canceled;
    }

    fn run(state: *@This(), id: p.Id, quiet: bool, comptime wait: anytype) !p.Reply {
        const t = std.testing;
        var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
        defer client.deinit();
        var detail: ?[]u8 = null;
        defer if (detail) |d| t.allocator.free(d);
        var attempts: u32 = 0;
        defer t.expectEqual(state.calls, attempts) catch @panic("incorrect attempt count");
        const reply = completeWith(request, wait, t.allocator, t.allocator, &client, .{ .provider = id, .base_url = "", .api_key = "", .model = "m" }, "key", &.{}, "[]", null, .{ .ctx = state, .onDelta = delta, .onData = data, .replay_safe = state.replay_safe }, &state.cancel, &detail, &attempts, if (quiet) null else .{ .ctx = state, .onEvent = event }) catch |err| {
            if (err == error.Canceled and state.cancel_on_retry) try t.expectEqual(@as(?[]u8, null), detail);
            if (detail) |d| try t.expectEqualStrings(state.message, d);
            return err;
        };
        try t.expectEqual(@as(?[]u8, null), detail);
        return reply;
    }
};

test "shared retry forwards data and orders activity before exponential retry notices" {
    const t = std.testing;
    for ([_]p.Id{ .chat_completions, .codex }) |id| {
        var state: TestRequest = .{ .failures = 2 };
        defer state.events.deinit(t.allocator);
        const reply = try state.run(id, false, TestRequest.noWait);
        try t.expectEqualStrings("done", reply.text);
        try t.expectEqual(@as(u64, 7), reply.usage.completion_tokens);
        try t.expectEqual(@as(u32, 3), state.calls);
        try t.expectEqual(@as(usize, 3), state.received);
        try t.expectEqual(@as(usize, 2), state.retries);
        try t.expectEqualSlices(u64, &.{ 1000, 2000 }, state.delays[0..2]);
        try t.expectEqualSlices(std.meta.Tag(Event), &.{ .started, .finished, .retry, .started, .finished, .retry, .started, .finished }, state.events.items);
    }
}

test "shared retry only replays emitted deltas for Codex" {
    const t = std.testing;
    for ([_]p.Id{ .chat_completions, .codex }) |id| {
        var state: TestRequest = .{ .emit_delta = true };
        defer state.events.deinit(t.allocator);
        if (id == .codex) {
            _ = try state.run(id, false, TestRequest.noWait);
            try t.expectEqual(@as(u32, 2), state.calls);
            try t.expectEqual(@as(usize, 2), state.deltas);
        } else {
            try t.expectError(error.HttpTransient, state.run(id, false, TestRequest.noWait));
            try t.expectEqual(@as(u32, 1), state.calls);
            try t.expectEqual(@as(usize, 1), state.deltas);
            try t.expectEqual(error.HttpTransient, state.failed.?);
        }
    }
}

test "shared retry limits attempts and preserves terminal errors and detail" {
    const t = std.testing;
    for ([_]anyerror{ error.HttpTransient, error.HttpStatus, error.InvalidCredentials, error.ProviderFailed, error.OutOfMemory, error.TooManyToolCalls, error.Canceled }) |err| {
        var state: TestRequest = .{ .failures = max_attempts, .failure = err };
        defer state.events.deinit(t.allocator);
        try t.expectError(err, state.run(.codex, false, TestRequest.noWait));
        try t.expectEqual(@as(u32, if (err == error.HttpTransient) max_attempts else 1), state.calls);
        if (err == error.Canceled) {
            try t.expectEqual(@as(?anyerror, null), state.failed);
        } else {
            try t.expectEqual(err, state.failed.?);
        }
    }
}

test "shared retry accepts Codex Retry-After detail and supports a silent caller" {
    const t = std.testing;
    var state: TestRequest = .{ .failure = error.RateLimited, .message = "try again in 0.25s" };
    defer state.events.deinit(t.allocator);
    _ = try state.run(.codex, false, TestRequest.noWait);
    try t.expectEqual(@as(u64, 250), state.delays[0]);
    var quiet: TestRequest = .{ .emit_delta = true };
    defer quiet.events.deinit(t.allocator);
    _ = try quiet.run(.codex, true, TestRequest.noWait);
    try t.expectEqual(@as(u32, 2), quiet.calls);
    try t.expectEqual(@as(usize, 2), quiet.received);
    try t.expectEqual(@as(usize, 0), quiet.events.items.len);
}

test "shared retry cancellation interrupts backoff after the retry notice" {
    const t = std.testing;
    var state: TestRequest = .{ .cancel_on_retry = true };
    defer state.events.deinit(t.allocator);
    try t.expectError(error.Canceled, state.run(.codex, false, sleep));
    try t.expectEqual(@as(u32, 1), state.calls);
    try t.expectEqualSlices(std.meta.Tag(Event), &.{ .started, .finished, .retry }, state.events.items);
}

test "buffered model callers can retry Chat deltas without weakening visible streaming" {
    const t = std.testing;
    var state: TestRequest = .{ .emit_delta = true, .replay_safe = true };
    defer state.events.deinit(t.allocator);
    _ = try state.run(.chat_completions, true, TestRequest.noWait);
    try t.expectEqual(@as(u32, 2), state.calls);
    try t.expectEqual(@as(usize, 2), state.deltas);
}

test "idle timeout retries preserve visible streaming and replay-safe rules" {
    const t = std.testing;
    for ([_]p.Id{ .chat_completions, .codex }) |id| {
        for ([_]bool{ false, true }) |emitted| {
            for ([_]bool{ false, true }) |safe| {
                var state: TestRequest = .{ .failure = error.StreamIdleTimeout, .emit_delta = emitted, .replay_safe = safe };
                defer state.events.deinit(t.allocator);
                if (id == .chat_completions and emitted and !safe) {
                    try t.expectError(error.StreamIdleTimeout, state.run(id, false, TestRequest.noWait));
                    try t.expectEqual(@as(u32, 1), state.calls);
                } else {
                    _ = try state.run(id, false, TestRequest.noWait);
                    try t.expectEqual(@as(u32, 2), state.calls);
                }
            }
        }
    }
}
