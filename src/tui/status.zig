const std = @import("std");
const provider = @import("../provider.zig");

pub const Phase = enum { thinking, writing, running, retrying, compacting };

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// What the running Turn is doing and since when.
pub const Activity = struct {
    phase: Phase = .thinking,
    since: std.Io.Clock.Timestamp,

    pub const Label = struct { phase: Phase, ms: u64 };

    pub fn start(io: std.Io, phase: Phase) Activity {
        return .{ .phase = phase, .since = .now(io, .awake) };
    }

    pub fn set(a: *Activity, io: std.Io, phase: Phase) void {
        if (a.phase == phase) return;
        a.* = start(io, phase);
    }

    pub fn label(a: Activity, io: std.Io) Label {
        return .{ .phase = a.phase, .ms = @intCast(@max(a.since.untilNow(io).raw.toMilliseconds(), 0)) };
    }
};

pub const Status = struct {
    cfg: provider.Config,
    usage: provider.Usage = .{},
    steps: u32 = 0,
    context: u64 = 0,
    /// Set while a Turn runs.
    busy: ?Activity.Label = null,
};

/// Text the status line prints; owned by the caller because vaxis reads
/// printed slices only at render time.
pub const Text = struct {
    status: [320]u8 = undefined,
    activity: [64]u8 = undefined,

    pub fn format(text: *Text, s: Status, scrolled: bool) []const u8 {
        const doing: []const u8 = if (s.busy) |b|
            std.fmt.bufPrint(&text.activity, "{s} {s} {d}s", .{ spinner[(b.ms / 100) % spinner.len], @tagName(b.phase), b.ms / 1000 }) catch ""
        else
            "";
        const separator: []const u8 = if (doing.len > 0) " · " else "";
        if (scrolled) return std.fmt.bufPrint(&text.status, "{s}{s}↑ history", .{ doing, separator }) catch "";
        return std.fmt.bufPrint(&text.status, "{s}{s}{s} · effort {s} · ctx {d}% · last turn: {d} steps, in {d} (cache {d}), out {d}", .{
            doing,
            separator,
            s.cfg.model,
            s.cfg.effectiveEffort(),
            s.context * 100 / @max(s.cfg.context_window, 1),
            s.steps,
            s.usage.prompt_tokens,
            s.usage.prompt_cache_hit_tokens,
            s.usage.completion_tokens,
        }) catch "";
    }
};

test "status line shows activity first, and only history hints while scrolled" {
    var text: Text = .{};
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "m", .context_window = 1000 };
    const idle = text.format(.{ .cfg = cfg, .context = 250, .steps = 2 }, false);
    try std.testing.expect(std.mem.startsWith(u8, idle, "m · effort "));
    try std.testing.expect(std.mem.indexOf(u8, idle, "ctx 25% · last turn: 2 steps") != null);
    try std.testing.expectEqualStrings("⠙ running 0s · ↑ history", text.format(.{ .cfg = cfg, .busy = .{ .phase = .running, .ms = 150 } }, true));
}
