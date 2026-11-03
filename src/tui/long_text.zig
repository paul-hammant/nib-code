const std = @import("std");

pub fn lines(text: []const u8) usize {
    return 1 + std.mem.count(u8, text, "\n");
}

pub fn chars(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn isLong(text: []const u8) bool {
    return lines(text) > 5 or chars(text) > 800;
}
