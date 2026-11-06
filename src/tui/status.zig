const std = @import("std");
const provider = @import("../provider.zig");
const ModelActivity = @import("../session/events.zig").ModelActivity;

pub const Phase = enum { thinking, writing, running, retrying, compacting };

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// What the running Turn is doing and since when.
pub const Activity = struct {
    phase: Phase = .thinking,
    since: std.Io.Clock.Timestamp,
    last_data: ?std.Io.Clock.Timestamp = null,

    pub const Label = struct { phase: Phase, ms: u64, no_data_ms: ?u64 = null };

    pub fn start(io: std.Io, phase: Phase) Activity {
        return .{ .phase = phase, .since = .now(io, .awake) };
    }

    pub fn set(a: *Activity, io: std.Io, phase: Phase) void {
        if (a.phase == phase) return;
        a.phase = phase;
        a.since = .now(io, .awake);
    }

    pub fn modelActivity(a: *Activity, activity: ModelActivity, at: std.Io.Clock.Timestamp) void {
        a.last_data = switch (activity) {
            .started, .data => at,
            .finished => null,
        };
    }

    pub fn label(a: Activity, io: std.Io) Label {
        return a.labelAt(.now(io, .awake));
    }

    fn labelAt(a: Activity, now: std.Io.Clock.Timestamp) Label {
        return .{
            .phase = a.phase,
            .ms = @intCast(@max(a.since.durationTo(now).raw.toMilliseconds(), 0)),
            .no_data_ms = if (a.last_data) |at| @intCast(@max(at.durationTo(now).raw.toMilliseconds(), 0)) else null,
        };
    }
};

pub const Status = struct {
    cfg: provider.Config,
    user_bg: @import("vaxis").Color = .default,
    usage: provider.Usage = .{},
    steps: u32 = 0,
    current_step: u32 = 1,
    background_count: usize = 0,
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
        if (s.busy) |b| {
            w.print("{s} {s} {d}s", .{ spinner[(b.ms / 100) % spinner.len], @tagName(b.phase), b.ms / 1000 }) catch {};
            if (b.no_data_ms) |ms| if (ms >= 30_000) {
                w.print(" · no data {d}s", .{ms / 1000}) catch {};
            };
            w.print(" · step {d} · esc to cancel", .{s.current_step}) catch {};
        }
        if (s.background_count > 0) {
            if (w.end > 0) w.writeAll(" · ") catch {};
            w.print("bg {d}", .{s.background_count}) catch {};
        }
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
        var line = std.fmt.bufPrint(&text.status, "{s} · effort {s}{s} · ctx {d}% · in {s} ({d}% cached) · out {s} · {s}: {d} steps", .{
            s.cfg.model,
            if (s.cfg.thinking != null or s.cfg.reasoning_effort != null) "≤" else "",
            s.cfg.effectiveEffort(),
            s.context * 100 / @max(s.cfg.context_window, 1),
            tokens(&input, s.usage.prompt_tokens),
            s.usage.prompt_cache_hit_tokens * 100 / @max(s.usage.prompt_tokens, 1),
            tokens(&output, s.usage.completion_tokens),
            if (s.busy != null) "turn" else "last turn",
            s.steps,
        }) catch "";
        var bg_buf: [32]u8 = undefined;
        const bg = if (s.background_count > 0) std.fmt.bufPrint(&bg_buf, " · bg {d}", .{s.background_count}) catch "" else "";
        while (std.mem.lastIndexOf(u8, line, " · ")) |separator| {
            if (@import("vaxis").gwidth.gwidth(line, .unicode) + @import("vaxis").gwidth.gwidth(bg, .unicode) <= width) break;
            line = line[0..separator];
        }
        if (bg.len > 0) {
            const fits = @import("vaxis").gwidth.gwidth(line, .unicode) + @import("vaxis").gwidth.gwidth(bg, .unicode) <= width;
            if (!fits) line = "";
            const suffix = std.fmt.bufPrint(text.status[line.len..], "{s}", .{if (fits) bg else bg[3..]}) catch "";
            line = text.status[0 .. line.len + suffix.len];
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

test "background task count remains visible during model work" {
    const t = std.testing;
    var text: Text = .{};
    const s: Status = .{ .cfg = .{ .base_url = "", .api_key = "", .model = "m" }, .busy = .{ .phase = .thinking, .ms = 0 }, .background_count = 2 };
    try t.expectEqualStrings("⠋ thinking 0s · step 1 · esc to cancel · bg 2", text.format(s, false));
    try t.expect(std.mem.endsWith(u8, text.footer(s, 200), " · bg 2"));
    try t.expectEqualStrings("bg 2", text.format(.{ .cfg = s.cfg, .background_count = 2 }, false));
}

test "model silence threshold, data reset, and request boundaries" {
    const t = std.testing;
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "m" };
    var text: Text = .{};
    var activity = Activity.start(t.io, .thinking);
    const start = activity.since;
    const before = start.addDuration(.{ .raw = .fromMilliseconds(29_999), .clock = .awake });
    const threshold = start.addDuration(.{ .raw = .fromMilliseconds(30_000), .clock = .awake });
    const later = start.addDuration(.{ .raw = .fromMilliseconds(45_000), .clock = .awake });
    activity.modelActivity(.started, start);
    try t.expect(std.mem.indexOf(u8, text.format(.{ .cfg = cfg, .busy = activity.labelAt(before) }, false), "no data") == null);
    try t.expect(std.mem.indexOf(u8, text.format(.{ .cfg = cfg, .busy = activity.labelAt(threshold) }, false), " · no data 30s") != null);
    try t.expectEqualStrings("⠋ thinking 45s · no data 45s · step 1 · esc to cancel", text.format(.{ .cfg = cfg, .busy = activity.labelAt(later) }, false));
    activity.modelActivity(.data, later);
    try t.expectEqualStrings("⠋ thinking 45s · step 1 · esc to cancel", text.format(.{ .cfg = cfg, .busy = activity.labelAt(later) }, false));
    activity.set(t.io, .writing);
    try t.expectEqual(@as(?u64, 0), activity.labelAt(later).no_data_ms);
    activity.modelActivity(.finished, later);
    for ([_]Phase{ .running, .retrying, .thinking }) |phase| {
        activity.set(t.io, phase);
        try t.expectEqual(@as(?u64, null), activity.labelAt(later).no_data_ms);
        try t.expect(std.mem.indexOf(u8, text.format(.{ .cfg = cfg, .busy = activity.labelAt(later) }, false), "no data") == null);
    }
    activity.set(t.io, .compacting);
    activity.modelActivity(.started, later);
    try t.expectEqual(@as(?u64, 0), activity.labelAt(later).no_data_ms);
    try t.expectEqual(Phase.compacting, activity.phase);
}

test "effort footer marks configured ceilings but preserves default" {
    const t = std.testing;
    var text: Text = .{};
    for ([_]provider.Id{ .chat_completions, .codex }) |id| {
        var cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "m", .provider = id };
        try t.expect(std.mem.startsWith(u8, text.footer(.{ .cfg = cfg }, 200), "m · effort server default ·"));
        try cfg.setEffort("high");
        try t.expect(std.mem.startsWith(u8, text.footer(.{ .cfg = cfg }, 200), "m · effort ≤high ·"));
        try cfg.setEffort("default");
        try t.expect(std.mem.startsWith(u8, text.footer(.{ .cfg = cfg }, 200), "m · effort server default ·"));
    }
}
