const std = @import("std");
const vaxis = @import("vaxis");
const Key = vaxis.Key;

pub const Editor = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Byte offset, always on a UTF-8 codepoint boundary.
    cursor: usize = 0,

    history: std.ArrayList([]const u8) = .empty,
    history_index: ?usize = null,
    draft: std.ArrayList(u8) = .empty,
    draft_cursor: usize = 0,
    top_row: u16 = 0,

    pub fn deinit(e: *Editor, gpa: std.mem.Allocator) void {
        e.buf.deinit(gpa);
        for (e.history.items) |item| gpa.free(item);
        e.history.deinit(gpa);
        e.draft.deinit(gpa);
    }

    pub fn text(e: *const Editor) []const u8 {
        return e.buf.items;
    }

    pub fn take(e: *Editor, gpa: std.mem.Allocator) ![]u8 {
        if (e.buf.items.len > 0) try e.remember(gpa, e.text());
        e.cursor = 0;
        e.top_row = 0;
        e.history_index = null;
        e.draft.clearRetainingCapacity();
        return e.buf.toOwnedSlice(gpa);
    }

    pub fn replace(e: *Editor, gpa: std.mem.Allocator, value: []const u8) !void {
        e.buf.clearRetainingCapacity();
        try e.buf.appendSlice(gpa, value);
        e.cursor = value.len;
        e.history_index = null;
        e.draft.clearRetainingCapacity();
    }

    pub fn remember(e: *Editor, gpa: std.mem.Allocator, value: []const u8) !void {
        const copy = try gpa.dupe(u8, value);
        errdefer gpa.free(copy);
        try e.history.append(gpa, copy);
    }

    fn recall(e: *Editor, gpa: std.mem.Allocator, older: bool) !void {
        if (e.history.items.len == 0) return;
        const index = e.history_index orelse e.history.items.len;
        if ((!older and e.history_index == null) or (older and index == 0)) return;
        if (e.history_index == null) {
            std.mem.swap(std.ArrayList(u8), &e.buf, &e.draft);
            e.draft_cursor = e.cursor;
        }
        const target = if (older) index - 1 else index + 1;
        if (target == e.history.items.len) {
            std.mem.swap(std.ArrayList(u8), &e.buf, &e.draft);
            e.cursor = e.draft_cursor;
            e.history_index = null;
        } else {
            e.buf.clearRetainingCapacity();
            try e.buf.appendSlice(gpa, e.history.items[target]);
            e.cursor = if (older) e.lineEnd(0) else e.buf.items.len;
            e.history_index = target;
        }
    }

    pub fn insert(e: *Editor, gpa: std.mem.Allocator, s: []const u8) !void {
        try e.buf.insertSlice(gpa, e.cursor, s);
        e.cursor += s.len;
    }

    /// Returns false for keys that are not editing keys.
    pub fn key(e: *Editor, gpa: std.mem.Allocator, k: Key) !bool {
        if (k.matches(Key.backspace, .{})) {
            e.remove(e.prev(e.cursor), e.cursor);
        } else if (k.matches(Key.delete, .{}) or k.matches('d', .{ .alt = true })) {
            e.remove(e.cursor, e.next(e.cursor));
        } else if (k.matches(Key.left, .{}) or k.matches('b', .{ .ctrl = true })) {
            e.cursor = e.prev(e.cursor);
        } else if (k.matches(Key.right, .{}) or k.matches('f', .{ .ctrl = true })) {
            e.cursor = e.next(e.cursor);
        } else if (k.matches(Key.home, .{}) or k.matches('a', .{ .ctrl = true })) {
            e.cursor = e.lineStart(e.cursor);
        } else if (k.matches(Key.end, .{}) or k.matches('e', .{ .ctrl = true })) {
            e.cursor = e.lineEnd(e.cursor);
        } else if (k.matches(Key.up, .{})) {
            const start = e.lineStart(e.cursor);
            if (start == 0) {
                try e.recall(gpa, true);
            } else {
                e.cursor = e.atColumn(e.lineStart(start - 1), e.column(e.cursor));
            }
        } else if (k.matches(Key.down, .{})) {
            const end = e.lineEnd(e.cursor);
            if (end == e.buf.items.len) {
                try e.recall(gpa, false);
            } else {
                e.cursor = e.atColumn(end + 1, e.column(e.cursor));
            }
        } else if (k.matches('u', .{ .ctrl = true })) {
            e.remove(e.lineStart(e.cursor), e.cursor);
        } else if (k.matches('k', .{ .ctrl = true })) {
            const end = e.lineEnd(e.cursor);
            e.remove(e.cursor, if (end == e.cursor) e.next(end) else end);
        } else if (k.matches('w', .{ .ctrl = true }) or k.matches(Key.backspace, .{ .alt = true })) {
            e.remove(e.wordStart(e.cursor), e.cursor);
        } else if (k.text) |t| {
            try e.insert(gpa, t);
        } else {
            return false;
        }
        return true;
    }

    pub fn rows(e: *const Editor, win: vaxis.Window) u16 {
        var measure = win;
        measure.height = std.math.maxInt(u16);
        const r = measure.print(&.{.{ .text = e.buf.items }}, .{ .wrap = .grapheme, .commit = false });
        return r.row +| 1;
    }

    pub fn draw(e: *Editor, win: vaxis.Window) void {
        var measure = win;
        measure.height = std.math.maxInt(u16);
        const at = measure.print(&.{.{ .text = e.buf.items[0..e.cursor] }}, .{ .wrap = .grapheme, .commit = false });
        if (at.row < e.top_row) e.top_row = at.row;
        if (at.row >= @as(u32, e.top_row) + win.height) e.top_row = at.row - win.height + 1;
        _ = win.child(.{ .y_off = -@as(i17, @intCast(e.top_row)) }).print(&.{.{ .text = e.buf.items }}, .{ .wrap = .grapheme });
        win.showCursor(at.col, at.row - e.top_row);
    }

    fn remove(e: *Editor, from: usize, to: usize) void {
        if (to <= from) return;
        e.buf.replaceRangeAssumeCapacity(from, to - from, &.{});
        e.cursor = from;
    }

    fn prev(e: *const Editor, i: usize) usize {
        var j = i;
        while (j > 0) {
            j -= 1;
            if (e.buf.items[j] & 0xC0 != 0x80) break;
        }
        return j;
    }

    fn next(e: *const Editor, i: usize) usize {
        if (i >= e.buf.items.len) return i;
        const len = std.unicode.utf8ByteSequenceLength(e.buf.items[i]) catch 1;
        return @min(i + len, e.buf.items.len);
    }

    fn lineStart(e: *const Editor, i: usize) usize {
        return if (std.mem.lastIndexOfScalar(u8, e.buf.items[0..i], '\n')) |nl| nl + 1 else 0;
    }

    fn lineEnd(e: *const Editor, i: usize) usize {
        return std.mem.indexOfScalarPos(u8, e.buf.items, i, '\n') orelse e.buf.items.len;
    }

    /// Column in codepoints from the start of the line.
    fn column(e: *const Editor, i: usize) usize {
        var c: usize = 0;
        var j = e.lineStart(i);
        while (j < i) : (c += 1) j = e.next(j);
        return c;
    }

    fn atColumn(e: *const Editor, line_start: usize, col: usize) usize {
        const end = e.lineEnd(line_start);
        var j = line_start;
        var c: usize = 0;
        while (c < col and j < end) : (c += 1) j = e.next(j);
        return j;
    }

    fn wordStart(e: *const Editor, i: usize) usize {
        var j = i;
        while (j > 0 and isSpace(e.buf.items[j - 1])) j -= 1;
        while (j > 0 and !isSpace(e.buf.items[j - 1])) j = e.prev(j);
        return j;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

const testing = std.testing;

fn press(e: *Editor, cp: u21, mods: vaxis.Key.Modifiers) !void {
    _ = try e.key(testing.allocator, .{ .codepoint = cp, .mods = mods });
}

test "multi-line editing with UTF-8" {
    var e: Editor = .{};
    defer e.deinit(testing.allocator);
    try e.insert(testing.allocator, "你好\nab");
    try press(&e, Key.up, .{});
    try testing.expectEqual(@as(usize, "你好".len), e.cursor);
    try press(&e, Key.backspace, .{});
    try testing.expectEqualStrings("你\nab", e.text());
    try press(&e, Key.down, .{});
    try press(&e, Key.end, .{});
    try e.insert(testing.allocator, "c");
    try testing.expectEqualStrings("你\nabc", e.text());
    try press(&e, 'w', .{ .ctrl = true });
    try testing.expectEqualStrings("你\n", e.text());
    try press(&e, Key.backspace, .{});
    try press(&e, Key.left, .{});
    try press(&e, 'k', .{ .ctrl = true });
    try testing.expectEqualStrings("", e.text());
    const taken = try e.take(testing.allocator);
    defer testing.allocator.free(taken);
    try testing.expectEqual(@as(usize, 0), e.cursor);
}

test {
    _ = @import("../tui.zig");
}

test "input history keeps multiline entries and restores draft cursor" {
    var e: Editor = .{};
    defer e.deinit(testing.allocator);
    try e.insert(testing.allocator, "first\nsecond");
    const first = try e.take(testing.allocator);
    defer testing.allocator.free(first);
    try e.insert(testing.allocator, "next");
    const next_input = try e.take(testing.allocator);
    defer testing.allocator.free(next_input);
    try e.insert(testing.allocator, "draft");
    try press(&e, Key.left, .{});
    try press(&e, Key.up, .{});
    try testing.expectEqualStrings("next", e.text());
    try press(&e, Key.up, .{});
    try testing.expectEqualStrings("first\nsecond", e.text());
    try press(&e, Key.up, .{});
    try testing.expectEqualStrings("first\nsecond", e.text());
    try e.insert(testing.allocator, " edited");
    try press(&e, Key.down, .{});
    try testing.expectEqualStrings("first edited\nsecond", e.text());
    try press(&e, Key.down, .{});
    try testing.expectEqualStrings("next", e.text());
    try press(&e, Key.down, .{});
    try testing.expectEqualStrings("draft", e.text());
    try testing.expectEqual(@as(usize, 4), e.cursor);
    try press(&e, Key.up, .{});
    try press(&e, Key.up, .{});
    try testing.expectEqualStrings("first\nsecond", e.text());
}

test "editor scrolls internally to keep cursor visible" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 10, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 3, .screen = &screen };
    var e: Editor = .{};
    defer e.deinit(gpa);
    try e.insert(gpa, "zero\none\ntwo\nthree\nfour");
    e.draw(win);
    try testing.expectEqual(@as(u16, 2), e.top_row);
    try testing.expect(screen.cursor_vis);
    try testing.expectEqual(@as(u16, 2), screen.cursor.row);
    try testing.expectEqualStrings("f", screen.readCell(0, 2).?.char.grapheme);
    for (0..4) |_| try press(&e, Key.up, .{});
    e.draw(win);
    try testing.expectEqual(@as(u16, 0), e.top_row);
    try testing.expectEqual(@as(u16, 0), screen.cursor.row);
    try testing.expectEqualStrings("z", screen.readCell(0, 0).?.char.grapheme);
    e.cursor = e.text().len;
    try e.insert(gpa, "123456");
    e.draw(win);
    try testing.expectEqual(@as(u16, 3), e.top_row);
    try testing.expectEqual(@as(u16, 0), screen.cursor.col);
    try testing.expectEqual(@as(u16, 2), screen.cursor.row);
}
