const std = @import("std");
const vaxis = @import("vaxis");

pub const Range = struct { start: usize, end: usize };

/// Changed middle of a line within its content, as byte offsets.
pub const Middle = struct { old: Range, new: Range };

/// A changed middle above this share of the longer line means the line was rewritten.
const max_middle_percent = 60;

fn graphemeBoundaries(text: []const u8, at: usize) usize {
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const start = g.start;
        if (start >= at) return start;
    }
    return text.len;
}

/// Common prefix and suffix on grapheme boundaries; null when emphasis would add nothing.
pub fn middle(old: []const u8, new: []const u8) ?Middle {
    if (old.len == 0 or new.len == 0) return null;
    var prefix: usize = 0;
    var a = vaxis.unicode.graphemeIterator(old);
    var b = vaxis.unicode.graphemeIterator(new);
    while (a.next()) |ga| {
        const gb = b.next() orelse break;
        if (!std.mem.eql(u8, ga.bytes(old), gb.bytes(new))) break;
        prefix = ga.start + ga.len;
    }
    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;
    while (suffix > 0) {
        const old_at = graphemeBoundaries(old[prefix..], old.len - prefix - suffix) + prefix;
        const new_at = graphemeBoundaries(new[prefix..], new.len - prefix - suffix) + prefix;
        const fit = @min(old.len - old_at, new.len - new_at);
        if (fit == suffix) break;
        suffix = fit;
    }
    const result: Middle = .{
        .old = .{ .start = prefix, .end = old.len - suffix },
        .new = .{ .start = prefix, .end = new.len - suffix },
    };
    const old_len = result.old.end - result.old.start;
    const new_len = result.new.end - result.new.start;
    if (old_len == 0 and new_len == 0) return null;
    const longer = @max(old.len, new.len);
    if (@max(old_len, new_len) * 100 > max_middle_percent * longer) return null;
    return result;
}

/// Walks diff text one line at a time (lines keep their trailing newline) and pairs
/// each `-` line of a run with the `+` line at the same position of the run that
/// directly follows, when both runs have the same length.
pub const Lines = struct {
    text: []const u8,
    pos: usize = 0,
    mode: enum { none, skip, minus, plus } = .none,
    remaining: usize = 0,
    partner: usize = 0,
    minus_start: usize = 0,

    pub const Item = struct {
        line: []const u8,
        /// Changed part of the line, offsets into `line` (after the sign), when paired.
        emphasis: ?Range = null,
    };

    fn lineEnd(self: *const Lines, at: usize) usize {
        return if (std.mem.indexOfScalarPos(u8, self.text, at, '\n')) |nl| nl + 1 else self.text.len;
    }

    fn body(line: []const u8) []const u8 {
        return std.mem.trimEnd(u8, line[1..], "\r\n");
    }

    fn runLength(self: *const Lines, from: usize, sign: u8) struct { count: usize, end: usize } {
        var at = from;
        var count: usize = 0;
        while (at < self.text.len and self.text[at] == sign) : (count += 1) at = self.lineEnd(at);
        return .{ .count = count, .end = at };
    }

    pub fn next(self: *Lines) ?Item {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        const end = self.lineEnd(start);
        self.pos = end;
        const line = self.text[start..end];
        switch (line[0]) {
            '-' => {
                if (self.mode == .none) {
                    const minus = self.runLength(start, '-');
                    const plus = self.runLength(minus.end, '+');
                    if (minus.count == plus.count) {
                        self.mode = .minus;
                        self.remaining = minus.count;
                        self.partner = minus.end;
                        self.minus_start = start;
                    } else if (minus.count + plus.count > 1) {
                        self.mode = .skip;
                        self.remaining = minus.count + plus.count;
                    }
                }
            },
            '+' => if (self.mode == .none) {
                const plus = self.runLength(start, '+');
                if (plus.count > 1) {
                    self.mode = .skip;
                    self.remaining = plus.count;
                }
            },
            else => self.mode = .none,
        }
        switch (self.mode) {
            .none => return .{ .line = line },
            .skip => {
                self.remaining -= 1;
                if (self.remaining == 0) self.mode = .none;
                return .{ .line = line };
            },
            .minus, .plus => {
                const partner_end = self.lineEnd(self.partner);
                const partner = self.text[self.partner..partner_end];
                const found = if (self.mode == .minus) middle(body(line), body(partner)) else middle(body(partner), body(line));
                self.partner = partner_end;
                self.remaining -= 1;
                if (self.remaining == 0) {
                    if (self.mode == .minus) {
                        self.mode = .plus;
                        self.remaining = self.runLength(self.minus_start, '-').count;
                        self.partner = self.minus_start;
                    } else self.mode = .none;
                }
                const m = found orelse return .{ .line = line };
                const r = if (line[0] == '-') m.old else m.new;
                if (r.start == r.end) return .{ .line = line };
                return .{ .line = line, .emphasis = .{ .start = r.start + 1, .end = r.end + 1 } };
            },
        }
    }
};

const testing = std.testing;

fn expectMiddle(old: []const u8, new: []const u8, want_old: []const u8, want_new: []const u8) !void {
    const m = middle(old, new) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(want_old, old[m.old.start..m.old.end]);
    try testing.expectEqualStrings(want_new, new[m.new.start..m.new.end]);
}

test "middle trims the common prefix and suffix" {
    try expectMiddle("const value = compute(a, b);", "const value = compute(a, c, b);", "", "c, ");
    try expectMiddle("let count = 10;", "let count = 11;", "0", "1");
    try expectMiddle("    return foo(x) + 1;", "    return bar(x) + 1;", "foo", "bar");
    try expectMiddle("pub fn init(gpa: Allocator) !Self {", "pub fn init(gpa: Allocator, io: Io) !Self {", "", ", io: Io");
    try expectMiddle("abcdefghij klmnop", "abcdefghij xlmnop", "k", "x");
}

test "middle skips rewritten, empty and identical lines" {
    try testing.expect(middle("hello world", "goodbye") == null);
    try testing.expect(middle("", "x") == null);
    try testing.expect(middle("x", "") == null);
    try testing.expect(middle("same", "same") == null);
    try testing.expect(middle("ab", "cd") == null);
    // 6 of 10 bytes is within the limit, 7 of 10 is not
    try testing.expect(middle("aaaXXXXXXa", "aaaYYYYYYa") != null);
    try testing.expect(middle("aaXXXXXXXa", "aaYYYYYYYa") == null);
}

test "middle splits only on grapheme boundaries" {
    try expectMiddle("名前: 太郎 です", "名前: 次郎 です", "太", "次");
    try expectMiddle("x = é end suffix text", "x = ê end suffix text", "é", "ê");
    try expectMiddle("aaaaaaaa e\u{301}", "aaaaaaaa e\u{302}", "e\u{301}", "e\u{302}");
    try expectMiddle("aaaaaaaa 👩‍💻 b", "aaaaaaaa 👨‍💻 b", "👩‍💻", "👨‍💻");
    try expectMiddle("aaaaaaaa e\u{301}z", "aaaaaaaa o\u{301}z", "e\u{301}", "o\u{301}");
    const m = middle("long prefix text é suffix text", "long prefix text è suffix text").?;
    try testing.expect(std.unicode.utf8ValidateSlice("long prefix text é suffix text"[0..m.old.start]));
}

fn collect(text: []const u8, out: *[16]Lines.Item) usize {
    var lines: Lines = .{ .text = text };
    var n: usize = 0;
    while (lines.next()) |item| : (n += 1) out[n] = item;
    return n;
}

fn emphasized(item: Lines.Item) []const u8 {
    const e = item.emphasis orelse return "";
    return item.line[e.start..e.end];
}

test "equal runs pair line by line" {
    var items: [16]Lines.Item = undefined;
    const text = " ctx\n-let a = 1;\n-let b = 2;\n+let a = 3;\n+let b = 4;\n ctx\n";
    try testing.expectEqual(@as(usize, 6), collect(text, &items));
    try testing.expectEqualStrings("1", emphasized(items[1]));
    try testing.expectEqualStrings("2", emphasized(items[2]));
    try testing.expectEqualStrings("3", emphasized(items[3]));
    try testing.expectEqualStrings("4", emphasized(items[4]));
    try testing.expect(items[0].emphasis == null and items[5].emphasis == null);
    try testing.expectEqualStrings("-let a = 1;\n", items[1].line);
}

test "unequal runs, lone lines and headers get no emphasis" {
    var items: [16]Lines.Item = undefined;
    var n = collect("-let a = 1;\n-let b = 2;\n+let a = 3;\n", &items);
    try testing.expectEqual(@as(usize, 3), n);
    for (items[0..n]) |item| try testing.expect(item.emphasis == null);
    n = collect("-let a = 1;\n+let a = 3;\n+let b = 3;\n", &items);
    for (items[0..n]) |item| try testing.expect(item.emphasis == null);
    n = collect("-let a = 1;\n-let b = 2;\n+let b = 3;\n", &items);
    try testing.expect(items[2].emphasis == null and items[1].emphasis == null);
    // the unpaired minus run must not make its tail pair up on its own
    n = collect("-let a = 1;\n-let b = 2;\n-let c = 3;\n+let c = 4;\n", &items);
    for (items[0..n]) |item| try testing.expect(item.emphasis == null);
    n = collect("-only removed 1\n x\n+only added 1\n", &items);
    for (items[0..n]) |item| try testing.expect(item.emphasis == null);
    n = collect("src/a.zig +1 −1\n-let a = 1;\n+let a = 2;\n", &items);
    try testing.expect(items[0].emphasis == null);
    try testing.expectEqualStrings("1", emphasized(items[1]));
    try testing.expectEqualStrings("2", emphasized(items[2]));
}

test "consecutive pairs and empty lines" {
    var items: [16]Lines.Item = undefined;
    var n = collect("-a1 text here\n+a2 text here\n x\n-b1 text here\n+b2 text here\n", &items);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("1", emphasized(items[0]));
    try testing.expectEqualStrings("2", emphasized(items[1]));
    try testing.expectEqualStrings("1", emphasized(items[3]));
    try testing.expectEqualStrings("2", emphasized(items[4]));
    n = collect("-\n+text\n", &items);
    for (items[0..n]) |item| try testing.expect(item.emphasis == null);
    n = collect("-keep this line a\n+keep this line b", &items);
    try testing.expectEqualStrings("a", emphasized(items[0]));
    try testing.expectEqualStrings("b", emphasized(items[1]));
}
