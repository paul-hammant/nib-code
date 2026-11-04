const std = @import("std");
const tools = @import("../tools.zig");
const sandbox = @import("../sandbox.zig");

pub fn stop(t: *tools.Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const parsed = std.json.parseFromSlice(struct { id: []const u8 }, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return tools.fail(gpa, "expected {{ id: string }}", .{});
    defer parsed.deinit();
    const stopped = try t.background.stopById(t.io, parsed.value.id);
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .id = parsed.value.id, .stopped = stopped }, .{}) };
}
