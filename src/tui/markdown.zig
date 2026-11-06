const std = @import("std");
const vaxis = @import("vaxis");

const Line = struct {
    text: []const u8,
    code: bool = false,
    heading: bool = false,
};

const Lines = struct {
    text: []const u8,
    pos: usize = 0,
    fence: ?struct { char: u8, len: usize } = null,

    fn next(self: *Lines) ?Line {
        while (self.pos <= self.text.len) {
            const end = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
            const raw = std.mem.trimEnd(u8, self.text[self.pos..end], "\r");
            self.pos = if (end == self.text.len) self.text.len + 1 else end + 1;
            const body = std.mem.trimStart(u8, raw, " ");
            const indent = raw.len - body.len;
            if (indent <= 3 and body.len >= 3 and (body[0] == '`' or body[0] == '~')) {
                const n = std.mem.indexOfNone(u8, body, body[0..1]) orelse body.len;
                if (n >= 3) {
                    if (self.fence) |f| {
                        if (body[0] == f.char and n >= f.len and std.mem.trim(u8, body[n..], " \t").len == 0) {
                            self.fence = null;
                            continue;
                        }
                    } else {
                        self.fence = .{ .char = body[0], .len = n };
                        continue;
                    }
                }
            }
            if (self.fence != null) return .{ .text = raw, .code = true };
            const marks = std.mem.indexOfNone(u8, body, "#") orelse body.len;
            if (indent <= 3 and marks > 0 and marks <= 6 and marks < body.len and body[marks] == ' ')
                return .{ .text = body[marks + 1 ..], .heading = true };
            return .{ .text = raw };
        }
        return null;
    }
};

const Inline = struct {
    text: []const u8,
    pos: usize = 0,
    base: vaxis.Style = .{},

    fn next(self: *Inline) ?vaxis.Segment {
        if (self.pos >= self.text.len) return null;
        var i = self.pos;
        while (i < self.text.len) : (i += 1) {
            const mark: []const u8 = if (self.text[i] == '`') "`" else if (std.mem.startsWith(u8, self.text[i..], "**")) "**" else continue;
            const end = std.mem.indexOfPos(u8, self.text, i + mark.len, mark) orelse continue;
            if (i > self.pos) {
                const plain = self.text[self.pos..i];
                self.pos = i;
                return .{ .text = plain, .style = self.base };
            }
            self.pos = end + mark.len;
            var style = self.base;
            if (mark[0] == '`') {
                style.fg = .{ .index = 3 };
            } else {
                style.bold = true;
            }
            return .{ .text = self.text[i + mark.len .. end], .style = style };
        }
        const plain = self.text[self.pos..];
        self.pos = self.text.len;
        return .{ .text = plain, .style = self.base };
    }
};

fn rows(result: vaxis.Window.PrintResult) u16 {
    return @max(1, result.row + @intFromBool(result.col > 0));
}

fn codeLine(win: vaxis.Window, text: []const u8, commit: bool) u16 {
    const style: vaxis.Style = .{ .fg = .{ .index = 3 } };
    var result: vaxis.Window.PrintResult = .{ .row = 0, .col = 0, .overflow = false };
    var pos: usize = 0;
    while (pos < text.len) {
        const tab = std.mem.indexOfScalarPos(u8, text, pos, '\t') orelse text.len;
        result = win.printSegment(.{ .text = text[pos..tab], .style = style }, .{ .row_offset = result.row, .col_offset = result.col, .commit = commit });
        if (tab == text.len) break;
        result = win.printSegment(.{ .text = "    ", .style = style }, .{ .row_offset = result.row, .col_offset = result.col, .commit = commit });
        pos = tab + 1;
    }
    return rows(result);
}

fn printLine(row: vaxis.Window, line: Line, commit: bool) u16 {
    var used: u16 = 1;
    if (line.code) {
        if (row.width > 2) {
            _ = row.printSegment(.{ .text = "│ ", .style = .{ .dim = true, .fg = .{ .index = 4 } } }, .{ .commit = commit });
            used = codeLine(row.child(.{ .x_off = 2 }), line.text, commit);
        } else {
            used = codeLine(row, line.text, commit);
        }
    } else {
        var spans: Inline = .{ .text = line.text, .base = if (line.heading) .{ .bold = true, .fg = .{ .index = 4 } } else .{} };
        var result: vaxis.Window.PrintResult = .{ .row = 0, .col = 0, .overflow = false };
        while (spans.next()) |segment| {
            result = row.printSegment(segment, .{ .row_offset = result.row, .col_offset = result.col, .wrap = .word, .commit = commit });
        }
        used = rows(result);
    }
    return used;
}

pub fn print(win: vaxis.Window, text: []const u8, commit: bool) u16 {
    var lines: Lines = .{ .text = text };
    var height: u16 = 0;
    while (lines.next()) |line| {
        const row = win.child(.{ .y_off = @intCast(height) });
        const used = printLine(row, line, commit);
        height +|= used;
    }
    return @max(1, height);
}

test "fences, indentation, and headings" {
    var lines: Lines = .{ .text = "~~~zig\n  one\n~~~\n```\ntwo" };
    try std.testing.expectEqualDeep(Line{ .text = "  one", .code = true }, lines.next().?);
    try std.testing.expectEqualDeep(Line{ .text = "two", .code = true }, lines.next().?);
    try std.testing.expect(lines.next() == null);

    lines = .{ .text = "  # Title\n    # plain" };
    try std.testing.expectEqualDeep(Line{ .text = "Title", .heading = true }, lines.next().?);
    try std.testing.expectEqualDeep(Line{ .text = "    # plain" }, lines.next().?);
}

test "inline code and bold" {
    var spans: Inline = .{ .text = "a **bold** `code` end" };
    try std.testing.expectEqualStrings("a ", spans.next().?.text);
    const bold = spans.next().?;
    try std.testing.expectEqualStrings("bold", bold.text);
    try std.testing.expect(bold.style.bold);
    try std.testing.expectEqualStrings(" ", spans.next().?.text);
    const code = spans.next().?;
    try std.testing.expectEqualStrings("code", code.text);
    try std.testing.expectEqual(vaxis.Color{ .index = 3 }, code.style.fg);
    try std.testing.expectEqualStrings(" end", spans.next().?.text);
    try std.testing.expect(spans.next() == null);
}

test "rendered rows and styles match measurement" {
    const alloc = std.testing.allocator;
    var screen = try vaxis.Screen.init(alloc, .{ .cols = 8, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(alloc);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 8,
        .height = 12,
        .screen = &screen,
    };
    try std.testing.expectEqual(@as(u16, 1), print(win, "12345678", false));
    try std.testing.expectEqual(@as(u16, 2), print(win, "abcde **def**", false));
    try std.testing.expectEqual(@as(u16, 2), print(win, "abcde **def**", true));
    try std.testing.expect(screen.readCell(0, 1).?.style.bold);
    screen.clear();
    try std.testing.expectEqual(@as(u16, 3), print(win, "```\n\txyz\n```\nlast", false));
    try std.testing.expectEqual(@as(u16, 3), print(win, "```\n\txyz\n```\nlast", true));
    try std.testing.expectEqualStrings("│", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("z", screen.readCell(2, 1).?.char.grapheme);
    screen.clear();
    try std.testing.expectEqual(@as(u16, 2), print(win, "~~~\n1234567", false));
    try std.testing.expectEqual(@as(u16, 2), print(win, "~~~\n1234567", true));
}

pub const Cache = struct {
    const CachedLine = struct { offset: usize, len: usize, code: bool, heading: bool, y: u16, rows: u16 };
    lines: std.ArrayList(CachedLine) = .empty,
    width: u16 = 0,
    pos: usize = 0,
    fence: @FieldType(Lines, "fence") = null,
    height: u16 = 0,

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        c.lines.deinit(gpa);
    }

    pub fn draw(c: *Cache, gpa: std.mem.Allocator, win: vaxis.Window, text: []const u8, commit: bool) u16 {
        if (c.width != win.width or c.pos > text.len) {
            c.lines.clearRetainingCapacity();
            c.width = win.width;
            c.pos = 0;
            c.fence = null;
            c.height = 0;
        }
        var parser: Lines = .{ .text = text, .pos = c.pos, .fence = c.fence };
        while (true) {
            const before = parser;
            const line = parser.next() orelse break;
            if (parser.pos > text.len) {
                parser = before;
                break;
            }
            const h = printLine(win, line, false);
            c.lines.append(gpa, .{ .offset = @intFromPtr(line.text.ptr) - @intFromPtr(text.ptr), .len = line.text.len, .code = line.code, .heading = line.heading, .y = c.height, .rows = h }) catch return print(win, text, commit);
            c.height +|= h;
            c.pos = parser.pos;
            c.fence = parser.fence;
        }
        if (commit) for (c.lines.items) |line| {
            if (@as(i32, win.y_off) + line.y + line.rows <= 0) continue;
            if (@as(i32, win.y_off) + line.y >= win.screen.height) break;
            _ = printLine(win.child(.{ .y_off = @intCast(line.y) }), .{ .text = text[line.offset..][0..line.len], .code = line.code, .heading = line.heading }, true);
        };
        var height = c.height;
        parser = .{ .text = text, .pos = c.pos, .fence = c.fence };
        while (parser.next()) |line| height +|= printLine(win.child(.{ .y_off = @intCast(height) }), line, commit);
        return @max(1, height);
    }
};

test "cached append and resize match uncached markdown" {
    const a = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(a);
    var screen = try vaxis.Screen.init(a, .{ .cols = 60, .rows = 32, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 32, .screen = &screen };
    const text = "# Heading\n**late\nclose**\n```zig\ncode\n```\n中文 👩‍💻 tail";
    for ([_]u16{ 60, 20, 60 }) |width| {
        win.width = width;
        for (0..text.len + 1) |n| {
            if (!std.unicode.utf8ValidateSlice(text[0..n])) continue;
            try std.testing.expectEqual(print(win, text[0..n], false), cache.draw(a, win, text[0..n], false));
            for ([_]i17{ 0, -3, -10 }) |offset| {
                win.y_off = offset;
                win.clear();
                _ = print(win, text[0..n], true);
                const expected = try a.dupe(vaxis.Cell, screen.buf);
                defer a.free(expected);
                win.clear();
                _ = cache.draw(a, win, text[0..n], true);
                try std.testing.expectEqualDeep(expected, screen.buf);
            }
            win.y_off = 0;
        }
    }
}
