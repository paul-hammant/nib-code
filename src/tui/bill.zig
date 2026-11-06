const std = @import("std");
const ui_format = @import("format.zig");
const TurnSummary = @import("../session/events.zig").TurnSummary;

pub const Text = struct {
    buf: [1024]u8 = undefined,

    pub fn format(text: *Text, summary: TurnSummary, runs: usize, width: u16) []const u8 {
        var wall: [64]u8 = undefined;
        var tok: [64]u8 = undefined;
        var tool: [64]u8 = undefined;
        var output: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&text.buf);
        if (runs > 0) w.print("{d} Run{s}", .{ runs, if (runs == 1) "" else "s" }) catch unreachable;
        if (summary.steps > 0) {
            separator(&w);
            w.print("{d} step{s}", .{ summary.steps, if (summary.steps == 1) "" else "s" }) catch unreachable;
        }
        if (summary.timing.wall_ms > 0) {
            separator(&w);
            w.writeAll(ui_format.duration(&wall, summary.timing.wall_ms)) catch unreachable;
        }
        const total = @as(u128, summary.usage.prompt_tokens) + summary.usage.completion_tokens;
        if (total > 0) {
            separator(&w);
            w.print("{s} tokens", .{ui_format.number(&tok, total)}) catch unreachable;
        }
        if (summary.timing.tool_bytes > 0) {
            separator(&w);
            w.print("tool data {s}", .{ui_format.bytes(&tool, summary.timing.tool_bytes)}) catch unreachable;
            if (summary.timing.output_bytes > 0) w.print(" → {s}", .{ui_format.bytes(&output, summary.timing.output_bytes)}) catch unreachable;
        } else if (summary.timing.output_bytes > 0) {
            separator(&w);
            w.print("Run result {s}", .{ui_format.bytes(&output, summary.timing.output_bytes)}) catch unreachable;
        }
        return fit(w.buffered(), width);
    }

    pub fn details(text: *Text, summary: TurnSummary) []const u8 {
        var wall: [64]u8 = undefined;
        var model: [64]u8 = undefined;
        var run: [64]u8 = undefined;
        return std.fmt.bufPrint(&text.buf, "Last turn · {s}\nTotal {s} · model {s} · Run {s}\nInput {d} tokens · output {d} tokens\nCache {d} tokens · {d}% of input\nDelegation · llm {d} · agent {d}", .{
            @tagName(summary.status),
            ui_format.duration(&wall, summary.timing.wall_ms),
            ui_format.duration(&model, summary.timing.model_ms),
            ui_format.duration(&run, summary.timing.run_ms),
            summary.usage.prompt_tokens,
            summary.usage.completion_tokens,
            summary.usage.prompt_cache_hit_tokens,
            @as(u128, summary.usage.prompt_cache_hit_tokens) * 100 / @max(summary.usage.prompt_tokens, 1),
            summary.timing.llm_calls,
            summary.timing.agent_calls,
        }) catch unreachable;
    }
};

fn separator(w: *std.Io.Writer) void {
    if (w.end > 0) w.writeAll(" · ") catch unreachable;
}

pub fn fit(full: []const u8, width: u16) []const u8 {
    var line = full;
    while ((std.unicode.utf8CountCodepoints(line) catch unreachable) > width) {
        const end = std.mem.lastIndexOf(u8, line, " · ") orelse return "";
        line = line[0..end];
    }
    return line;
}

const example: TurnSummary = .{
    .steps = 3,
    .usage = .{ .prompt_tokens = 6500, .completion_tokens = 100, .prompt_cache_hit_tokens = 6000 },
    .timing = .{ .wall_ms = 41_999, .model_ms = 30_000, .run_ms = 11_000, .tool_bytes = 3_200_000, .output_bytes = 18_000 },
};

test "quiet footer names Runs and units and leaves cache and timing details to status" {
    var text: Text = .{};
    try std.testing.expectEqualStrings("2 Runs · 3 steps · 41s · 6.6k tokens · tool data 3.2MB → 18kB", text.format(example, 2, 200));
    try std.testing.expectEqualStrings("1 Run · 1 step", text.format(.{ .steps = 1 }, 1, 200));
    const details = text.details(example);
    try std.testing.expect(std.mem.indexOf(u8, details, "model 30s · Run 11s") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "Cache 6000 tokens · 92% of input") != null);
}

test "zero statistics and repeated outcomes stay out of the footer" {
    var text: Text = .{};
    try std.testing.expectEqualStrings("", text.format(.{}, 0, 200));
    try std.testing.expectEqualStrings("tool data 320B", text.format(.{ .timing = .{ .tool_bytes = 320 } }, 0, 200));
    try std.testing.expectEqualStrings("Run result 18kB", text.format(.{ .timing = .{ .output_bytes = 18_000 } }, 0, 200));
    inline for (.{ .canceled, .failed }) |outcome| try std.testing.expectEqualStrings("1s", text.format(.{ .status = outcome, .timing = .{ .wall_ms = 1000 } }, 0, 200));
}

test "footer drops complete fields and preserves UTF-8 at every width" {
    var text: Text = .{};
    const full = text.format(example, 2, 200);
    for (0..200) |width| {
        const line = fit(full, @intCast(width));
        try std.testing.expect((try std.unicode.utf8CountCodepoints(line)) <= width);
        try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
        try std.testing.expect(std.mem.startsWith(u8, full, line));
    }
    try std.testing.expectEqualStrings("2 Runs · 3 steps · 41s", fit(full, 22));
}
