//! Server-sent events: feed lines, get back each event's `data` payload.

const std = @import("std");

pub const Parser = struct {
    data: std.ArrayList(u8) = .empty,
    pending: bool = false,
    /// The previous `feed` returned `data`; clear it before the next line.
    emitted: bool = false,

    pub fn deinit(p: *Parser, gpa: std.mem.Allocator) void {
        p.data.deinit(gpa);
    }

    /// Feed one line without its `\n`. Returns the joined `data` fields when a
    /// blank line completes an event; the slice is valid until the next call.
    pub fn feed(p: *Parser, gpa: std.mem.Allocator, raw: []const u8) !?[]const u8 {
        if (p.emitted) {
            p.data.clearRetainingCapacity();
            p.emitted = false;
        }
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (!p.pending) return null;
            p.pending = false;
            p.emitted = true;
            return p.data.items;
        }
        if (line[0] == ':') return null;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        if (!std.mem.eql(u8, line[0..colon], "data")) return null;
        var value = line[@min(colon + 1, line.len)..];
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (p.pending) try p.data.append(gpa, '\n');
        try p.data.appendSlice(gpa, value);
        p.pending = true;
        return null;
    }
};

test "sse joins data lines and skips comments" {
    const gpa = std.testing.allocator;
    var p: Parser = .{};
    defer p.deinit(gpa);
    try std.testing.expect(try p.feed(gpa, ": keep-alive") == null);
    try std.testing.expect(try p.feed(gpa, "event: x") == null);
    try std.testing.expect(try p.feed(gpa, "data: {\"a\":1}") == null);
    try std.testing.expect(try p.feed(gpa, "data:2\r") == null);
    try std.testing.expectEqualStrings("{\"a\":1}\n2", (try p.feed(gpa, "")).?);
    try std.testing.expect(try p.feed(gpa, "") == null);
    try std.testing.expect(try p.feed(gpa, "data: [DONE]") == null);
    try std.testing.expectEqualStrings("[DONE]", (try p.feed(gpa, "")).?);
}
