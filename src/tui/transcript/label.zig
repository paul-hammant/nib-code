const std = @import("std");
const ToolSummary = @import("../../session/tool_summary.zig").Summary;

pub fn actualToolSummary(summary: ToolSummary, changed_files: usize, buf: []u8) []const u8 {
    if (summary.counts.len == 0 and summary.omitted == 0) return "";
    var w: std.Io.Writer = .fixed(buf);
    var changed_shown = false;
    for (summary.counts) |call| {
        const changed = changed_files > 0 and (std.mem.eql(u8, call.name, "edit") or std.mem.eql(u8, call.name, "write"));
        if (changed and changed_shown) continue;
        if (w.end > 0) w.writeAll(" · ") catch break;
        if (changed) {
            w.print("edit {d} file{s}", .{ changed_files, if (changed_files == 1) "" else "s" }) catch break;
            changed_shown = true;
        } else {
            w.writeAll(call.name) catch break;
            if (call.count > 1) w.print(" ×{d}", .{call.count}) catch break;
        }
    }
    if (summary.omitted > 0) {
        if (summary.counts.len > 0) w.writeAll(" · ") catch {};
        w.print("+{d}", .{summary.omitted}) catch {};
    }
    return w.buffered();
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
