const std = @import("std");
const Progress = @import("../../session/events.zig").Progress;
const ToolSummary = @import("../../session/tool_summary.zig").Summary;

/// What a Run changed, as shown: the one-line summary and the colored diff.
pub fn appendHead(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, max_lines: usize) !void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        if (n == max_lines) {
            var rest: usize = 1;
            while (it.next()) |_| rest += 1;
            try out.print(gpa, "\n… {d} more lines", .{rest});
            return;
        }
        if (n > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, line);
    }
}

pub fn actualToolSummary(summary: ToolSummary, buf: []u8) []const u8 {
    if (summary.counts.len == 0 and summary.omitted == 0) return "js";
    var w: std.Io.Writer = .fixed(buf);
    for (summary.counts, 0..) |call, i| {
        if (i > 0) w.writeAll(", ") catch break;
        w.writeAll(call.name) catch break;
        if (call.count > 1) w.print(" ×{d}", .{call.count}) catch break;
    }
    if (summary.omitted > 0) {
        if (summary.counts.len > 0) w.writeAll(", ") catch {};
        w.print("+{d}", .{summary.omitted}) catch {};
    }
    return w.buffered();
}

/// Source estimate used until actual calls are available.
pub fn toolSummary(code: []const u8, buf: []u8) []const u8 {
    var names: [8][]const u8 = undefined;
    var counts: [8]u32 = undefined;
    var n: usize = 0;
    var rest = code;
    while (std.mem.indexOf(u8, rest, "tools.")) |i| {
        rest = rest[i + 6 ..];
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
        if (end == 0) continue;
        const name = rest[0..end];
        for (names[0..n], counts[0..n]) |known, *count| {
            if (std.mem.eql(u8, known, name)) {
                count.* += 1;
                break;
            }
        } else if (n < names.len) {
            names[n] = name;
            counts[n] = 1;
            n += 1;
        }
    }
    if (n == 0) return "js";
    var w: std.Io.Writer = .fixed(buf);
    for (names[0..n], counts[0..n], 0..) |name, count, i| {
        if (i > 0) w.writeAll(", ") catch break;
        w.writeAll(name) catch break;
        if (count > 1) w.print(" ×{d}", .{count}) catch break;
    }
    return w.buffered();
}

pub fn appendAction(gpa: std.mem.Allocator, out: *std.ArrayList(u8), p: Progress) !void {
    if (p.tools.len == 0 and p.files.len == 0) return;
    try out.appendSlice(gpa, " · ");
    for (p.tools, 0..) |name, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, name);
    }
    for (p.files, 0..) |path, i| {
        if (i > 0) try out.appendSlice(gpa, ", ") else if (p.tools.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, path);
    }
}

pub fn appendTokens(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tokens: u64) !void {
    var buf: [64]u8 = undefined;
    try out.print(gpa, " · {s} tokens", .{@import("../format.zig").number(&buf, tokens)});
}

pub fn promptPrefix(prompt: []const u8) []const u8 {
    var end: usize = 0;
    var count: usize = 0;
    while (end < prompt.len and count < 40) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(prompt[end]) catch 1;
        end = @min(prompt.len, end + len);
    }
    return prompt[0..end];
}

pub fn appendPreview(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (promptPrefix(value)) |byte| try out.append(gpa, if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte);
}

const testing = std.testing;

test "toolSummary" {
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("js", toolSummary("1 + 1", &buf));
    try testing.expectEqualStrings("agent ×2", toolSummary("Promise.all([tools.agent({}), tools.agent({})])", &buf));
}
