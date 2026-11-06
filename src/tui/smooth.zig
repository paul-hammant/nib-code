const std = @import("std");
const vaxis = @import("vaxis");

pub const Smooth = struct {
    visible: usize = 0,
    deadline: ?std.Io.Clock.Timestamp = null,

    pub fn arrive(s: *Smooth, old_len: usize, len: usize, now: std.Io.Clock.Timestamp) void {
        if (old_len == 0) return s.flush(len);
        if (s.deadline == null) s.deadline = now.addDuration(.{ .raw = .fromMilliseconds(40), .clock = .awake });
    }

    pub fn flush(s: *Smooth, len: usize) void {
        s.visible = len;
        s.deadline = null;
    }

    pub fn advance(s: *Smooth, text: []const u8, now: std.Io.Clock.Timestamp) void {
        const deadline = s.deadline orelse return;
        const left = now.durationTo(deadline).raw.toMilliseconds();
        if (left <= 0) return s.flush(text.len);
        const frames: usize = @intCast(@max(1, @divTrunc(left + 15, 16)));
        const target = s.visible + (text.len - s.visible + frames - 1) / frames;
        var it = vaxis.unicode.graphemeIterator(text);
        var end: usize = 0;
        while (it.next()) |g| {
            end += g.bytes(text).len;
            if (end >= target) break;
        }
        s.visible = end;
        if (end == text.len) s.deadline = null;
    }
};

test "bursts drain proportionally within three frames on grapheme boundaries" {
    const t = std.testing;
    const now = std.Io.Clock.Timestamp.now(t.io, .awake);
    var s: Smooth = .{};
    s.arrive(0, 1, now);
    try t.expectEqual(@as(usize, 1), s.visible);
    const text = "a中文👩‍💻🙂abcdef";
    s.arrive(1, text.len, now);
    s.advance(text, now);
    try t.expect(s.visible > 1 and s.visible < text.len);
    var it = vaxis.unicode.graphemeIterator(text);
    var end: usize = 0;
    while (it.next()) |g| {
        end += g.bytes(text).len;
        if (end >= s.visible) break;
    }
    try t.expectEqual(end, s.visible);
    s.advance(text, now.addDuration(.{ .raw = .fromMilliseconds(48), .clock = .awake }));
    try t.expectEqual(text.len, s.visible);
    var big: Smooth = .{ .visible = 1 };
    big.arrive(1, 1001, now);
    const bytes: [1001]u8 = @splat('a');
    big.advance(&bytes, now);
    try t.expect(big.visible > 300);
    big.flush(1001);
    try t.expect(big.deadline == null);
}
