const std = @import("std");
const Task = @import("../tools/background.zig").Background.Task;
const appendElapsed = @import("agent_tree.zig").appendElapsed;

pub fn format(a: std.mem.Allocator, tasks: []const Task, now_ms: i64) ![]const u8 {
    if (tasks.len == 0) return "no background tasks in this Session";
    var text: std.ArrayList(u8) = .empty;
    for (tasks, 0..) |task, i| {
        if (i > 0) try text.append(a, '\n');
        try text.print(a, "{s} {s} · {s} · ", .{ task.id, @tagName(task.kind), task.state });
        try appendElapsed(a, &text, task.elapsed_ms);
        if (task.detached) {
            try text.appendSlice(a, " · no deadline (detached)");
        } else if (task.deadline_ms) |deadline| {
            const seconds = (std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(@max(deadline, 0), 1000)) }).getDaySeconds();
            try text.print(a, " · deadline {d:0>2}:{d:0>2}:{d:0>2} UTC ({d}s)", .{ seconds.getHoursIntoDay(), seconds.getMinutesIntoHour(), seconds.getSecondsIntoMinute(), @divTrunc(@max(deadline - now_ms, 0), 1000) });
        } else try text.appendSlice(a, if (task.kind == .run) " · per-tool deadlines" else " · deadline pending");
        try text.print(a, " · {s}", .{task.description});
    }
    for (text.items) |*c| if (c.* < 0x20 and c.* != '\n' or c.* == 0x7f) {
        c.* = ' ';
    };
    return text.toOwnedSlice(a);
}

test "tasks include state elapsed deadlines and detached lifetime" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("no background tasks in this Session", try format(a, &.{}, 0));
    const text = try format(a, &.{
        .{ .id = "a1", .kind = .agent, .description = "investigate", .state = "working", .elapsed_ms = 1200, .deadline_ms = 30000 },
        .{ .id = "b1", .kind = .bash, .description = "server", .state = "working", .elapsed_ms = 61000, .detached = true },
        .{ .id = "r1", .kind = .run, .description = "Run (step 1)", .state = "done", .elapsed_ms = 10000 },
    }, 10000);
    try std.testing.expectEqualStrings("a1 agent · working · 1.2s · deadline 00:00:30 UTC (20s) · investigate\nb1 bash · working · 1m1s · no deadline (detached) · server\nr1 run · done · 10.0s · per-tool deadlines · Run (step 1)", text);
}
