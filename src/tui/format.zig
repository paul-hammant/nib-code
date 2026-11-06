const std = @import("std");

pub fn state(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "working")) return "running";
    if (std.mem.eql(u8, raw, "done") or std.mem.eql(u8, raw, "ok")) return "completed";
    if (std.mem.eql(u8, raw, "timed_out")) return "timed out";
    return raw;
}

pub fn duration(buf: []u8, ms: u64) []const u8 {
    const s = ms / 1000;
    if (s == 0) return "<1s";
    if (s >= 3600) return std.fmt.bufPrint(buf, "{d}h{d}m{d}s", .{ s / 3600, s % 3600 / 60, s % 60 }) catch unreachable;
    if (s >= 60) return std.fmt.bufPrint(buf, "{d}m{d}s", .{ s / 60, s % 60 }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch unreachable;
}

pub fn number(buf: []u8, n: u128) []const u8 {
    const unit: u128 = if (n >= 1_000_000) 1_000_000 else if (n >= 1000) 1000 else 1;
    if (unit == 1) return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
    const suffix = if (unit == 1000) "k" else "M";
    const tenths = n % unit * 10 / unit;
    if (tenths == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ n / unit, suffix }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ n / unit, tenths, suffix }) catch unreachable;
}

pub fn bytes(buf: []u8, n: u64) []const u8 {
    var digits: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}B", .{number(&digits, n)}) catch unreachable;
}

pub const Fitted = struct { text: []const u8, suffix: []const u8 = "" };

pub fn fit(text: []const u8, columns: u16) Fitted {
    const vaxis = @import("vaxis");
    if (vaxis.gwidth.gwidth(text, .unicode) <= columns) return .{ .text = text };
    if (columns == 0) return .{ .text = "" };
    var end: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |grapheme| {
        const next = end + grapheme.bytes(text).len;
        if (vaxis.gwidth.gwidth(text[0..next], .unicode) > columns - 1) break;
        end = next;
    }
    return .{ .text = text[0..end], .suffix = "…" };
}

test "UI state vocabulary and decimal units" {
    const t = std.testing;
    try t.expectEqualStrings("running", state("working"));
    try t.expectEqualStrings("completed", state("done"));
    try t.expectEqualStrings("completed", state("ok"));
    try t.expectEqualStrings("timed out", state("timed_out"));
    var buf: [64]u8 = undefined;
    inline for (.{ .{ 0, "<1s" }, .{ 999, "<1s" }, .{ 1000, "1s" }, .{ 59_999, "59s" }, .{ 100_000, "1m40s" }, .{ 3_661_999, "1h1m1s" } }) |c| try t.expectEqualStrings(c[1], duration(&buf, c[0]));
    try t.expectEqualStrings("6.6k", number(&buf, 6699));
    try t.expectEqualStrings("18kB", bytes(&buf, 18_000));
    try t.expectEqualStrings("3.2MB", bytes(&buf, 3_200_000));
}

test "single-line previews mark omissions and preserve graphemes" {
    const result = fit("á👩‍💻xyz", 4);
    try std.testing.expectEqualStrings("á👩‍💻", result.text);
    try std.testing.expectEqualStrings("…", result.suffix);
    try std.testing.expectEqualStrings("", fit("word", 0).text);
}
