const std = @import("std");
const sandbox = @import("../sandbox.zig");
const t = std.testing;

const Host = struct {
    calls: std.atomic.Value(usize) = .init(0),
    released: std.atomic.Value(bool) = .init(false),

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, _: []const u8) sandbox.ToolResult {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        if (std.mem.eql(u8, name, "block")) {
            while (!self.released.load(.acquire))
                std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1), .clock = .awake }, t.io) catch unreachable;
        }
        return .{ .ok = gpa.dupe(u8, "true") catch unreachable };
    }

    fn admit(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "release")) self.released.store(true, .release);
        return null;
    }

    fn host(self: *@This()) sandbox.Host {
        return .{ .ctx = self, .names = &.{ "sleep", "echo", "block", "release" }, .call = call, .admit = admit, .cancel = &self.released };
    }
};

fn run(code: []const u8, limits: sandbox.Limits, host: sandbox.Host) !sandbox.Outcome {
    return sandbox.eval(t.allocator, t.io, code, limits, host, null);
}

test "sleep validates milliseconds without coercion or host dispatch" {
    var host: Host = .{};
    const result = try run(
        \\const bad = [undefined, null, true, '1', {}, [], NaN, Infinity, -Infinity, -1, .5, 2147483648];
        \\const errors = await Promise.all(bad.map(ms => tools.sleep(ms).then(() => false, e => e.message === 'sleep: ms must be an integer in 0..2147483647')));
        \\[errors.every(Boolean), await tools.sleep(0), await tools.sleep(-0), await tools.sleep(1.0)];
    , .{}, host.host());
    defer result.deinit(t.allocator);
    try t.expect(result.ok);
    try t.expectEqualStrings("[true,null,null,null]", result.text);
    try t.expectEqual(@as(usize, 0), host.calls.load(.monotonic));
}

test "sleep waits asynchronously and excludes waiting from JS budget" {
    var host: Host = .{};
    const start = std.Io.Clock.Timestamp.now(t.io, .awake);
    const result = try run(
        \\let settled = false;
        \\const pending = tools.sleep(120).then(value => { settled = true; return value; });
        \\const before = settled;
        \\const value = await pending;
        \\await tools.sleep(120);
        \\[before, settled, value];
    , .{ .timeout_ms = 50 }, host.host());
    defer result.deinit(t.allocator);
    try t.expect(result.ok);
    try t.expectEqualStrings("[false,true,null]", result.text);
    try t.expect(start.durationTo(.now(t.io, .awake)).raw.toMilliseconds() >= 240);
}

test "sleep does not reset accumulated JS budget" {
    var host: Host = .{};
    const result = try run(
        \\const spin = () => { const start = Date.now(); while (Date.now() - start < 65) {} };
        \\spin(); await tools.sleep(120); spin();
    , .{ .timeout_ms = 100 }, host.host());
    defer result.deinit(t.allocator);
    try t.expect(!result.ok);
    try t.expectEqualStrings("Error: run timed out", result.text);
}

test "sleep timers run concurrently with each other and host calls" {
    var host: Host = .{};
    var timing: sandbox.RunTiming = .init(t.io, .now(t.io, .awake));
    var h = host.host();
    h.timing = &timing;
    const result = try run(
        \\const order = [];
        \\const slow = tools.sleep(120).then(() => order.push('slow'));
        \\const fast = tools.sleep(10).then(() => order.push('fast'));
        \\const echo = await tools.echo();
        \\await Promise.all([slow, fast]);
        \\[echo, order];
    , .{}, h);
    defer result.deinit(t.allocator);
    try t.expect(result.ok);
    try t.expectEqualStrings("[true,[\"fast\",\"slow\"]]", result.text);
    try t.expectEqual(@as(usize, 1), host.calls.load(.monotonic));
    try t.expectEqual(@as(usize, 3), timing.count);
    for (timing.entries[0..2]) |entry| {
        try t.expectEqualStrings("sleep", entry.name);
        try t.expect(entry.ok and entry.dispatched);
        try t.expectEqual(@as(?u64, 4), entry.result_bytes);
        try t.expect(entry.end_ms >= entry.start_ms);
    }
    try t.expectEqual(@as(u64, 12), timing.tool_bytes);
}

test "sleep cancellation and rejection discard long timers promptly" {
    const Cancel = struct {
        fn work(flag: *std.atomic.Value(bool)) void {
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(40), .clock = .awake }, t.io) catch unreachable;
            flag.store(true, .release);
        }
    };
    var host: Host = .{};
    var flag: std.atomic.Value(bool) = .init(false);
    const worker = try std.Thread.spawn(.{}, Cancel.work, .{&flag});
    defer worker.join();
    const start = std.Io.Clock.Timestamp.now(t.io, .awake);
    const canceled = try sandbox.eval(t.allocator, t.io, "await tools.sleep(2147483647)", .{}, host.host(), &flag);
    defer canceled.deinit(t.allocator);
    try t.expectEqualStrings("Error: run canceled", canceled.text);
    try t.expect(start.durationTo(.now(t.io, .awake)).raw.toMilliseconds() < 1000);
    var timing: sandbox.RunTiming = .init(t.io, .now(t.io, .awake));
    var h = host.host();
    h.timing = &timing;
    const rejected = try run("tools.sleep(2147483647); throw new Error('stop')", .{}, h);
    defer rejected.deinit(t.allocator);
    try t.expect(!rejected.ok);
    try t.expect(std.mem.indexOf(u8, rejected.text, "stop") != null);
    try t.expectEqual(@as(usize, 1), timing.count);
    try t.expect(!timing.entries[0].ok);
    try t.expectEqual(@as(?u64, 0), timing.entries[0].result_bytes);
    try t.expectEqual(@as(u64, 0), rejected.tool_bytes);
}

test "normal completion drains unawaited sleep timers" {
    var host: Host = .{};
    const result = try run("tools.sleep(10).then(() => console.log('settled')); 7", .{}, host.host());
    defer result.deinit(t.allocator);
    try t.expect(result.ok);
    try t.expectEqualStrings("7", result.text);
    try t.expectEqualStrings("settled\n", result.logs);
}

test "sleep remains live when all tool slots are blocked" {
    const Gate = struct {
        released: std.atomic.Value(bool) = .init(false),

        fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, _: []const u8) sandbox.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "block")) {
                const start = std.Io.Clock.Timestamp.now(t.io, .awake);
                while (!self.released.load(.acquire)) {
                    if (start.durationTo(.now(t.io, .awake)).raw.toMilliseconds() >= 1000)
                        return .{ .ok = gpa.dupe(u8, "false") catch unreachable };
                    std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1), .clock = .awake }, t.io) catch unreachable;
                }
            }
            return .{ .ok = gpa.dupe(u8, "true") catch unreachable };
        }

        fn admit(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "release")) self.released.store(true, .release);
            return null;
        }
    };
    var gate: Gate = .{};
    const result = try run(
        \\const pending = Array.from({length: 8}, () => tools.block());
        \\await tools.sleep(30);
        \\await tools.release();
        \\(await Promise.all(pending)).every(Boolean);
    , .{}, .{ .ctx = &gate, .names = &.{ "sleep", "block", "release" }, .call = Gate.call, .admit = Gate.admit });
    defer result.deinit(t.allocator);
    try t.expect(result.ok);
    try t.expectEqualStrings("true", result.text);
}

test "pending sleeps do not occupy slots needed by a tool" {
    var host: Host = .{};
    const start = std.Io.Clock.Timestamp.now(t.io, .awake);
    const result = try run(
        \\const pending = Array.from({length: 16}, () => tools.sleep(2000));
        \\await tools.echo();
        \\throw new Error('tool ran');
    , .{}, host.host());
    defer result.deinit(t.allocator);
    try t.expect(!result.ok);
    try t.expect(std.mem.indexOf(u8, result.text, "tool ran") != null);
    try t.expectEqual(@as(usize, 1), host.calls.load(.monotonic));
    try t.expect(start.durationTo(.now(t.io, .awake)).raw.toMilliseconds() < 1000);
}

test "script replay exposes sleep even with no recorded sleep calls" {
    const result = try sandbox.replay.execute(t.allocator, t.io, "await tools.sleep(1)", &.{}, 0, .ok, true);
    defer result.deinit(t.allocator);
    try t.expect(!result.outcome.ok);
    try t.expect(std.mem.indexOf(u8, result.outcome.text, "not recorded: sleep") != null);
}

test "zero sleeps do not starve queued or ready host calls" {
    var host: Host = .{};
    const result = try run(
        \\let done = false;
        \\const pending = tools.echo().then(() => { done = true; });
        \\while (!done) await tools.sleep(0);
        \\await pending; done;
    , .{ .timeout_ms = 250 }, host.host());
    defer result.deinit(t.allocator);
    try t.expect(result.ok);
    try t.expectEqualStrings("true", result.text);
}

test "serial zero sleeps keep native bookkeeping bounded with an active worker" {
    var allocator: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    allocator.requested_memory_limit = 64 * 1024;
    defer std.debug.assert(allocator.deinit() == .ok);
    var host: Host = .{};
    const result = try sandbox.eval(allocator.allocator(), t.io,
        \\const pending = tools.block();
        \\for (let i = 0; i < 10000; i++) await tools.sleep(0);
        \\await tools.release(); await pending; 'done';
    , .{ .timeout_ms = 2000 }, host.host(), null);
    defer result.deinit(allocator.allocator());
    try t.expect(result.ok);
    try t.expectEqualStrings("\"done\"", result.text);
}

test "overdue sleeps settle by deadline rather than creation order" {
    var host: Host = .{};
    const result = try run(
        \\const order = [];
        \\const slow = tools.sleep(20).then(() => order.push('slow'));
        \\const fast = tools.sleep(0).then(() => order.push('fast'));
        \\const start = Date.now(); while (Date.now() - start < 40) {}
        \\await Promise.all([slow, fast]); order;
    , .{}, host.host());
    defer result.deinit(t.allocator);
    try t.expect(result.ok);
    try t.expectEqualStrings("[\"fast\",\"slow\"]", result.text);
}
