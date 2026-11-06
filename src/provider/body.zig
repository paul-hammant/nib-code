const std = @import("std");
const p = @import("../provider.zig");
const idle = @import("idle.zig");

pub const Reader = struct {
    reader: std.Io.Reader,
    input: *std.Io.Reader,
    monitor: *idle.Monitor,
    sink: p.Sink,

    pub fn init(gpa: std.mem.Allocator, input: *std.Io.Reader, monitor: *idle.Monitor, sink: p.Sink) !Reader {
        const buffer = try gpa.alloc(u8, 64 * 1024);
        return initBuffer(buffer, input, monitor, sink);
    }

    pub fn initBuffer(buffer: []u8, input: *std.Io.Reader, monitor: *idle.Monitor, sink: p.Sink) Reader {
        monitor.body = true;
        monitor.last = .now(monitor.io, .awake);
        return .{
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .input = input,
            .monitor = monitor,
            .sink = sink,
        };
    }

    pub fn deinit(r: *Reader, gpa: std.mem.Allocator) void {
        gpa.free(r.reader.buffer);
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *Reader = @fieldParentPtr("reader", reader);
        r.monitor.check() catch return error.ReadFailed;
        const n = try r.input.stream(writer, limit);
        if (n > 0) {
            r.monitor.last = .now(r.monitor.io, .awake);
            if (r.sink.timing) |model| model.received(n);
            r.sink.received() catch |err| {
                r.monitor.read_failure = err;
                return error.ReadFailed;
            };
        }
        return n;
    }
};
