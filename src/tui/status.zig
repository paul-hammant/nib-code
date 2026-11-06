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
                .thinking => "Waiting for model",
                .writing => "Generating response",
                .scripting => "Writing Run",
                .running => if (s.detail.len > 0) "Running" else "Running Run",
                .waiting => if (s.detail.len > 0) "Waiting for" else "Waiting for background tasks",
                .retrying => "Retrying",
                .compacting => "Compacting context",
            };
            w.print("{s} {s}", .{ spinner[(b.ms / 100) % spinner.len], phase }) catch {};
            if (s.detail.len > 0) w.print("{s}{s}", .{ if (b.phase == .retrying) " · " else " ", s.detail }) catch {};
            var elapsed: [64]u8 = undefined;
            w.print(" · turn {s}", .{ui_format.duration(&elapsed, b.turn_ms)}) catch {};
            if (b.quiet_ms >= 30_000) w.print(" · no progress {s}", .{ui_format.duration(&elapsed, b.quiet_ms)}) catch {};
            w.print(" · step {d} · Esc to cancel", .{s.current_step}) catch {};
        }
        if (s.background_count > 0) {
            if (w.end > 0) w.writeAll(" · ") catch {};
            w.print("{d} background task{s}", .{ s.background_count, if (s.background_count == 1) "" else "s" }) catch {};
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
        var line = if (s.context > 0) std.fmt.bufPrint(&text.status, "{s} · context {d}%", .{ s.cfg.model, s.context * 100 / @max(s.cfg.context_window, 1) }) catch "" else s.cfg.model;
        while (@import("vaxis").gwidth.gwidth(line, .unicode) > width) {
            const separator = std.mem.lastIndexOf(u8, line, " · ") orelse return "";
            line = line[0..separator];
        }
        return line;
    }
};

pub fn retryReason(reason: []const u8) []const u8 {
    if (std.mem.indexOf(u8, reason, "rate_limit") != null or std.mem.indexOf(u8, reason, "429") != null) return "rate limit";
    if (std.mem.indexOf(u8, reason, "server_error") != null or std.mem.indexOf(u8, reason, "500") != null) return "provider error";
    if (std.mem.indexOf(u8, reason, "Timeout") != null or std.mem.indexOf(u8, reason, "timed out") != null) return "connection timed out";
    if (std.mem.indexOf(u8, reason, "IncompleteResponse") != null) return "response interrupted";
    const line = reason[0 .. std.mem.indexOfAny(u8, reason, "\r\n") orelse reason.len];
    return @import("transcript/label.zig").promptPrefix(line);
}

test "activity is optional and footer shows latest reported usage" {
    var text: Text = .{};
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "m", .context_window = 1000 };
    try std.testing.expectEqualStrings("", text.format(.{ .cfg = cfg }, false));
    try std.testing.expectEqualStrings("↑ history · PgDn to return", text.format(.{ .cfg = cfg }, true));
    try std.testing.expectEqualStrings("⠙ Running Run · turn <1s · step 2 · Esc to cancel · copied 3 chars", text.format(.{ .cfg = cfg, .current_step = 2, .busy = .{ .phase = .running, .ms = 150 }, .notice = "copied 3 chars" }, false));
    const line = text.footer(.{ .cfg = cfg, .context = 250, .steps = 2, .usage = .{ .prompt_tokens = 1_800_000, .prompt_cache_hit_tokens = 1_692_000, .completion_tokens = 18_000 } }, 200);
    try std.testing.expectEqualStrings("m · context 25%", line);
    const busy = text.footer(.{ .cfg = cfg, .context = 400, .steps = 1, .usage = .{ .prompt_tokens = 1200, .completion_tokens = 50, .prompt_cache_hit_tokens = 600 }, .busy = .{ .phase = .running, .ms = 100 } }, 200);
    try std.testing.expectEqualStrings("m · context 40%", busy);
}

test "background task count remains visible during model work" {
    const t = std.testing;
    var text: Text = .{};
    const s: Status = .{ .cfg = .{ .base_url = "", .api_key = "", .model = "m" }, .busy = .{ .phase = .thinking, .ms = 0 }, .background_count = 2 };
    try t.expectEqualStrings("⠋ Waiting for model · turn <1s · step 1 · Esc to cancel · 2 background tasks", text.format(s, false));
    try t.expectEqualStrings("m", text.footer(s, 200));
    try t.expectEqualStrings("2 background tasks", text.format(.{ .cfg = s.cfg, .background_count = 2 }, false));
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
    const s: Status = .{ .cfg = cfg, .detail = "r3 · 32s", .busy = .{ .phase = .waiting, .ms = 0, .turn_ms = 574000, .quiet_ms = 30000 } };
    try t.expectEqualStrings("⠋ Waiting for r3 · 32s · turn 9m34s · no progress 30s · step 1 · Esc to cancel", text.format(s, false));
    for (0..100) |width| {
        const line = text.formatWidth(s, false, @intCast(width));
        try t.expect(@import("vaxis").gwidth.gwidth(line, .unicode) <= width);
        try t.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    }
}

test "footer is quiet initially and contains only model and context" {
    var text: Text = .{};
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "m", .context_window = 1000 };
    try std.testing.expectEqualStrings("m", text.footer(.{ .cfg = cfg }, 200));
    try std.testing.expectEqualStrings("m · context 25%", text.footer(.{ .cfg = cfg, .context = 250 }, 200));
    try std.testing.expectEqualStrings("m", text.footer(.{ .cfg = cfg, .context = 250 }, 10));
}

test "retry line names the next attempt and a concise cause" {
    var text: Text = .{};
    const s: Status = .{ .cfg = .{ .base_url = "", .api_key = "", .model = "m" }, .detail = "attempt 2/5 · rate limit", .busy = .{ .phase = .retrying, .ms = 0, .turn_ms = 100_000 } };
    try std.testing.expectEqualStrings("⠋ Retrying · attempt 2/5 · rate limit · turn 1m40s · step 1 · Esc to cancel", text.format(s, false));
    try std.testing.expectEqualStrings("rate limit", retryReason("Codex stream failed: rate_limit_exceeded: mock error"));
}
