const std = @import("std");
const vaxis = @import("vaxis");
const Key = vaxis.Key;
const long_text = @import("long_text.zig");

const Block = struct { start: usize, end: usize, original: []const u8 };

const Snapshot = struct {
    text: []const u8,
    blocks: []Block,
    number: usize,

    fn deinit(s: Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(s.text);
        for (s.blocks) |b| gpa.free(b.original);
        gpa.free(s.blocks);
    }
};

pub const Editor = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Byte offset, always on a UTF-8 codepoint boundary.
    cursor: usize = 0,

    blocks: std.ArrayList(Block) = .empty,
    number: usize = 1,
    history: std.ArrayList(Snapshot) = .empty,
    history_index: ?usize = null,
    draft: ?Snapshot = null,
    draft_cursor: usize = 0,
    top_row: u16 = 0,

    pub fn deinit(e: *Editor, gpa: std.mem.Allocator) void {
        e.buf.deinit(gpa);
        for (e.history.items) |item| item.deinit(gpa);
        e.clearBlocks(gpa);
        e.blocks.deinit(gpa);
        e.history.deinit(gpa);
        if (e.draft) |d| d.deinit(gpa);
    }

    pub fn text(e: *const Editor) []const u8 {
        return e.buf.items;
    }

    fn clearBlocks(e: *Editor, gpa: std.mem.Allocator) void {
        for (e.blocks.items) |b| gpa.free(b.original);
        e.blocks.clearRetainingCapacity();
    }

    fn snapshot(e: *const Editor, gpa: std.mem.Allocator) !Snapshot {
        const text_copy = try gpa.dupe(u8, e.text());
        errdefer gpa.free(text_copy);
        var blocks: std.ArrayList(Block) = .empty;
        errdefer {
            for (blocks.items) |b| gpa.free(b.original);
            blocks.deinit(gpa);
        }
        for (e.blocks.items) |b| {
            const original = try gpa.dupe(u8, b.original);
            errdefer gpa.free(original);
            try blocks.append(gpa, .{ .start = b.start, .end = b.end, .original = original });
        }
        return .{ .text = text_copy, .blocks = try blocks.toOwnedSlice(gpa), .number = e.number };
    }

    fn load(e: *Editor, gpa: std.mem.Allocator, s: Snapshot) !void {
        e.clearBlocks(gpa);
        e.buf.clearRetainingCapacity();
        try e.buf.appendSlice(gpa, s.text);
        for (s.blocks) |b| {
            const original = try gpa.dupe(u8, b.original);
            errdefer gpa.free(original);
            try e.blocks.append(gpa, .{ .start = b.start, .end = b.end, .original = original });
        }
        e.number = s.number;
        e.top_row = 0;
    }

    pub fn expanded(e: *const Editor, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (i < e.buf.items.len) {
            if (e.blockAt(i)) |b| {
                try out.appendSlice(gpa, b.original);
                i = b.end;
            } else {
                const next_i = e.next(i);
                try out.appendSlice(gpa, e.buf.items[i..next_i]);
                i = next_i;
            }
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn take(e: *Editor, gpa: std.mem.Allocator) ![]u8 {
        const out = try e.expanded(gpa);
        errdefer gpa.free(out);
        if (e.buf.items.len > 0) {
            const saved = try e.snapshot(gpa);
            errdefer saved.deinit(gpa);
            try e.history.append(gpa, saved);
        }
        try e.replace(gpa, "");
        return out;
    }

    pub fn replace(e: *Editor, gpa: std.mem.Allocator, value: []const u8) !void {
        e.clearBlocks(gpa);
        e.buf.clearRetainingCapacity();
        try e.buf.appendSlice(gpa, value);
        e.number = 1;
        e.cursor = value.len;
        e.top_row = 0;
        e.history_index = null;
        if (e.draft) |d| d.deinit(gpa);
        e.draft = null;
    }

    pub fn remember(e: *Editor, gpa: std.mem.Allocator, value: []const u8) !void {
        var restored: Editor = .{};
        defer restored.deinit(gpa);
        try restored.paste(gpa, value);
        const saved = try restored.snapshot(gpa);
        errdefer saved.deinit(gpa);
        try e.history.append(gpa, saved);
    }

    fn recall(e: *Editor, gpa: std.mem.Allocator, older: bool) !void {
        if (e.history.items.len == 0) return;
        const index = e.history_index orelse e.history.items.len;
        if ((!older and e.history_index == null) or (older and index == 0)) return;
        if (e.history_index == null) {
            const saved = try e.snapshot(gpa);
            if (e.draft) |d| d.deinit(gpa);
            e.draft = saved;
            e.draft_cursor = e.cursor;
        }
        const target = if (older) index - 1 else index + 1;
        if (target == e.history.items.len) {
            try e.load(gpa, e.draft.?);
            e.cursor = e.draft_cursor;
            e.history_index = null;
        } else {
            try e.load(gpa, e.history.items[target]);
            e.cursor = if (older) e.lineEnd(0) else e.buf.items.len;
            e.history_index = target;
        }
    }

    pub fn insert(e: *Editor, gpa: std.mem.Allocator, s: []const u8) !void {
        try e.buf.insertSlice(gpa, e.cursor, s);
        for (e.blocks.items) |*b| if (b.start >= e.cursor) {
            b.start += s.len;
            b.end += s.len;
        };
        e.cursor += s.len;
    }

    pub fn paste(e: *Editor, gpa: std.mem.Allocator, s: []const u8) !void {
        if (!long_text.isLong(s)) return e.insert(gpa, s);
        var label: [96]u8 = undefined;
        const n = long_text.lines(s);
        const shown = try std.fmt.bufPrint(&label, "[Pasted #{d} · {d} {s}]", .{ e.number, if (n < 2) long_text.chars(s) else n, if (n < 2) "chars" else "lines" });
        const original = try gpa.dupe(u8, s);
        errdefer gpa.free(original);
        try e.blocks.ensureUnusedCapacity(gpa, 1);
        const start = e.cursor;
        try e.insert(gpa, shown);
        e.blocks.appendAssumeCapacity(.{ .start = start, .end = e.cursor, .original = original });
        e.number += 1;
    }

    fn blockAt(e: *const Editor, i: usize) ?Block {
        for (e.blocks.items) |b| if (b.start == i) return b;
        return null;
    }

    /// Returns false for keys that are not editing keys.
    pub fn key(e: *Editor, gpa: std.mem.Allocator, k: Key) !bool {
        if (k.matches(Key.backspace, .{})) {
            e.remove(gpa, e.prev(e.cursor), e.cursor);
        } else if (k.matches(Key.delete, .{}) or k.matches('d', .{ .alt = true })) {
            e.remove(gpa, e.cursor, e.next(e.cursor));
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
            e.remove(gpa, e.lineStart(e.cursor), e.cursor);
        } else if (k.matches('k', .{ .ctrl = true })) {
            const end = e.lineEnd(e.cursor);
            e.remove(gpa, e.cursor, if (end == e.cursor) e.next(end) else end);
        } else if (k.matches('w', .{ .ctrl = true }) or k.matches(Key.backspace, .{ .alt = true })) {
            e.remove(gpa, e.wordStart(e.cursor), e.cursor);
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
        if (e.buf.items.len == 0) {
            _ = win.printSegment(.{ .text = "Message nib · / for commands", .style = .{ .dim = true } }, .{ .wrap = .none });
        } else {
            _ = win.child(.{ .y_off = -@as(i17, @intCast(e.top_row)) }).print(&.{.{ .text = e.buf.items }}, .{ .wrap = .grapheme });
        }
        win.showCursor(at.col, at.row - e.top_row);
    }

    fn remove(e: *Editor, gpa: std.mem.Allocator, from: usize, to: usize) void {
        if (to <= from) return;
        var i: usize = 0;
        while (i < e.blocks.items.len) {
            const b = &e.blocks.items[i];
            if (b.start >= from and b.end <= to) {
                gpa.free(b.original);
                _ = e.blocks.swapRemove(i);
            } else {
                if (b.start >= to) {
                    b.start -= to - from;
                    b.end -= to - from;
                }
                i += 1;
            }
        }
        e.buf.replaceRangeAssumeCapacity(from, to - from, &.{});
        e.cursor = from;
    }

    fn prev(e: *const Editor, i: usize) usize {
        for (e.blocks.items) |b| if (b.end == i) return b.start;
        var j = i;
        while (j > 0) {
            j -= 1;
            if (e.buf.items[j] & 0xC0 != 0x80) break;
        }
        return j;
    }

    fn next(e: *const Editor, i: usize) usize {
        if (e.blockAt(i)) |b| return b.end;
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

    fn column(e: *const Editor, i: usize) usize {
        var c: usize = 0;
        var j = e.lineStart(i);
        while (j < i) {
            const n = e.next(j);
            c += displayWidth(e.buf.items[j..n]);
            j = n;
        }
        return c;
    }

    fn atColumn(e: *const Editor, line_start: usize, col: usize) usize {
        const end = e.lineEnd(line_start);
        var j = line_start;
        var c: usize = 0;
        while (c < col and j < end) {
            const n = e.next(j);
            const w = displayWidth(e.buf.items[j..n]);
            if (c + w > col) break;
            c += w;
            j = n;
        }
        return j;
    }

    fn wordStart(e: *const Editor, i: usize) usize {
        var j = i;
        while (j > 0 and isSpace(e.buf.items[j - 1])) j -= 1;
        while (j > 0 and !isSpace(e.buf.items[j - 1])) j = e.prev(j);
        return j;
    }
};

fn displayWidth(s: []const u8) usize {
    return vaxis.gwidth.gwidth(s, .unicode);
}

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
    try e.insert(testing.allocator, "你好\nabcd");
    try press(&e, Key.up, .{});
    try testing.expectEqual(@as(usize, "你好".len), e.cursor);
    try press(&e, Key.backspace, .{});
    try testing.expectEqualStrings("你\nabcd", e.text());
    try press(&e, Key.down, .{});
    try press(&e, Key.end, .{});
    try e.insert(testing.allocator, "c");
    try testing.expectEqualStrings("你\nabcdc", e.text());
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

test "paste thresholds count characters and keep literal private-use codepoints" {
    const gpa = testing.allocator;
    var e: Editor = .{};
    defer e.deinit(gpa);
    try e.paste(gpa, "a\nb\nc\nd\ne");
    try testing.expectEqual(@as(usize, 0), e.blocks.items.len);
    try e.replace(gpa, "");
    const exact = try gpa.alloc(u8, 800);
    defer gpa.free(exact);
    @memset(exact, 'x');
    try e.paste(gpa, exact);
    try testing.expectEqual(@as(usize, 0), e.blocks.items.len);
    try e.replace(gpa, "");
    var unicode_text: std.ArrayList(u8) = .empty;
    defer unicode_text.deinit(gpa);
    for (0..800) |_| try unicode_text.appendSlice(gpa, "你");
    try e.paste(gpa, unicode_text.items);
    try testing.expectEqual(@as(usize, 0), e.blocks.items.len);
    try unicode_text.appendSlice(gpa, "\u{e000}\u{f0000}");
    try e.replace(gpa, "\u{e000} ");
    try e.paste(gpa, unicode_text.items);
    try testing.expectEqualStrings("\u{e000} [Pasted #1 · 802 chars]", e.text());
    const expanded = try e.expanded(gpa);
    defer gpa.free(expanded);
    try testing.expect(std.mem.endsWith(u8, expanded, unicode_text.items));
    try testing.expect(std.mem.startsWith(u8, expanded, "\u{e000} "));
}

test "paste blocks are atomic and offsets survive insertion and deletion" {
    const gpa = testing.allocator;
    var e: Editor = .{};
    defer e.deinit(gpa);
    const raw = "1\n2\n3\n4\n5\n6";
    try e.insert(gpa, "a");
    try e.paste(gpa, raw);
    const end = e.cursor;
    try e.insert(gpa, "b");
    try press(&e, Key.left, .{});
    try press(&e, Key.left, .{});
    try testing.expectEqual(@as(usize, 1), e.cursor);
    try e.insert(gpa, "z");
    try press(&e, Key.right, .{});
    try testing.expectEqual(end + 1, e.cursor);
    try press(&e, Key.backspace, .{});
    try testing.expectEqualStrings("azb", e.text());
    try testing.expectEqual(@as(usize, 0), e.blocks.items.len);
    try e.paste(gpa, raw);
    try testing.expect(std.mem.indexOf(u8, e.text(), "#2") != null);
    try press(&e, Key.left, .{});
    try press(&e, Key.delete, .{});
    try testing.expectEqualStrings("azb", e.text());
    try e.paste(gpa, raw);
    try press(&e, 'w', .{ .ctrl = true });
    try testing.expectEqualStrings("b", e.text());
    try testing.expectEqual(@as(usize, 0), e.blocks.items.len);
}

test "send expands blocks and history restores process drafts or folds log text" {
    const gpa = testing.allocator;
    var e: Editor = .{};
    defer e.deinit(gpa);
    const raw = "1\n2\n3\n4\n5\n6";
    try e.insert(gpa, "prefix ");
    try e.paste(gpa, raw);
    try e.insert(gpa, " suffix");
    const shown = try gpa.dupe(u8, e.text());
    defer gpa.free(shown);
    const sent = try e.take(gpa);
    defer gpa.free(sent);
    try testing.expectEqualStrings("prefix 1\n2\n3\n4\n5\n6 suffix", sent);
    try testing.expectEqual(@as(usize, 1), e.number);
    try e.paste(gpa, raw);
    const draft_end = e.cursor;
    try press(&e, Key.up, .{});
    try testing.expectEqualStrings(shown, e.text());
    try testing.expectEqual(@as(usize, 1), e.blocks.items.len);
    try testing.expectEqual(@as(usize, 2), e.number);
    try press(&e, Key.down, .{});
    try testing.expectEqualStrings("[Pasted #1 · 6 lines]", e.text());
    try testing.expectEqual(draft_end, e.cursor);
    try e.remember(gpa, sent);
    try press(&e, Key.up, .{});
    try testing.expectEqualStrings("[Pasted #1 · 6 lines]", e.text());
    const restored = try e.expanded(gpa);
    defer gpa.free(restored);
    try testing.expectEqualStrings(sent, restored);
}

test "block columns use label width and drawing wraps labels not payload" {
    const gpa = testing.allocator;
    var e: Editor = .{};
    defer e.deinit(gpa);
    try e.insert(gpa, "你");
    try e.paste(gpa, "1\n2\n3\n4\n5\n6");
    const end = e.cursor;
    try testing.expectEqual(@as(usize, 23), e.column(end));
    try testing.expectEqual(@as(usize, "你".len), e.atColumn(0, 10));
    try e.insert(gpa, "\n12345678901234567890123");
    try press(&e, Key.up, .{});
    try testing.expectEqual(end, e.cursor);
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 12, .rows = 4, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 12, .height = 4, .screen = &screen };
    e.draw(win);
    try testing.expectEqual(@as(u16, 11), screen.cursor.col);
    try testing.expectEqual(@as(u16, 1), screen.cursor.row);
}
