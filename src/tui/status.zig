const std = @import("std");
const ui_format = @import("format.zig");
const provider = @import("../provider.zig");
const ModelActivity = @import("../session/events.zig").ModelActivity;

pub const Phase = enum { thinking, writing, scripting, running, waiting, retrying, compacting };

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub const Activity = struct {
    phase: Phase = .thinking,
    since: std.Io.Clock.Timestamp,
    turn_since: std.Io.Clock.Timestamp,
    last_progress: std.Io.Clock.Timestamp,
    tool: []const u8 = "",

    pub const Label = struct { phase: Phase, ms: u64, turn_ms: u64 = 0, quiet_ms: u64 = 0 };

    pub fn start(io: std.Io, phase: Phase) Activity {
        const now: std.Io.Clock.Timestamp = .now(io, .awake);
        return .{ .phase = phase, .since = now, .turn_since = now, .last_progress = now };
    }

    pub fn set(a: *Activity, io: std.Io, phase: Phase) void {
        if (a.phase == phase) return;
        a.phase = phase;
        a.since = .now(io, .awake);
    }

    pub fn modelActivity(a: *Activity, activity: ModelActivity, at: std.Io.Clock.Timestamp) void {
        switch (activity) {
            .data, .script => a.progress(at),
            .started, .finished, .waiting => {},
        }
    }

    pub fn progress(a: *Activity, at: std.Io.Clock.Timestamp) void {
        a.last_progress = at;
    }

    pub fn label(a: Activity, io: std.Io) Label {
        return a.labelAt(.now(io, .awake));
    }

    fn labelAt(a: Activity, now: std.Io.Clock.Timestamp) Label {
        return .{
            .phase = a.phase,
            .ms = @intCast(@max(a.since.durationTo(now).raw.toMilliseconds(), 0)),
            .turn_ms = @intCast(@max(a.turn_since.durationTo(now).raw.toMilliseconds(), 0)),
            .quiet_ms = @intCast(@max(a.last_progress.durationTo(now).raw.toMilliseconds(), 0)),
        };
    }
};

pub const Status = struct {
    cfg: provider.Config,
    usage: provider.Usage = .{},
    steps: u32 = 0,
    current_step: u32 = 1,
    background_count: usize = 0,
    context: u64 = 0,
    /// Set while a Turn runs.
    busy: ?Activity.Label = null,
    /// A transient message, such as a copy confirmation.
    notice: ?[]const u8 = null,
    detail: []const u8 = "",
};

/// Printed slices must survive until vaxis renders the frame.
pub const Text = struct {
    status: [512]u8 = undefined,
    activity: [512]u8 = undefined,

    pub fn format(text: *Text, s: Status, scrolled: bool) []const u8 {
        var w: std.Io.Writer = .fixed(&text.activity);
        if (s.busy) |b| {
            const phase = switch (b.phase) {
                .thinking => "waiting model",
                .writing => "model output",
                .scripting => "generating run",
                .running => "tools",
                .waiting => "waiting tasks",
                .retrying => "retrying",
                .compacting => "compacting",
            };
            w.print("{s} {s}", .{ spinner[(b.ms / 100) % spinner.len], phase }) catch {};
            if (s.detail.len > 0) w.print(" {s}", .{s.detail}) catch {};
            var elapsed: [64]u8 = undefined;
            w.print(" · turn {s}", .{ui_format.duration(&elapsed, b.turn_ms)}) catch {};
            if (b.quiet_ms >= 30_000) w.print(" · no progress {s}", .{ui_format.duration(&elapsed, b.quiet_ms)}) catch {};
            w.print(" · step {d} · Esc to cancel", .{s.current_step}) catch {};
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

    pub fn formatWidth(text: *Text, s: Status, scrolled: bool, width: u16) []const u8 {
        var line = text.format(s, scrolled);
        const vaxis = @import("vaxis");
        while (vaxis.gwidth.gwidth(line, .unicode) > width) {
            if (std.mem.lastIndexOf(u8, line, " · ")) |separator| {
                line = line[0..separator];
            } else {
                var end: usize = 0;
                var it = vaxis.unicode.graphemeIterator(line);
                while (it.next()) |grapheme| {
                    const next = end + grapheme.bytes(line).len;
                    if (vaxis.gwidth.gwidth(line[0..next], .unicode) > width) break;
                    end = next;
                }
                return line[0..end];
            }
        }
        return line;
    }

    pub fn footer(text: *Text, s: Status, width: u16) []const u8 {
        var input: [32]u8 = undefined;
        var output: [32]u8 = undefined;
        var line = std.fmt.bufPrint(&text.status, "{s} · effort {s}{s} · ctx {d}% · in {s} ({d}% cached) · out {s} · {s}: {d} step{s}", .{
            s.cfg.model,
            if (s.cfg.thinking != null or s.cfg.reasoning_effort != null) "≤" else "",
            s.cfg.effectiveEffort(),
            s.context * 100 / @max(s.cfg.context_window, 1),
            tokens(&input, s.usage.prompt_tokens),
            s.usage.prompt_cache_hit_tokens * 100 / @max(s.usage.prompt_tokens, 1),
            tokens(&output, s.usage.completion_tokens),
            if (s.busy != null) "turn" else "last turn",
            s.steps,
            if (s.steps == 1) "" else "s",
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

const tokens = ui_format.number;

test "activity is optional and footer shows latest reported usage" {
    var text: Text = .{};
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "m", .context_window = 1000 };
    try std.testing.expectEqualStrings("", text.format(.{ .cfg = cfg }, false));
    try std.testing.expectEqualStrings("↑ history · PgDn to return", text.format(.{ .cfg = cfg }, true));
    try std.testing.expectEqualStrings("⠙ tools · turn <1s · step 2 · Esc to cancel · copied 3 chars", text.format(.{ .cfg = cfg, .current_step = 2, .busy = .{ .phase = .running, .ms = 150 }, .notice = "copied 3 chars" }, false));
    const line = text.footer(.{ .cfg = cfg, .context = 250, .steps = 2, .usage = .{ .prompt_tokens = 1_800_000, .prompt_cache_hit_tokens = 1_692_000, .completion_tokens = 18_000 } }, 200);
    try std.testing.expectEqualStrings("m · effort server default · ctx 25% · in 1.8M (94% cached) · out 18k · last turn: 2 steps", line);
    const busy = text.footer(.{ .cfg = cfg, .context = 400, .steps = 1, .usage = .{ .prompt_tokens = 1200, .completion_tokens = 50, .prompt_cache_hit_tokens = 600 }, .busy = .{ .phase = .running, .ms = 100 } }, 200);
    try std.testing.expectEqualStrings("m · effort server default · ctx 40% · in 1.2k (50% cached) · out 50 · turn: 1 step", busy);
}

test "background task count remains visible during model work" {
    const t = std.testing;
    var text: Text = .{};
    const s: Status = .{ .cfg = .{ .base_url = "", .api_key = "", .model = "m" }, .busy = .{ .phase = .thinking, .ms = 0 }, .background_count = 2 };
    try t.expectEqualStrings("⠋ waiting model · turn <1s · step 1 · Esc to cancel · bg 2", text.format(s, false));
    try t.expect(std.mem.endsWith(u8, text.footer(s, 200), " · bg 2"));
    try t.expectEqualStrings("bg 2", text.format(.{ .cfg = s.cfg, .background_count = 2 }, false));
}

test "only content advances progress; stage changes preserve Turn duration" {
    const t = std.testing;
    var activity = Activity.start(t.io, .thinking);
    const start = activity.since;
    const later = start.addDuration(.{ .raw = .fromMilliseconds(45000), .clock = .awake });
    activity.modelActivity(.started, later);
    activity.modelActivity(.finished, later);
    try t.expectEqual(@as(u64, 45000), activity.labelAt(later).quiet_ms);
    activity.modelActivity(.script, later);
    try t.expectEqual(@as(u64, 0), activity.labelAt(later).quiet_ms);
    activity.set(t.io, .running);
    try t.expectEqual(@as(u64, 45000), activity.labelAt(later).turn_ms);
    activity.modelActivity(.waiting, later);
    try t.expectEqualDeep(later, activity.last_progress);
    var text: Text = .{};
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "m" };
    const s: Status = .{ .cfg = cfg, .detail = "r3 32s", .busy = .{ .phase = .waiting, .ms = 0, .turn_ms = 574000, .quiet_ms = 30000 } };
    try t.expectEqualStrings("⠋ waiting tasks r3 32s · turn 9m34s · no progress 30s · step 1 · Esc to cancel", text.format(s, false));
    for (0..100) |width| {
        const line = text.formatWidth(s, false, @intCast(width));
        try t.expect(@import("vaxis").gwidth.gwidth(line, .unicode) <= width);
        try t.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    }
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
