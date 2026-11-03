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
    current_step: u32 = 1,
    context: u64 = 0,
    /// Set while a Turn runs.
    busy: ?Activity.Label = null,
    /// A transient message, such as a copy confirmation.
    notice: ?[]const u8 = null,
};

/// Printed slices must survive until vaxis renders the frame.
pub const Text = struct {
    status: [512]u8 = undefined,
    activity: [512]u8 = undefined,

    pub fn format(text: *Text, s: Status, scrolled: bool) []const u8 {
        var w: std.Io.Writer = .fixed(&text.activity);
        if (s.busy) |b| w.print("{s} {s} {d}s · step {d} · esc to cancel", .{ spinner[(b.ms / 100) % spinner.len], @tagName(b.phase), b.ms / 1000, s.current_step }) catch {};
        if (scrolled) {
            if (w.end > 0) w.writeAll(" · ") catch {};
            w.writeAll("↑ history · PgDn to return") catch {};
        }
        if (s.notice) |notice| {
            if (w.end > 0) w.writeAll(" · ") catch {};
            w.writeAll(notice) catch {};
        }
        return w.buffered();
    }

    pub fn footer(text: *Text, s: Status, width: u16) []const u8 {
        var input: [32]u8 = undefined;
        var output: [32]u8 = undefined;
        var line = std.fmt.bufPrint(&text.status, "{s} · effort {s} · ctx {d}% · in {s} ({d}% cached) · out {s} · {s}: {d} steps", .{
            s.cfg.model,                                 s.cfg.effectiveEffort(),                                                s.context * 100 / @max(s.cfg.context_window, 1),
            tokens(&input, s.usage.prompt_tokens),       s.usage.prompt_cache_hit_tokens * 100 / @max(s.usage.prompt_tokens, 1), tokens(&output, s.usage.completion_tokens),
            if (s.busy != null) "turn" else "last turn", s.steps,
        }) catch "";
        while (std.mem.lastIndexOf(u8, line, " · ")) |separator| {
            if (@import("vaxis").gwidth.gwidth(line, .unicode) <= width) break;
            line = line[0..separator];
        }
        return line;
    }
};

fn tokens(buf: []u8, n: u64) []const u8 {
    const unit: u64 = if (n >= 1_000_000) 1_000_000 else if (n >= 1000) 1000 else 1;
    if (unit == 1) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
    const suffix = if (unit == 1000) "k" else "M";
    const tenths = n % unit * 10 / unit;
    if (tenths == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ n / unit, suffix }) catch "";
    return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ n / unit, tenths, suffix }) catch "";
}

test "activity is optional and footer shows latest reported usage" {
    var text: Text = .{};
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "m", .context_window = 1000 };
    try std.testing.expectEqualStrings("", text.format(.{ .cfg = cfg }, false));
    try std.testing.expectEqualStrings("↑ history · PgDn to return", text.format(.{ .cfg = cfg }, true));
    try std.testing.expectEqualStrings("⠙ running 0s · step 2 · esc to cancel · copied 3 chars", text.format(.{ .cfg = cfg, .current_step = 2, .busy = .{ .phase = .running, .ms = 150 }, .notice = "copied 3 chars" }, false));
    const line = text.footer(.{ .cfg = cfg, .context = 250, .steps = 2, .usage = .{ .prompt_tokens = 1_800_000, .prompt_cache_hit_tokens = 1_692_000, .completion_tokens = 18_000 } }, 200);
    try std.testing.expectEqualStrings("m · effort server default · ctx 25% · in 1.8M (94% cached) · out 18k · last turn: 2 steps", line);
    const busy = text.footer(.{ .cfg = cfg, .context = 400, .steps = 1, .usage = .{ .prompt_tokens = 1200, .completion_tokens = 50, .prompt_cache_hit_tokens = 600 }, .busy = .{ .phase = .running, .ms = 100 } }, 200);
    try std.testing.expectEqualStrings("m · effort server default · ctx 40% · in 1.2k (50% cached) · out 50 · turn: 1 steps", busy);
}
