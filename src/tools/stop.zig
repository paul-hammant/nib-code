const std = @import("std");
const tools = @import("../tools.zig");
const sandbox = @import("../sandbox.zig");

pub fn stop(t: *tools.Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const parsed = std.json.parseFromSlice(struct { id: []const u8, reason: ?[]const u8 = null }, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return tools.fail(gpa, "expected {{ id: string, reason: string }}", .{});
    defer parsed.deinit();
    const reason = parsed.value.reason orelse "";
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0)
        return tools.fail(gpa, "stop requires a nonempty reason. Canceling a running test discards its progress and prevents a completed validation result. Elapsed time or no output alone does not mean it is stuck; reply without tools to wait locally. Stop only for a concrete failure, changed requirement or user request.", .{});
    const stopped = try t.background.stopById(t.io, parsed.value.id);
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .id = parsed.value.id, .stopped = stopped, .reason = reason, .notice = if (stopped) @as(?[]const u8, "Task canceled; unfinished validation has no passing result. Restarting repeats its work.") else null }, .{ .emit_null_optional_fields = false }) };
}
