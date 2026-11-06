const std = @import("std");
const idle = @import("idle.zig");

pub const Connection = struct {
    connection: *std.http.Client.Connection,
    turn_state: ?[]u8 = null,
    read_buffer: ?[]u8 = null,
    read_seek: usize = 0,
    read_end: usize = 0,

    pub fn observe(ws: *Connection, gpa: std.mem.Allocator, monitor: *idle.Monitor, sink: @import("../provider.zig").Sink) !@import("body.zig").Reader {
        if (ws.read_buffer == null) ws.read_buffer = try gpa.alloc(u8, 64 * 1024);
        var observed = @import("body.zig").Reader.initBuffer(ws.read_buffer.?, ws.connection.reader(), monitor, sink);
        observed.reader.seek = ws.read_seek;
        observed.reader.end = ws.read_end;
        return observed;
    }

    pub fn saveReader(ws: *Connection, reader: *std.Io.Reader) void {
        ws.read_seek = reader.seek;
        ws.read_end = reader.end;
    }

    pub fn close(ws: *Connection, gpa: std.mem.Allocator) void {
        if (ws.turn_state) |s| gpa.free(s);
        if (ws.read_buffer) |buffer| gpa.free(buffer);
        const c = ws.connection;
        c.closing = true;
        c.client.connection_pool.release(c, c.client.io);
        ws.* = undefined;
    }

    pub fn open(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8, headers: []const std.http.Header, monitor: *idle.Monitor) !Connection {
        var key_bytes: [16]u8 = undefined;
        client.io.random(&key_bytes);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_bytes);
        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(gpa);
        try extra.appendSlice(gpa, headers);
        try extra.appendSlice(gpa, &.{
            .{ .name = "upgrade", .value = "websocket" },
            .{ .name = "sec-websocket-version", .value = "13" },
            .{ .name = "sec-websocket-key", .value = &key },
        });
        var req = try client.request(.GET, try std.Uri.parse(url), .{
            .redirect_behavior = .not_allowed,
            .headers = .{ .connection = .{ .override = "Upgrade" }, .accept_encoding = .omit },
            .extra_headers = extra.items,
        });
        defer req.deinit();
        const c = req.connection.?;
        monitor.attach(c);
        defer monitor.detach(c);
        errdefer c.closing = true;
        try req.sendBodiless();
        const response = try req.receiveHead(&.{});
        if (response.head.status != .switching_protocols) return error.WebSocketHandshake;
        var upgrade = false;
        var connection = false;
        var accepted = false;
        var ws: Connection = .{ .connection = c };
        errdefer if (ws.turn_state) |s| gpa.free(s);
        var hash: [20]u8 = undefined;
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(&key);
        sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        sha.final(&hash);
        var accept: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept, &hash);
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "upgrade")) upgrade = std.ascii.eqlIgnoreCase(h.value, "websocket");
            if (std.ascii.eqlIgnoreCase(h.name, "connection")) {
                var tokens = std.mem.tokenizeScalar(u8, h.value, ',');
                while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "upgrade")) {
                    connection = true;
                };
            }
            if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-accept")) accepted = std.mem.eql(u8, h.value, &accept);
            if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-extensions") or std.ascii.eqlIgnoreCase(h.name, "sec-websocket-protocol")) return error.WebSocketProtocol;
            if (std.ascii.eqlIgnoreCase(h.name, "x-codex-turn-state") and ws.turn_state == null) ws.turn_state = try gpa.dupe(u8, h.value);
        }
        if (!upgrade or !connection or !accepted) return error.WebSocketHandshake;
        req.connection = null;
        return ws;
    }

    pub fn checkIdle(ws: *Connection, gpa: std.mem.Allocator, monitor: *idle.Monitor) !bool {
        const c = ws.connection;
        monitor.attach(c);
        defer monitor.detach(c);
        var observed = try ws.observe(gpa, monitor, .{ .ctx = ws, .onDelta = idleDelta });
        defer ws.saveReader(&observed.reader);
        const reader = &observed.reader;
        const raw = &c.stream_reader.interface;
        const original = raw.vtable;
        // A partial frame or TLS control record must not wait for more socket bytes.
        raw.vtable = &.{ .stream = IdleRead.stream, .readVec = IdleRead.readVec };
        defer raw.vtable = original;
        while (reader.buffered().len != 0 or try ws.readable()) {
            const head = readHeader(reader) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return false,
                else => return err,
            };
            if (!head.fin or head.opcode < 8) return false;
            var control: [125]u8 = undefined;
            reader.readSliceAll(control[0..head.len]) catch return false;
            switch (head.opcode) {
                8 => return false,
                9 => try ws.send(10, control[0..head.len]),
                10 => {},
                else => return error.WebSocketProtocol,
            }
        }
        return true;
    }

    fn idleDelta(_: *anyopaque, _: @import("../provider.zig").Kind, _: []const u8) !void {}

    const IdleRead = struct {
        fn ready(r: *std.Io.Reader) bool {
            const raw: *std.Io.net.Stream.Reader = @alignCast(@fieldParentPtr("interface", r));
            return socketReadable(raw.stream.socket.handle) catch false;
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            if (!ready(r)) return error.ReadFailed;
            const raw: *std.Io.net.Stream.Reader = @alignCast(@fieldParentPtr("interface", r));
            const original = std.Io.net.Stream.Reader.init(raw.stream, raw.io, &.{});
            return original.interface.vtable.stream(r, w, limit);
        }

        fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            if (!ready(r)) return error.ReadFailed;
            const raw: *std.Io.net.Stream.Reader = @alignCast(@fieldParentPtr("interface", r));
            const original = std.Io.net.Stream.Reader.init(raw.stream, raw.io, &.{});
            return original.interface.vtable.readVec(r, data);
        }
    };

    fn readable(ws: *Connection) !bool {
        const c = ws.connection;
        // TLS plaintext and encrypted input may already be buffered above the socket.
        if (c.reader().buffered().len != 0 or c.stream_reader.interface.buffered().len != 0) return true;
        return socketReadable(c.stream_reader.stream.socket.handle) catch false;
    }

    fn socketReadable(handle: std.Io.net.Socket.Handle) !bool {
        switch (@import("builtin").os.tag) {
            .linux, .macos => {
                var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
                return try std.posix.poll(&fds, 0) != 0;
            },
            else => return false,
        }
    }

    pub fn send(ws: *Connection, opcode: u4, payload: []const u8) !void {
        var mask: [4]u8 = undefined;
        ws.connection.client.io.random(&mask);
        try writeFrame(ws.connection.writer(), opcode, payload, mask);
        try ws.connection.flush();
    }

    pub fn message(ws: *Connection, reader: *std.Io.Reader, out: *std.Io.Writer.Allocating) ![]const u8 {
        out.clearRetainingCapacity();
        var fragmented = false;
        while (true) {
            const head = try readHeader(reader);
            if (head.opcode >= 8) {
                var control: [125]u8 = undefined;
                try reader.readSliceAll(control[0..head.len]);
                switch (head.opcode) {
                    8 => {
                        if (head.len == 1) return error.WebSocketProtocol;
                        if (head.len >= 2) {
                            const code = std.mem.readInt(u16, control[0..2], .big);
                            if (code < 1000 or code >= 5000 or code == 1004 or code == 1005 or code == 1006 or (code >= 1015 and code < 3000) or !std.unicode.utf8ValidateSlice(control[2..head.len])) return error.WebSocketProtocol;
                        }
                        try ws.send(8, control[0..head.len]);
                        return error.WebSocketClosed;
                    },
                    9 => try ws.send(10, control[0..head.len]),
                    10 => {},
                    else => return error.WebSocketProtocol,
                }
                continue;
            }
            if ((head.opcode == 1 and fragmented) or (head.opcode == 0 and !fragmented) or (head.opcode != 0 and head.opcode != 1)) return error.WebSocketProtocol;
            if (head.len > max_message - out.written().len) return error.WebSocketMessageTooLarge;
            reader.streamExact(&out.writer, head.len) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
            if (head.fin) {
                if (!std.unicode.utf8ValidateSlice(out.written())) return error.WebSocketProtocol;
                return out.written();
            }
            fragmented = true;
        }
    }
};

// shortcut: messages over 16 MiB use SSE; raise this after measuring larger Responses events.
const max_message = 16 * 1024 * 1024;
const Header = struct { fin: bool, opcode: u4, len: usize };

fn readHeader(r: *std.Io.Reader) !Header {
    const a = try r.takeByte();
    const b = try r.takeByte();
    if (a & 0x70 != 0 or b & 0x80 != 0) return error.WebSocketProtocol;
    const opcode: u4 = @truncate(a);
    var len: u64 = b & 0x7f;
    if (len == 126) {
        len = try r.takeInt(u16, .big);
        if (len < 126) return error.WebSocketProtocol;
    } else if (len == 127) {
        len = try r.takeInt(u64, .big);
        if (len < 65536 or len >> 63 != 0) return error.WebSocketProtocol;
    }
    if (opcode >= 8 and (a & 0x80 == 0 or len > 125)) return error.WebSocketProtocol;
    if (len > max_message) return error.WebSocketMessageTooLarge;
    return .{ .fin = a & 0x80 != 0, .opcode = opcode, .len = @intCast(len) };
}

fn writeFrame(w: *std.Io.Writer, opcode: u4, payload: []const u8, mask: [4]u8) !void {
    try w.writeByte(0x80 | @as(u8, opcode));
    if (payload.len < 126) {
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 65535) {
        try w.writeByte(0x80 | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(0x80 | 127);
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const n = @min(buffer.len, payload.len - offset);
        for (payload[offset..][0..n], 0..) |byte, i| buffer[i] = byte ^ mask[(offset + i) % 4];
        try w.writeAll(buffer[0..n]);
        offset += n;
    }
}

test "WebSocket client masks short and extended frames" {
    const t = std.testing;
    for ([_]usize{ 0, 5, 125, 126, 65535, 65536 }) |len| {
        const payload = try t.allocator.alloc(u8, len);
        defer t.allocator.free(payload);
        @memset(payload, 'x');
        var w: std.Io.Writer.Allocating = .init(t.allocator);
        defer w.deinit();
        const mask = [4]u8{ 1, 2, 3, 4 };
        try writeFrame(&w.writer, 1, payload, mask);
        var r = std.Io.Reader.fixed(w.written());
        try t.expectEqual(@as(u8, 0x81), try r.takeByte());
        const b = try r.takeByte();
        try t.expect(b & 0x80 != 0);
        const actual: u64 = switch (b & 0x7f) {
            126 => try r.takeInt(u16, .big),
            127 => try r.takeInt(u64, .big),
            else => b & 0x7f,
        };
        try t.expectEqual(len, actual);
        try t.expectEqualSlices(u8, &mask, try r.takeArray(4));
        for (0..len) |i| try t.expectEqual(@as(u8, 'x'), (try r.takeByte()) ^ mask[i % 4]);
    }
}

test "WebSocket rejects masked server frames, reserved bits and invalid control lengths" {
    const t = std.testing;
    for ([_][]const u8{ "\x81\x80", "\xc1\x00", "\x09\x00", "\x89\x7e\x00\x7e", "\x81\x7e\x00\x05", "\x81\x7f\x80\x00\x00\x00\x00\x00\x00\x00" }) |bytes| {
        var r = std.Io.Reader.fixed(bytes);
        try t.expectError(error.WebSocketProtocol, readHeader(&r));
    }
    var r = std.Io.Reader.fixed("\x01\x03abc");
    const h = try readHeader(&r);
    try t.expect(!h.fin and h.opcode == 1 and h.len == 3);
}

test "WebSocket assembles text fragments and rejects invalid continuation and UTF-8" {
    const t = std.testing;
    var ws: Connection = .{ .connection = undefined };
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var r = std.Io.Reader.fixed("\x01\x03hel\x8a\x00\x80\x02lo");
    try t.expectEqualStrings("hello", try ws.message(&r, &out));
    for ([_][]const u8{ "\x80\x00", "\x01\x00\x81\x00", "\x82\x00", "\x81\x01\xff", "\x88\x01x", "\x88\x02\x03\xed" }) |bytes| {
        r = .fixed(bytes);
        try t.expectError(error.WebSocketProtocol, ws.message(&r, &out));
    }
}
