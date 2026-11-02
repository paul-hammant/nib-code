const std = @import("std");
const vaxis = @import("vaxis");
const Session = @import("session.zig").Session;
const SessionEvent = @import("session.zig").Event;
const Sink = @import("session.zig").Sink;
const provider = @import("provider.zig");
const config = @import("config.zig");
const Editor = @import("tui/editor.zig").Editor;
const commands = @import("tui/commands.zig");
const Transcript = @import("tui/transcript.zig").Transcript;
const EntryKind = @import("tui/transcript.zig").Kind;
const ChangeText = @import("tui/transcript.zig").ChangeText;
const Viewport = @import("tui/viewport.zig").Viewport;
const Menu = @import("tui/menu.zig").Menu;
const status = @import("tui/status.zig");
const view = @import("tui/view.zig");
const selection = @import("tui/selection.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    paste_start,
    paste_end,
    mouse: vaxis.Mouse,
    tick,
    /// Slices are owned by the receiver.
    delta: struct { kind: provider.Kind, text: []u8 },
    run_start: []u8,
    run_end: struct { ok: bool, output: []u8, changes: ChangeText },
    retry: []u8,
    notice: []u8,
    done,
    usage: provider.Usage,
    failed: []u8,
};

/// Posts `.tick` while `busy` so the spinner and timer advance without input.
const Ticker = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    busy: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),

    fn work(t: *Ticker) void {
        while (!t.stop.load(.acquire)) {
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(100), .clock = .awake }, t.io) catch return;
            if (t.busy.load(.acquire)) t.loop.postEvent(.tick) catch {};
        }
    }
};

/// A Turn or `/compact` on its own thread. The UI thread must not touch the Session meanwhile.
const Turn = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    text: []const u8,
    loop: *vaxis.Loop(Event),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn spawn(gpa: std.mem.Allocator, session: *Session, loop: *vaxis.Loop(Event), text: []const u8, compact: bool) !*Turn {
        const t = try gpa.create(Turn);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .session = session, .text = text, .loop = loop };
        t.thread = try std.Thread.spawn(.{}, work, .{ t, compact });
        return t;
    }

    fn work(t: *Turn, compact: bool) void {
        var detail: ?[]u8 = null;
        t.execute(compact, &detail) catch |err| {
            const msg = detail orelse (t.gpa.dupe(u8, @errorName(err)) catch return);
            t.loop.postEvent(.{ .failed = msg }) catch t.gpa.free(msg);
            return;
        };
        t.loop.postEvent(.done) catch {};
    }

    fn execute(t: *Turn, compact: bool, detail: *?[]u8) !void {
        const sink: Sink = .{ .ctx = t, .emit = emit };
        if (compact) {
            _ = try t.session.compact(sink, &t.cancel, detail);
        } else try t.session.turn(t.text, sink, &t.cancel, detail);
    }

    fn emit(ctx: *anyopaque, ev: SessionEvent) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        const gpa = t.gpa;
        try t.loop.postEvent(switch (ev) {
            .delta => |d| .{ .delta = .{ .kind = d.kind, .text = try gpa.dupe(u8, d.text) } },
            .run_start => |code| .{ .run_start = try gpa.dupe(u8, code) },
            .run_end => |r| .{ .run_end = .{ .ok = r.ok, .output = try gpa.dupe(u8, r.output), .changes = try .init(gpa, r.changes) } },
            .retry => |r| .{ .retry = try std.fmt.allocPrint(gpa, "retry {d} in {d}s: {s}", .{ r.attempt, r.delay_ms / 1000, r.reason }) },
            .notice => |m| .{ .notice = try gpa.dupe(u8, m) },
            .usage => |u| .{ .usage = u },
        });
    }

    fn finish(t: *Turn) void {
        t.thread.join();
        t.gpa.free(t.text);
        t.gpa.destroy(t);
    }
};

/// `session` may already hold history (a resumed Session); it is shown first.
pub fn run(init: std.process.Init, session: *Session) !void {
    const io = init.io;
    const gpa = init.gpa;

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const w = tty.writer();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, w);

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(w);
    try w.flush();
    try vx.queryTerminal(w, .fromSeconds(1));
    try vx.setBracketedPaste(w, true);
    // Selection needs cell coordinates; some terminals claim SGR pixel mode yet report cells.
    vx.caps.sgr_pixels = false;
    try vx.setMouseMode(w, true);

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .session = session,
        .environ = init.environ_map,
        .cfg = session.cfg,
        .vx = &vx,
        .w = w,
        .loop = &loop,
        .menu = .init(gpa),
        .activity = .start(io, .thinking),
        .context = session.context_tokens,
    };
    defer app.deinit();
    var ticker: Ticker = .{ .io = io, .loop = &loop };
    const ticker_thread = try std.Thread.spawn(.{}, Ticker.work, .{&ticker});
    defer {
        ticker.stop.store(true, .release);
        ticker_thread.join();
    }

    try app.transcript.addHistory(gpa, session.history.items);
    for (session.history.items) |m| {
        if (std.mem.eql(u8, m.role, "user")) try app.input.remember(gpa, m.content orelse "");
    }
    if (app.cfg.missingKey()) try app.transcript.add(gpa, .err, "no API key: set DEEPSEEK_API_KEY (or NIB_API_KEY). /js <code> still works.");

    while (try app.handle(try loop.nextEvent())) {
        ticker.busy.store(app.turn != null, .release);
        try app.render();
    }
}

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session: *Session,
    cfg: provider.Config,
    vx: *vaxis.Vaxis,
    w: *std.Io.Writer,
    loop: *vaxis.Loop(Event),
    environ: *const std.process.Environ.Map,
    selection: selection.Selection = .{},
    /// Shown on the status line until the next key or click; not part of the transcript.
    notice: ?[]const u8 = null,
    notice_buf: [64]u8 = undefined,
    transcript: Transcript = .{},
    input: Editor = .{},
    pasting: bool = false,
    scroll: Viewport = .{},
    menu: Menu,
    status_text: status.Text = .{},
    activity: status.Activity,
    usage: provider.Usage = .{},
    steps: u32 = 0,
    context: u64 = 0,
    turn: ?*Turn = null,

    fn deinit(app: *App) void {
        if (app.turn) |t| {
            t.cancel.store(true, .release);
            t.finish();
        }
        app.menu.deinit();
        app.transcript.deinit(app.gpa);
        app.input.deinit(app.gpa);
    }

    /// False to quit.
    fn handle(app: *App, event: Event) !bool {
        const gpa = app.gpa;
        switch (event) {
            .key_press => |k| return app.onKey(k),
            .paste_start => app.pasting = true,
            .paste_end => app.pasting = false,
            .mouse => |m| {
                if (m.type == .press) app.notice = null;
                if (m.button == .wheel_up or m.button == .wheel_down) {
                    app.selection.clear();
                    app.scroll.pending += if (m.button == .wheel_up) @as(i64, -3) else 3;
                } else if (app.selection.mouse(m, &app.vx.screen)) {
                    const text = try app.selection.text(gpa, &app.vx.screen);
                    defer gpa.free(text);
                    if (std.mem.trim(u8, text, " \n").len == 0) {
                        app.selection.clear();
                    } else {
                        try selection.copy(app.vx, app.w, gpa, app.io, app.environ, text);
                        app.notice = std.fmt.bufPrint(&app.notice_buf, "copied {d} chars", .{std.unicode.utf8CountCodepoints(text) catch text.len}) catch null;
                    }
                }
            },
            .tick => {},
            .winsize => |ws| {
                app.selection.clear();
                try app.vx.resize(gpa, app.w, ws);
            },
            .delta => |d| {
                defer gpa.free(d.text);
                if (app.activity.phase != .compacting) app.activity.set(app.io, if (d.kind == .reasoning) .thinking else .writing);
                try app.transcript.appendDelta(gpa, d.kind, d.text);
            },
            .run_start => |code| {
                defer gpa.free(code);
                app.activity.set(app.io, .running);
                try app.transcript.startRun(gpa, code);
            },
            .run_end => |r| {
                defer gpa.free(r.output);
                const elapsed = app.activity.label(app.io).ms;
                app.activity.set(app.io, .thinking);
                try app.transcript.endRun(gpa, r.ok, r.output, elapsed, r.changes);
            },
            .retry, .notice => |msg| {
                defer gpa.free(msg);
                if (std.mem.startsWith(u8, msg, "retry")) app.activity.set(app.io, .retrying);
                try app.transcript.add(gpa, .info, msg);
            },
            .usage => |u| app.usage = u,
            .done => app.finishTurn(),
            .failed => |msg| {
                defer gpa.free(msg);
                const canceled = app.turn.?.cancel.load(.acquire);
                try app.transcript.add(gpa, if (canceled) .info else .err, if (canceled) "canceled" else msg);
                app.finishTurn();
            },
        }
        return true;
    }

    fn onKey(app: *App, k: vaxis.Key) !bool {
        app.notice = null;
        const gpa = app.gpa;
        const input = &app.input;
        const page = @max(app.vx.window().height / 2, 1);
        if (k.matches('c', .{ .ctrl = true })) return false;
        if (k.matches('d', .{ .ctrl = true }) and input.text().len == 0) return false;
        const selected = app.menu.selected(input.text());
        const before = std.hash.Wyhash.hash(0, input.text());
        var submitted: ?[]u8 = null;

        if (selected != null and k.matches(vaxis.Key.escape, .{})) {
            app.menu.closed = true;
        } else if (selected != null and k.matches(vaxis.Key.up, .{})) {
            app.menu.move(input.text(), false);
        } else if (selected != null and k.matches(vaxis.Key.down, .{})) {
            app.menu.move(input.text(), true);
        } else if (selected != null and (k.matches(vaxis.Key.tab, .{}) or (k.matches(vaxis.Key.enter, .{}) and !app.pasting and !selected.?.runs()))) {
            const completion = try selected.?.completion(gpa);
            defer gpa.free(completion);
            try input.replace(gpa, completion);
        } else if (selected != null and k.matches(vaxis.Key.enter, .{}) and !app.pasting) {
            const line = try selected.?.line(gpa);
            defer gpa.free(line);
            try input.replace(gpa, line);
            if (app.turn == null or commands.allowedWhileBusy(line)) submitted = try input.take(gpa);
        } else if (k.matches(vaxis.Key.escape, .{})) {
            if (app.turn) |t| t.cancel.store(true, .release);
        } else if (k.matches(vaxis.Key.page_up, .{})) {
            app.scroll.pending -= page;
        } else if (k.matches(vaxis.Key.page_down, .{})) {
            app.scroll.pending += page;
        } else if (k.matches('o', .{ .ctrl = true })) {
            app.transcript.toggleExpanded();
        } else if (k.matches(vaxis.Key.up, .{ .shift = true })) {
            app.scroll.pending -= 3;
        } else if (k.matches(vaxis.Key.down, .{ .shift = true })) {
            app.scroll.pending += 3;
        } else if (isNewline(k, app.pasting)) {
            try input.insert(gpa, "\n");
        } else if (k.matches(vaxis.Key.enter, .{})) {
            if (app.turn == null or commands.allowedWhileBusy(input.text())) submitted = try input.take(gpa);
        } else {
            _ = try input.key(gpa, k);
        }
        if (std.hash.Wyhash.hash(0, input.text()) != before) app.menu.inputChanged(input.text());
        if (submitted) |line| try app.submit(line);
        return true;
    }

    /// Takes ownership of `line`.
    fn submit(app: *App, line: []u8) !void {
        const gpa = app.gpa;
        app.scroll = .{};
        app.menu.forgetSessions();
        if (line.len == 0) return gpa.free(line);
        if (commands.parse(line)) |parsed| {
            defer gpa.free(line);
            return switch (parsed) {
                .unknown => |name| app.report(.err, "unknown command /{s} · /help lists commands", .{name}),
                .known => |c| app.command(c.command, c.arg, line),
            };
        }
        if (app.cfg.missingKey()) {
            gpa.free(line);
            return app.transcript.add(gpa, .err, "no API key");
        }
        try app.transcript.add(gpa, .user, line);
        app.turn = try Turn.spawn(gpa, app.session, app.loop, line, false);
        app.activity = .start(app.io, .thinking);
    }

    fn command(app: *App, c: commands.Command, arg: []const u8, line: []const u8) !void {
        const gpa = app.gpa;
        const session = app.session;
        switch (c) {
            .help => {
                const text = try commands.helpText(gpa);
                defer gpa.free(text);
                try app.transcript.add(gpa, .info, text);
            },
            .new, .@"resume" => {
                const id = if (c == .new) null else app.menu.resolveSession(app.io, session, arg) catch |err| {
                    return app.transcript.add(gpa, .err, switch (err) {
                        error.MissingSessionId => "usage: /resume <id> · type /resume and a space to pick one",
                        error.UnknownSession => "no session here starts with that id",
                        error.AmbiguousSession => "several sessions start with that id; type more of it",
                        else => @errorName(err),
                    });
                };
                if (id != null and std.mem.eql(u8, id.?, session.id)) return app.transcript.add(gpa, .info, "already in this session");
                session.reopen(id) catch |err| return app.report(.err, "could not open session: {s}", .{@errorName(err)});
                app.transcript.clear(gpa);
                try app.transcript.addHistory(gpa, session.history.items);
                app.usage = .{};
                app.steps = 0;
                app.context = session.context_tokens;
                try app.report(.info, "{s} session {s}", .{ if (c == .new) "new" else "resumed", session.id[0..8] });
            },
            .copy => {
                const answer = app.transcript.lastAnswer() orelse return app.transcript.add(gpa, .err, "no answer to copy yet");
                try app.vx.copyToSystemClipboard(app.w, answer, gpa);
                try app.report(.info, "copied {d} bytes (needs a terminal with OSC 52 clipboard support)", .{answer.len});
            },
            .effort => {
                if (arg.len > 0) {
                    app.cfg.setEffort(arg) catch return app.transcript.add(gpa, .err, "usage: /effort [default|off|none|minimal|low|medium|high|xhigh|max]");
                    session.cfg = app.cfg;
                    session.tools.cfg = app.cfg;
                    config.saveEffort(gpa, app.io, session.options.home, arg) catch |err| {
                        try app.report(.err, "effort applied, but could not save {s}/config.toml: {s}", .{ session.options.home, @errorName(err) });
                        return;
                    };
                    try app.report(.info, "effort: {s} · saved to {s}/config.toml (environment and --effort override saved preferences)", .{ app.cfg.effectiveEffort(), session.options.home });
                    return;
                }
                try app.report(.info, "effort: {s} · thinking: {s} · configured: {s} (model support varies)", .{
                    app.cfg.effectiveEffort(),
                    if (app.cfg.thinking) |on| (if (on) "on" else "off") else "default",
                    app.cfg.reasoning_effort orelse "default",
                });
            },
            .js => {
                if (arg.len == 0) return app.transcript.add(gpa, .err, "usage: /js <code>");
                try app.transcript.add(gpa, .user, line);
                const ran = try session.run(arg, null);
                const r = ran.outcome;
                app.usage = session.usage;
                defer r.deinit(gpa);
                if (r.logs.len > 0) try app.transcript.add(gpa, .info, std.mem.trimEnd(u8, r.logs, "\n"));
                try app.transcript.add(gpa, if (r.ok) .info else .err, r.text);
                var changes: ChangeText = try .init(gpa, ran.changes);
                defer changes.deinit(gpa);
                if (changes.diff.len > 0) try app.transcript.add(gpa, .info, std.mem.trimEnd(u8, changes.diff, "\n"));
            },
            .compact => {
                app.turn = try Turn.spawn(gpa, session, app.loop, try gpa.dupe(u8, line), true);
                app.activity = .start(app.io, .compacting);
            },
        }
    }

    fn report(app: *App, kind: EntryKind, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(app.gpa, fmt, args);
        defer app.gpa.free(message);
        try app.transcript.add(app.gpa, kind, message);
    }

    fn finishTurn(app: *App) void {
        app.turn.?.finish();
        app.turn = null;
        app.usage = app.session.usage;
        app.steps = app.session.steps;
        app.context = app.session.context_tokens;
    }

    fn render(app: *App) !void {
        try app.menu.load(app.io, app.input.text(), app.session);
        const menu = app.menu.items(app.input.text());
        if (app.scroll.pending != 0) app.selection.clear();
        view.draw(app.vx.window(), app.transcript.entries.items, &app.input, &app.scroll, menu, @min(app.menu.sel, menu.len -| 1), .{
            .cfg = app.cfg,
            .usage = app.usage,
            .steps = app.steps,
            .context = app.context,
            .busy = if (app.turn != null) app.activity.label(app.io) else null,
            .notice = app.notice,
        }, &app.status_text);
        app.selection.highlight(&app.vx.screen);
        try app.vx.render(app.w);
        try app.w.flush();
    }
};

fn isNewline(key: vaxis.Key, pasting: bool) bool {
    const enter = vaxis.Key.enter;
    return (pasting and key.matches(enter, .{})) or key.matches(enter, .{ .shift = true }) or
        key.matches(enter, .{ .alt = true }) or key.matches('j', .{ .ctrl = true });
}
