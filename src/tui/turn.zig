const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const Event = tui.Event;
const Session = @import("../session.zig").Session;
const SessionEvent = @import("../session.zig").Event;
const ModelActivity = @import("../session.zig").ModelActivity;
const Sink = @import("../session.zig").Sink;
const ChangeText = @import("transcript.zig").ChangeText;

/// Posts `.tick` while `busy` so the spinner and timer advance without input.
pub const Ticker = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    busy: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),

    pub fn work(t: *Ticker) void {
        while (!t.stop.load(.acquire)) {
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(100), .clock = .awake }, t.io) catch return;
            if (t.busy.load(.acquire)) t.loop.postEvent(.tick) catch {};
        }
    }
};

/// A Turn or `/compact` on its own thread. Only Session.enqueue is shared with the UI.
pub const Turn = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    text: []const u8,
    loop: *vaxis.Loop(Event),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    last_model_activity: ?std.Io.Clock.Timestamp = null,

    pub fn spawn(gpa: std.mem.Allocator, session: *Session, loop: *vaxis.Loop(Event), text: []const u8, compact: bool) !*Turn {
        const t = try gpa.create(Turn);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .session = session, .text = text, .loop = loop };
        t.thread = try std.Thread.spawn(.{}, work, .{ t, compact });
        return t;
    }

    pub fn work(t: *Turn, compact: bool) void {
        var detail: ?[]u8 = null;
        t.execute(compact, &detail) catch |err| {
            const msg = detail orelse (t.gpa.dupe(u8, @errorName(err)) catch return);
            t.loop.postEvent(.{ .failed = msg }) catch t.gpa.free(msg);
            return;
        };
        t.loop.postEvent(.done) catch {};
    }

    fn execute(t: *Turn, compact: bool, detail: *?[]u8) !void {
        const sink: Sink = .{ .ctx = t, .emit = emit, .onModelActivity = modelActivity, .onUserInserted = userInserted };
        if (compact) {
            errdefer t.session.tools.background.stop(t.gpa);
            _ = try t.session.compact(sink, &t.cancel, detail);
        } else try t.session.turn(t.text, sink, &t.cancel, detail);
    }

    pub fn userInserted(ctx: *anyopaque, id: u64) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        try t.loop.postEvent(.{ .user_inserted = id });
    }

    pub fn modelActivity(ctx: *anyopaque, state: ModelActivity) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        try t.modelActivityAt(state, .now(t.session.io, .awake));
    }

    pub fn modelActivityAt(t: *Turn, state: ModelActivity, at: std.Io.Clock.Timestamp) !void {
        if (state == .data) if (t.last_model_activity) |last| {
            if (last.durationTo(at).raw.toMilliseconds() < 1000) return;
        };
        try t.loop.postEvent(.{ .model_activity = .{ .state = state, .at = at } });
        t.last_model_activity = if (state == .finished) null else at;
    }

    pub fn emit(ctx: *anyopaque, ev: SessionEvent) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        const gpa = t.gpa;
        const event: Event = switch (ev) {
            .step => |s| .{ .step = .{ .n = s.n, .effort = try gpa.dupe(u8, s.effort), .source = s.source } },
            .delta => |d| .{ .delta = .{ .kind = d.kind, .text = try gpa.dupe(u8, d.text), .step = t.session.steps + 1 } },
            .run_start => |code| .{ .run_start = .{ .code = try gpa.dupe(u8, code), .step = t.session.steps } },
            .run_end => |r| blk: {
                const output = try gpa.dupe(u8, r.output);
                errdefer gpa.free(output);
                var changes = try ChangeText.init(gpa, r.changes);
                errdefer changes.deinit(gpa);
                break :blk .{ .run_end = .{ .ok = r.ok, .output = output, .changes = changes, .tool_summary = if (r.tool_summary) |summary| try summary.clone(gpa) else null } };
            },
            .retry => |r| .{ .retry = try std.fmt.allocPrint(gpa, "retry {d} in {d}s: {s}", .{ r.attempt, r.delay_ms / 1000, r.reason }) },
            .notice => |m| .{ .notice = try gpa.dupe(u8, m) },
            .usage => |u| .{ .usage = .{ .tokens = u, .context = t.session.context_tokens, .steps = t.session.steps } },
            .progress => |p| .{ .progress = try p.clone(gpa) },
            .background => |b| blk: {
                const id = try gpa.dupe(u8, b.id);
                errdefer gpa.free(id);
                break :blk .{ .background = .{ .id = id, .kind = b.kind, .state = b.state, .ok = b.ok, .result = if (b.result) |result| try gpa.dupe(u8, result) else null } };
            },
            .turn_end => |summary| .{ .turn_end = summary },
        };
        errdefer switch (event) {
            .run_end => |r| {
                gpa.free(r.output);
                var changes = r.changes;
                changes.deinit(gpa);
                if (r.tool_summary) |summary| summary.deinit(gpa);
            },
            .step => |s| gpa.free(s.effort),
            .background => |b| {
                gpa.free(b.id);
                if (b.result) |result| gpa.free(result);
            },
            .progress => |p| {
                var owned = p;
                owned.deinit(gpa);
            },
            else => {},
        };
        try t.loop.postEvent(event);
    }

    pub fn finish(t: *Turn) void {
        t.thread.join();
        t.gpa.free(t.text);
        t.gpa.destroy(t);
    }
};
