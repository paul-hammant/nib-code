const std = @import("std");
const timing = @import("timing.zig");

pub const Monitor = struct {
    io: std.Io,
    timeout_s: usize,
    duration: std.Io.Clock.Duration,
    last: std.Io.Clock.Timestamp,
    model: ?*timing.Model,
    read_failure: ?anyerror = null,
    body: bool = false,

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.operate = operate;
        break :blk table;
    };

    pub fn init(io: std.Io, timeout_s: usize, model: ?*timing.Model) Monitor {
        return .{
            .io = io,
            .timeout_s = timeout_s,
            .duration = .{ .raw = .fromSeconds(@intCast(@min(timeout_s, std.math.maxInt(i64)))), .clock = .awake },
            .last = .now(io, .awake),
            .model = model,
        };
    }

    pub fn attach(m: *Monitor, connection: *std.http.Client.Connection) void {
        m.last = .now(m.io, .awake);
        m.read_failure = null;
        m.body = false;
        if (m.model) |model| model.resetAttempt();
        // Stream.Reader only uses Io.operate; intercept below HTTP and TLS buffering.
        connection.stream_reader.io = .{ .userdata = m, .vtable = &vtable };
    }

    pub fn detach(m: *Monitor, connection: *std.http.Client.Connection) void {
        connection.stream_reader.io = m.io;
        if (m.read_failure != null) connection.closing = true;
    }

    fn operate(ctx: ?*anyopaque, op: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const m: *Monitor = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(op == .net_read);
        var storage: [1]std.Io.Operation.Storage = undefined;
        var batch: std.Io.Batch = .init(&storage);
        // A timed-out/canceled batch may still own the socket and destination buffers.
        defer batch.cancel(m.io);
        batch.addAt(0, op);
        batch.awaitConcurrent(m.io, .{ .deadline = m.last.addDuration(m.duration) }) catch |err| {
            m.read_failure = err;
            return error.Canceled;
        };
        const result = batch.next().?.result;
        if (result.net_read) |read| {
            if (read.data_len > 0 and !m.body) m.last = .now(m.io, .awake);
        } else |_| {}
        return result;
    }

    pub fn failure(m: *const Monitor, gpa: std.mem.Allocator, detail: *?[]u8, err: anyerror) anyerror {
        const failure_error = m.read_failure orelse return err;
        if (failure_error != error.Timeout) return failure_error;
        const message = std.fmt.allocPrint(gpa, "Stream idle timeout after {d}s without receiving bytes.{s}{s}", .{
            m.timeout_s,
            if (detail.* != null) "\n" else "",
            detail.* orelse "",
        }) catch return error.OutOfMemory;
        if (detail.*) |old| gpa.free(old);
        detail.* = message;
        return error.StreamIdleTimeout;
    }
};

test "idle timeout diagnostic retains protocol detail and reports configured duration" {
    const t = std.testing;
    var m: Monitor = .init(t.io, 300, null);
    var detail: ?[]u8 = try t.allocator.dupe(u8, "Codex stream diagnostic");
    defer if (detail) |d| t.allocator.free(d);
    try t.expectEqual(error.ReadFailed, m.failure(t.allocator, &detail, error.ReadFailed));
    m.read_failure = error.Timeout;
    try t.expectEqual(error.StreamIdleTimeout, m.failure(t.allocator, &detail, error.ReadFailed));
    try t.expectEqualStrings("Stream idle timeout after 300s without receiving bytes.\nCodex stream diagnostic", detail.?);
    m.read_failure = error.Canceled;
    try t.expectEqual(error.Canceled, m.failure(t.allocator, &detail, error.ReadFailed));
}

const TestPair = struct {
    sender: std.Io.net.Stream,
    receiver: std.Io.net.Stream,

    fn init() !TestPair {
        const io = std.testing.io;
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const receiver = try server.socket.address.connect(io, .{ .mode = .stream });
        errdefer receiver.close(io);
        return .{ .sender = try server.accept(io), .receiver = receiver };
    }

    fn deinit(pair: TestPair) void {
        pair.sender.close(std.testing.io);
        pair.receiver.close(std.testing.io);
    }
};

test "idle deadline covers the first read and joins timed-out operations" {
    const t = std.testing;
    var pair = try TestPair.init();
    defer pair.deinit();
    var model: timing.Model = .init(t.io, .now(t.io, .awake));
    var m: Monitor = .init(t.io, 1, &model);
    m.duration.raw = .fromMilliseconds(30);
    var buffer: [64]u8 = undefined;
    var reader = pair.receiver.reader(.{ .userdata = &m, .vtable = &Monitor.vtable }, &buffer);
    const start = std.Io.Clock.awake.now(t.io);
    try t.expectError(error.ReadFailed, reader.interface.takeByte());
    try t.expectEqual(error.Timeout, m.read_failure.?);
    try t.expect(start.durationTo(.now(t.io, .awake)).toMilliseconds() < 2000);
    try t.expectEqual(@as(?u64, null), model.max_gap_ms);
    var writer = pair.sender.writer(t.io, &.{});
    try writer.interface.writeAll("x");
    m.last = .now(t.io, .awake);
    m.duration.raw = .fromSeconds(2);
    m.read_failure = null;
    try t.expectEqual(@as(u8, 'x'), try reader.interface.takeByte());
    try t.expectEqual(@as(?anyerror, null), m.read_failure);
}

test "partial lines and heartbeats reset the byte deadline before SSE parsing" {
    const t = std.testing;
    const Sender = struct {
        fn send(stream: std.Io.net.Stream) !void {
            var writer = stream.writer(std.testing.io, &.{});
            for ([_][]const u8{ ":", " keepalive\n", "data: ", "part", "ial", "\n\n" }) |part| {
                try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(50), .clock = .awake }, std.testing.io);
                try writer.interface.writeAll(part);
            }
        }
    };
    var pair = try TestPair.init();
    defer pair.deinit();
    var model: timing.Model = .init(t.io, .now(t.io, .awake));
    var m: Monitor = .init(t.io, 1, &model);
    m.duration.raw = .fromMilliseconds(200);
    var sender = try t.io.concurrent(Sender.send, .{pair.sender});
    defer sender.cancel(t.io) catch {};
    var buffer: [64]u8 = undefined;
    var reader = pair.receiver.reader(.{ .userdata = &m, .vtable = &Monitor.vtable }, &buffer);
    const Sink = struct {
        fn delta(_: *anyopaque, _: @import("../provider.zig").Kind, _: []const u8) !void {}
    };
    var observed = try @import("body.zig").Reader.init(t.allocator, &reader.interface, &m, .{ .ctx = &m, .onDelta = Sink.delta, .timing = &model });
    defer observed.deinit(t.allocator);
    try t.expectEqualStrings(": keepalive", (try observed.reader.takeDelimiter('\n')).?);
    try t.expectEqualStrings("data: partial", (try observed.reader.takeDelimiter('\n')).?);
    try t.expectEqualStrings("", (try observed.reader.takeDelimiter('\n')).?);
    try sender.await(t.io);
    try t.expectEqual(@as(?anyerror, null), m.read_failure);
    try t.expect(model.max_gap_ms != null);
}

test "cancel interrupts an idle socket read without waiting for the deadline" {
    const t = std.testing;
    const p = @import("../provider.zig");
    const State = struct {
        cancel: std.atomic.Value(bool) = .init(false),
        started: std.atomic.Value(bool) = .init(false),

        fn request(state: *@This(), reader: *std.Io.Reader) anyerror!p.Reply {
            state.started.store(true, .release);
            _ = try reader.takeByte();
            return error.UnexpectedData;
        }

        fn cancelSoon(state: *@This()) void {
            while (!state.started.load(.acquire)) {
                std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1), .clock = .awake }, std.testing.io) catch return;
            }
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, std.testing.io) catch return;
            state.cancel.store(true, .release);
        }
    };
    var pair = try TestPair.init();
    defer pair.deinit();
    var m: Monitor = .init(t.io, 30, null);
    var buffer: [64]u8 = undefined;
    var reader = pair.receiver.reader(.{ .userdata = &m, .vtable = &Monitor.vtable }, &buffer);
    var state: State = .{};
    var canceler = try t.io.concurrent(State.cancelSoon, .{&state});
    defer canceler.cancel(t.io);
    const start = std.Io.Clock.awake.now(t.io);
    try t.expectError(error.Canceled, @import("cancel.zig").run(t.io, &state.cancel, State.request, .{ &state, &reader.interface }));
    try t.expectEqual(error.Canceled, m.read_failure.?);
    try t.expect(start.durationTo(.now(t.io, .awake)).toMilliseconds() < 2000);
}
