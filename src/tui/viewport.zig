const std = @import("std");
const vaxis = @import("vaxis");
const Entry = @import("transcript.zig").Entry;
const Transcript = @import("transcript.zig").Transcript;

pub const Anchor = struct {
    entry: usize = 0,
    row: u16 = 0,

    fn atOrAfter(a: Anchor, b: Anchor) bool {
        return a.entry > b.entry or (a.entry == b.entry and a.row >= b.row);
    }
};

/// Follows the bottom until scrolled up; then stays anchored to the top entry,
/// so streamed output does not move what is on screen.
pub const Viewport = struct {
    /// null while following the bottom.
    top: ?Anchor = null,
    /// Rows to scroll at the next layout; negative is up.
    pending: i64 = 0,

    pub fn bottom(entries: []Entry, win: vaxis.Window) Anchor {
        var i = entries.len;
        var rows: i64 = -1;
        while (i > 0 and rows < win.height) {
            i -= 1;
            rows += @as(i64, entries[i].height(win)) + 1;
        }
        return .{ .entry = i, .row = @intCast(@max(rows - win.height, 0)) };
    }

    pub fn layout(v: *Viewport, entries: []Entry, win: vaxis.Window) Anchor {
        const end = bottom(entries, win);
        var top = v.top orelse end;
        if (entries.len > 0) top.row = @min(top.row, entries[top.entry].height(win));
        var left = @abs(v.pending);
        while (left > 0 and entries.len > 0) {
            if (v.pending < 0) {
                const step = @min(left, top.row);
                top.row -= @intCast(step);
                left -= step;
                if (left == 0 or top.entry == 0) break;
                top.entry -= 1;
                top.row = entries[top.entry].height(win) +| 1;
            } else {
                const step = @min(left, @as(u32, entries[top.entry].height(win)) + 1 - top.row);
                top.row += @intCast(step);
                left -= step;
                if (top.row <= entries[top.entry].height(win)) break;
                if (top.entry + 1 == entries.len) break;
                top.entry += 1;
                top.row = 0;
            }
        }
        v.pending = 0;
        if (top.atOrAfter(end)) {
            v.top = null;
            return end;
        }
        v.top = top;
        return top;
    }
};

const testing = std.testing;

test "viewport anchors survive streaming and appended Run output then resume following" {
    const gpa = testing.allocator;
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 20, .height = 4, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.add(gpa, .user, "one");
    try t.add(gpa, .assistant, "two\nthree\nfour");
    var view: Viewport = .{ .pending = -2 };
    const top = view.layout(t.entries.items, win);
    try testing.expect(view.top != null);
    try t.entries.items[1].text.appendSlice(gpa, "\nfive\nsix");
    try testing.expectEqualDeep(top, view.layout(t.entries.items, win));
    try t.add(gpa, .info, "output\nmore output");
    try testing.expectEqualDeep(top, view.layout(t.entries.items, win));
    view.pending = 100;
    _ = view.layout(t.entries.items, win);
    try testing.expect(view.top == null);
    try t.add(gpa, .assistant, "done");
    try testing.expectEqualDeep(Viewport.bottom(t.entries.items, win), view.layout(t.entries.items, win));
}

test "viewport can traverse all 5000 entries and gaps in both directions" {
    const gpa = testing.allocator;
    const entries = try gpa.alloc(Entry, 5000);
    defer gpa.free(entries);
    for (entries) |*e| e.* = .{ .kind = .info };
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 4, .screen = &screen };
    var view: Viewport = .{ .pending = -100_000 };
    try testing.expectEqualDeep(Anchor{}, view.layout(entries, win));
    view.pending = 1;
    try testing.expectEqualDeep(Anchor{ .row = 1 }, view.layout(entries, win));
    view.pending = 1;
    try testing.expectEqualDeep(Anchor{ .entry = 1 }, view.layout(entries, win));
    view.pending = -1;
    try testing.expectEqualDeep(Anchor{ .row = 1 }, view.layout(entries, win));
    view.pending = 100_000;
    try testing.expectEqualDeep(Viewport.bottom(entries, win), view.layout(entries, win));
    try testing.expect(view.top == null);
}
