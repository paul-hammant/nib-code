const std = @import("std");
const vaxis = @import("vaxis");
const Session = @import("session.zig").Session;
const SessionEvent = @import("session.zig").Event;
const ModelActivity = @import("session.zig").ModelActivity;
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
const reflect = @import("tui/reflect.zig");
const bill = @import("tui/bill.zig");
const TurnSummary = @import("session/events.zig").TurnSummary;
const ToolSummary = @import("session/tool_summary.zig").Summary;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    paste_start,
    paste_end,
    mouse: vaxis.Mouse,
    tick,
    model_activity: struct { state: ModelActivity, at: std.Io.Clock.Timestamp },
    /// Slices are owned by the receiver.
    step: struct { n: u32, effort: []u8, source: provider.EffortSource },
    delta: struct { kind: provider.Kind, text: []u8, step: u32 },
    run_start: struct { code: []u8, step: u32 },
    run_end: struct { ok: bool, output: []u8, changes: ChangeText, tool_summary: ?ToolSummary = null },
    retry: []u8,
    notice: []u8,
    user_inserted: u64,
    done,
    turn_end: TurnSummary,
    usage: struct { tokens: provider.Usage, context: u64, steps: u32 },
    progress: @import("session/events.zig").Progress,
    background: @FieldType(SessionEvent, "background"),
    failed: []u8,
    /// One outcome line from automatic issue filing, owned by the receiver.
    issue: []u8,
    issues_done,
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

/// A Turn or `/compact` on its own thread. Only Session.enqueue is shared with the UI.
const Turn = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    text: []const u8,
    loop: *vaxis.Loop(Event),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    last_model_activity: ?std.Io.Clock.Timestamp = null,

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
        const sink: Sink = .{ .ctx = t, .emit = emit, .onModelActivity = modelActivity, .onUserInserted = userInserted };
        if (compact) {
            _ = try t.session.compact(sink, &t.cancel, detail);
        } else try t.session.turn(t.text, sink, &t.cancel, detail);
    }

    fn userInserted(ctx: *anyopaque, id: u64) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        try t.loop.postEvent(.{ .user_inserted = id });
    }

    fn modelActivity(ctx: *anyopaque, state: ModelActivity) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        try t.modelActivityAt(state, .now(t.session.io, .awake));
    }

    fn modelActivityAt(t: *Turn, state: ModelActivity, at: std.Io.Clock.Timestamp) !void {
        if (state == .data) if (t.last_model_activity) |last| {
            if (last.durationTo(at).raw.toMilliseconds() < 1000) return;
        };
        try t.loop.postEvent(.{ .model_activity = .{ .state = state, .at = at } });
        t.last_model_activity = if (state == .finished) null else at;
    }

    fn emit(ctx: *anyopaque, ev: SessionEvent) !void {
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

    fn finish(t: *Turn) void {
        t.thread.join();
        t.gpa.free(t.text);
        t.gpa.destroy(t);
    }
};

/// Background filing of one reflection's issue drafts; owns copies of everything it needs.
const Issues = struct {
    const default_repo = "yyydddkkk/nib-code";

    gpa: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(Event),
    environ: *const std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    drafts: []const reflect.Draft = &.{},
    repo: []const u8 = "",
    reflections_path: []const u8 = "",
    session: []const u8 = "",
    home: []const u8 = "",
    cwd: []const u8 = "",
    footer: []const u8 = "",
    thread: ?std.Thread = null,

    fn work(job: *Issues) void {
        for (job.drafts) |draft| job.report(draft) catch {};
        job.loop.postEvent(.issues_done) catch {};
    }

    fn report(job: *Issues, draft: reflect.Draft) !void {
        const gpa = job.gpa;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const outcome = if (try reflect.sanitize(scratch.allocator(), draft, job.home, job.cwd)) |clean|
            reflect.fileIssue(job.io, gpa, job.environ, "gh", job.repo, clean, job.footer) catch |err| try std.fmt.allocPrint(gpa, "could not file the issue: {s}", .{@errorName(err)})
        else
            try gpa.dupe(u8, "not filed: the draft looks like it contains a credential");
        defer gpa.free(outcome);
        const line = try std.fmt.allocPrint(gpa, "issue · {s} · {s}", .{ draft.title, outcome });
        const record = try std.fmt.allocPrint(scratch.allocator(), "- session {s} · {s}\n", .{ job.session, line });
        reflect.appendText(job.io, job.reflections_path, record) catch {};
        job.loop.postEvent(.{ .issue = line }) catch gpa.free(line);
    }

    /// Joins the filing thread; gh runs to completion first.
    fn finish(job: *Issues) void {
        if (job.thread) |t| t.join();
        job.arena.deinit();
        job.gpa.destroy(job);
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
    notice_buf: [256]u8 = undefined,
    /// Set while a /reflect Turn runs: its focus, owned.
    reflecting: ?[]u8 = null,
    issues: ?*Issues = null,
    transcript: Transcript = .{},
    input: Editor = .{},
    pasting: bool = false,
    paste_buf: std.ArrayList(u8) = .empty,
    live_steps: u32 = 0,
    background_count: usize = 0,
    step_effort: ?provider.StepEffort = null,
    scroll: Viewport = .{},
    menu: Menu,
    status_text: status.Text = .{},
    activity: status.Activity,
    usage: provider.Usage = .{},
    steps: u32 = 0,
    context: u64 = 0,
    turn: ?*Turn = null,
    // turn_end precedes done/failed; append only after their terminal content.
    pending_bill: ?TurnSummary = null,

    fn deinit(app: *App) void {
        if (app.turn) |t| {
            t.cancel.store(true, .release);
            t.finish();
        }
        app.stopReflecting();
        app.clearStepEffort();
        if (app.issues) |job| job.finish();
        app.menu.deinit();
        app.transcript.deinit(app.gpa);
        app.input.deinit(app.gpa);
        app.paste_buf.deinit(app.gpa);
    }

    /// False to quit.
    fn handle(app: *App, event: Event) !bool {
        const gpa = app.gpa;
        switch (event) {
            .key_press => |k| return app.onKey(k),
            .paste_start => {
                app.pasting = true;
                app.paste_buf.clearRetainingCapacity();
            },
            .paste_end => {
                app.pasting = false;
                try app.input.paste(gpa, app.paste_buf.items);
                app.menu.inputChanged(app.input.text());
                app.paste_buf.clearRetainingCapacity();
            },
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
            .model_activity => |activity| {
                if (activity.state == .started and app.activity.phase != .compacting) app.activity.set(app.io, .thinking);
                app.activity.modelActivity(activity.state, activity.at);
            },
            .winsize => |ws| {
                app.selection.clear();
                try app.vx.resize(gpa, app.w, ws);
            },
            .step => |s| {
                app.clearStepEffort();
                app.step_effort = .{ .effort = s.effort, .source = s.source };
                app.live_steps = s.n;
            },
            .delta => |d| {
                defer gpa.free(d.text);
                app.live_steps = d.step;
                if (app.activity.phase != .compacting) app.activity.set(app.io, if (d.kind == .reasoning) .thinking else .writing);
                try app.transcript.appendDelta(gpa, d.kind, d.text);
            },
            .run_start => |r| {
                defer gpa.free(r.code);
                app.live_steps = r.step;
                app.activity.set(app.io, .running);
                try app.transcript.startRunWithEffort(gpa, r.code, app.step_effort);
            },
            .run_end => |r| {
                defer gpa.free(r.output);
                defer if (r.tool_summary) |summary| summary.deinit(gpa);
                const elapsed = app.activity.label(app.io).ms;
                app.activity.set(app.io, .thinking);
                try app.transcript.endRunWithSummary(gpa, r.ok, r.output, elapsed, r.changes, r.tool_summary);
            },
            .retry, .notice => |msg| {
                defer gpa.free(msg);
                if (std.mem.startsWith(u8, msg, "retry")) app.activity.set(app.io, .retrying);
                try app.transcript.add(gpa, .info, msg);
            },
            .usage => |u| {
                app.usage = u.tokens;
                app.context = u.context;
                app.steps = u.steps;
            },
            .progress => |p| {
                var owned = p;
                defer owned.deinit(gpa);
                try app.transcript.progress(gpa, p);
            },
            .background => |b| {
                defer gpa.free(b.id);
                defer if (b.result) |result| gpa.free(result);
                switch (b.state) {
                    .started => app.background_count += 1,
                    .finished => {
                        app.background_count -|= 1;
                        try app.transcript.backgroundResult(gpa, b.kind, b.id, b.ok orelse false, b.result orelse "{}");
                    },
                    .lost => {
                        app.background_count -|= 1;
                        try app.transcript.lostBackground(gpa, b.kind, b.id, b.result orelse "background task was lost");
                    },
                }
            },
            .turn_end => |summary| app.pending_bill = summary,
            .user_inserted => |id| app.transcript.userInserted(id),
            .done => {
                const canceled = app.turn.?.cancel.load(.acquire);
                try app.finishTurn();
                try app.saveReflection();
                try app.appendBill();
                try app.finishQueued(!canceled);
            },
            .issue => |msg| {
                defer gpa.free(msg);
                try app.transcript.add(gpa, .info, msg);
            },
            .issues_done => {
                if (app.issues) |job| job.finish();
                app.issues = null;
            },
            .failed => |msg| {
                defer gpa.free(msg);
                app.stopReflecting();
                const canceled = app.turn.?.cancel.load(.acquire);
                try app.transcript.add(gpa, if (canceled) .info else .err, if (canceled) "canceled" else msg);
                try app.finishTurn();
                try app.appendBill();
                try app.finishQueued(false);
            },
        }
        return true;
    }

    fn onKey(app: *App, k: vaxis.Key) !bool {
        app.notice = null;
        const gpa = app.gpa;
        if (app.pasting) {
            if (k.text) |t| {
                try app.paste_buf.appendSlice(gpa, t);
            } else if (isNewline(k, true)) {
                try app.paste_buf.append(gpa, '\n');
            } else if (k.matches(vaxis.Key.tab, .{})) {
                try app.paste_buf.append(gpa, '\t');
            }
            return true;
        }
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
            app.scroll.pending = if (app.scroll.top != null) std.math.maxInt(i32) else page;
        } else if (k.matches('o', .{ .ctrl = true })) {
            app.transcript.toggleExpanded();
        } else if (k.matches(vaxis.Key.up, .{ .shift = true })) {
            app.scroll.pending -= 3;
        } else if (k.matches(vaxis.Key.down, .{ .shift = true })) {
            app.scroll.pending += 3;
        } else if (isNewline(k, app.pasting)) {
            try input.insert(gpa, "\n");
        } else if (k.matches(vaxis.Key.enter, .{})) {
            if (app.turn == null or commands.parse(input.text()) == null or commands.allowedWhileBusy(input.text())) submitted = try input.take(gpa);
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
        if (app.turn != null) {
            defer gpa.free(line);
            const id = try app.session.enqueue(line);
            try app.transcript.add(gpa, .user, line);
            app.transcript.entries.items[app.transcript.entries.items.len - 1].queued = id;
            return;
        }
        try app.startTurn(line);
    }

    /// Takes ownership of text without interpreting slash commands.
    fn startTurn(app: *App, text: []u8) !void {
        errdefer app.gpa.free(text);
        try app.transcript.add(app.gpa, .user, text);
        app.turn = try Turn.spawn(app.gpa, app.session, app.loop, text, false);
        app.live_steps = 0;
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
                app.live_steps = 0;
                app.activity = .start(app.io, .compacting);
            },
            .reflect => {
                if (app.cfg.missingKey()) return app.transcript.add(gpa, .err, "no API key");
                const log_path = try std.fmt.allocPrint(gpa, "{s}/sessions/{s}.jsonl", .{ session.options.home, session.id });
                defer gpa.free(log_path);
                const text = try reflect.prompt(gpa, session.id, log_path, app.issueRepo() orelse Issues.default_repo, arg);
                errdefer gpa.free(text);
                const focus = try gpa.dupe(u8, arg);
                errdefer gpa.free(focus);
                try app.transcript.add(gpa, .user, line);
                app.turn = try Turn.spawn(gpa, session, app.loop, text, false);
                app.live_steps = 0;
                app.activity = .start(app.io, .thinking);
                app.reflecting = focus;
            },
        }
    }

    fn report(app: *App, kind: EntryKind, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(app.gpa, fmt, args);
        defer app.gpa.free(message);
        try app.transcript.add(app.gpa, kind, message);
    }

    /// Appends the answer of a finished /reflect Turn to NIB_HOME/reflections.md.
    fn saveReflection(app: *App) !void {
        const focus = app.reflecting orelse return;
        defer app.stopReflecting();
        const history = app.session.history.items;
        const last = if (history.len > 0) history[history.len - 1] else return;
        const answer = if (std.mem.eql(u8, last.role, "assistant")) last.content orelse "" else "";
        if (answer.len == 0) return;
        const path = try std.fs.path.join(app.gpa, &.{ app.session.options.home, "reflections.md" });
        defer app.gpa.free(path);
        const cwd = try std.process.currentPathAlloc(app.io, app.gpa);
        defer app.gpa.free(cwd);
        reflect.append(app.io, app.gpa, path, .{
            .unix_seconds = @intCast(@divFloor(std.Io.Clock.real.now(app.io).nanoseconds, std.time.ns_per_s)),
            .session_id = app.session.id,
            .cwd = cwd,
            .model = app.cfg.model,
            .effort = app.cfg.effectiveEffort(),
            .focus = focus,
            .answer = answer,
        }) catch |err| {
            app.notice = std.fmt.bufPrint(&app.notice_buf, "could not save reflection to {s}: {s}", .{ path, @errorName(err) }) catch null;
            return;
        };
        app.notice = std.fmt.bufPrint(&app.notice_buf, "reflection saved to {s}", .{path}) catch null;
        try app.fileIssues(answer, path);
    }

    /// Null when `NIB_ISSUE_REPO=off`.
    fn issueRepo(app: *const App) ?[]const u8 {
        const repo = app.environ.get("NIB_ISSUE_REPO") orelse Issues.default_repo;
        return if (std.mem.eql(u8, repo, "off")) null else repo;
    }

    /// Publishes the reflection's issue drafts in the background; no confirmation by design.
    fn fileIssues(app: *App, answer: []const u8, reflections_path: []const u8) !void {
        const repo = app.issueRepo() orelse return;
        if (app.issues != null) return;
        const job = try app.gpa.create(Issues);
        job.* = .{ .gpa = app.gpa, .io = app.io, .loop = app.loop, .environ = app.environ, .arena = .init(app.gpa) };
        errdefer job.finish();
        const a = job.arena.allocator();
        job.drafts = try reflect.drafts(a, answer);
        if (job.drafts.len == 0) {
            job.finish();
            return;
        }
        job.repo = try a.dupe(u8, repo);
        job.reflections_path = try a.dupe(u8, reflections_path);
        job.session = try a.dupe(u8, app.session.id[0..8]);
        job.home = try a.dupe(u8, app.environ.get("HOME") orelse "");
        job.cwd = try std.process.currentPathAlloc(app.io, a);
        job.footer = try std.fmt.allocPrint(a, "_Filed automatically by nib /reflect · nib {s} · {s} · effort {s} · session {s}_", .{ @import("build_options").version, app.cfg.model, app.cfg.effectiveEffort(), job.session });
        job.thread = try std.Thread.spawn(.{}, Issues.work, .{job});
        app.issues = job;
        try app.report(.info, "filing {d} issue draft{s} to {s}", .{ job.drafts.len, if (job.drafts.len == 1) "" else "s", repo });
    }

    fn stopReflecting(app: *App) void {
        if (app.reflecting) |focus| app.gpa.free(focus);
        app.reflecting = null;
    }

    fn appendBill(app: *App) !void {
        const summary = app.pending_bill orelse return;
        var text: bill.Text = .{};
        try app.transcript.add(app.gpa, .bill, text.format(summary, std.math.maxInt(u16)));
        app.pending_bill = null;
    }

    fn clearStepEffort(app: *App) void {
        if (app.step_effort) |effort| app.gpa.free(effort.effort);
        app.step_effort = null;
    }

    fn finishTurn(app: *App) !void {
        app.clearStepEffort();
        app.turn.?.finish();
        app.turn = null;
        app.background_count = 0;
        try app.transcript.clearBackgroundProgress(app.gpa);
        app.transcript.next_run = 0;
        app.usage = app.session.usage;
        app.steps = app.session.steps;
        app.context = app.session.context_tokens;
    }

    fn finishQueued(app: *App, send: bool) !void {
        var batch = app.session.takeQueued();
        defer batch.deinit(app.gpa);
        if (batch.items.items.len == 0) return;
        const text = try batch.joined(app.gpa);
        if (text.len == 0) {
            app.gpa.free(text);
            return;
        }
        app.transcript.removeQueued(app.gpa);
        if (send) {
            try app.startTurn(text);
        } else {
            defer app.gpa.free(text);
            const draft = try app.input.expanded(app.gpa);
            defer app.gpa.free(draft);
            const restored = if (draft.len == 0) try app.gpa.dupe(u8, text) else try std.fmt.allocPrint(app.gpa, "{s}\n\n{s}", .{ text, draft });
            defer app.gpa.free(restored);
            try app.input.replace(app.gpa, restored);
            app.menu.inputChanged(app.input.text());
        }
    }

    fn render(app: *App) !void {
        try app.menu.load(app.io, app.input.text(), app.session);
        const menu = app.menu.items(app.input.text());
        if (app.scroll.pending != 0) app.selection.clear();
        view.draw(app.vx.window(), app.transcript.entries.items, &app.input, &app.scroll, menu, @min(app.menu.sel, menu.len -| 1), .{
            .cfg = app.cfg,
            .usage = app.usage,
            .steps = app.steps,
            .current_step = @max(1, app.live_steps),
            .background_count = app.background_count,
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

test "bracketed paste buffers newline and slash keys without executing them" {
    const gpa = std.testing.allocator;
    var app: App = undefined;
    app.gpa = gpa;
    app.input = .{};
    defer app.input.deinit(gpa);
    app.paste_buf = .empty;
    defer app.paste_buf.deinit(gpa);
    app.menu = .init(gpa);
    defer app.menu.deinit();
    app.notice = null;
    _ = try app.handle(.paste_start);
    _ = try app.onKey(.{ .codepoint = '/', .text = "/help" });
    for (0..5) |_| {
        _ = try app.onKey(.{ .codepoint = 'j', .mods = .{ .ctrl = true } });
        _ = try app.onKey(.{ .codepoint = 'x', .text = "x" });
    }
    try std.testing.expectEqualStrings("", app.input.text());
    _ = try app.handle(.paste_end);
    try std.testing.expectEqualStrings("[Pasted #1 · 6 lines]", app.input.text());
    const expanded = try app.input.expanded(gpa);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings("/help\nx\nx\nx\nx\nx", expanded);
}

test "usage snapshots refresh the footer without reading the running Session" {
    const t = std.testing;
    var app: App = undefined;
    app.gpa = t.allocator;
    app.usage = .{ .prompt_tokens = 99999, .completion_tokens = 999 };
    app.context = 800;
    app.steps = 9;
    _ = try app.handle(.{ .usage = .{ .tokens = .{}, .context = 800, .steps = 0 } });
    try t.expectEqualDeep(provider.Usage{}, app.usage);
    try t.expectEqual(@as(u32, 0), app.steps);
    const usage: provider.Usage = .{ .prompt_tokens = 1200, .completion_tokens = 50, .prompt_cache_hit_tokens = 600 };
    _ = try app.handle(.{ .usage = .{ .tokens = usage, .context = 1250, .steps = 1 } });
    try t.expectEqualDeep(usage, app.usage);
    try t.expectEqual(@as(u64, 1250), app.context);
    try t.expectEqual(@as(u32, 1), app.steps);
    _ = try app.handle(.{ .usage = .{ .tokens = usage, .context = 200, .steps = 1 } });
    try t.expectEqual(@as(u64, 200), app.context);
    try t.expectEqualDeep(usage, app.usage);
}

test "Turn throttles model data events but sends request boundaries immediately" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.loop = &loop;
    turn.last_model_activity = null;
    const start: std.Io.Clock.Timestamp = .now(t.io, .awake);
    for (0..100) |i| {
        try turn.modelActivityAt(.data, start.addDuration(.{ .raw = .fromMilliseconds(@intCast(i * 10)), .clock = .awake }));
    }
    const first = (try loop.tryEvent()).?.model_activity;
    try t.expectEqual(ModelActivity.data, first.state);
    try t.expectEqualDeep(start, first.at);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());
    const before = start.addDuration(.{ .raw = .fromMilliseconds(999), .clock = .awake });
    try turn.modelActivityAt(.data, before);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());
    const next = start.addDuration(.{ .raw = .fromMilliseconds(1000), .clock = .awake });
    try turn.modelActivityAt(.data, next);
    const second = (try loop.tryEvent()).?.model_activity;
    try t.expectEqual(ModelActivity.data, second.state);
    try t.expectEqualDeep(next, second.at);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());

    try turn.modelActivityAt(.started, next);
    const before_next = next.addDuration(.{ .raw = .fromMilliseconds(999), .clock = .awake });
    for (0..100) |_| try turn.modelActivityAt(.data, before_next);
    try t.expectEqual(ModelActivity.started, (try loop.tryEvent()).?.model_activity.state);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());
    const after_start = next.addDuration(.{ .raw = .fromMilliseconds(1000), .clock = .awake });
    try turn.modelActivityAt(.data, after_start);
    try turn.modelActivityAt(.finished, after_start);
    try turn.modelActivityAt(.started, after_start);
    try turn.modelActivityAt(.data, after_start);
    for ([_]ModelActivity{ .data, .finished, .started }) |state| {
        try t.expectEqual(state, (try loop.tryEvent()).?.model_activity.state);
    }
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());

    const silence = after_start.addDuration(.{ .raw = .fromMilliseconds(30_000), .clock = .awake });
    try turn.modelActivityAt(.data, silence);
    const resumed = (try loop.tryEvent()).?.model_activity;
    try t.expectEqual(ModelActivity.data, resumed.state);
    try t.expectEqualDeep(silence, resumed.at);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());
}

test "turn_end forwards by value and defers bills until terminal content" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.gpa = t.allocator;
    turn.loop = &loop;
    var app: App = undefined;
    app.gpa = t.allocator;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.pending_bill = null;
    inline for (.{ .completed, .canceled, .failed }) |status_value| {
        const summary: TurnSummary = .{ .status = status_value, .steps = 2, .timing = .{ .wall_ms = 1000 } };
        try app.transcript.add(t.allocator, .assistant, "answer");
        const before = app.transcript.entries.items.len;
        try Turn.emit(&turn, .{ .turn_end = summary });
        const event = (try loop.tryEvent()).?;
        try t.expectEqualDeep(summary, event.turn_end);
        _ = try app.handle(event);
        try t.expectEqual(before, app.transcript.entries.items.len);
        try t.expectEqualDeep(summary, app.pending_bill.?);
        if (status_value != .completed) try app.transcript.add(t.allocator, .err, @tagName(status_value));
        try app.appendBill();
        const entries = app.transcript.entries.items;
        try t.expectEqual(EntryKind.bill, entries[entries.len - 1].kind);
        try t.expectEqualStrings(if (status_value == .completed) "answer" else @tagName(status_value), entries[entries.len - 2].text.items);
        try t.expect(app.pending_bill == null);
        const count = entries.len;
        try app.appendBill();
        try t.expectEqual(count, app.transcript.entries.items.len);
    }
}

test "insertion notifications reach the queued user entry" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.loop = &loop;
    var app: App = undefined;
    app.gpa = t.allocator;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    try app.transcript.add(t.allocator, .user, "interjection");
    app.transcript.entries.items[0].queued = 42;
    try Turn.userInserted(&turn, 42);
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqual(@as(?u64, null), app.transcript.entries.items[0].queued);
}

test "background events own their payload and maintain running count" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.gpa = t.allocator;
    turn.loop = &loop;
    var app: App = undefined;
    app.gpa = t.allocator;
    app.transcript = .{};
    app.background_count = 0;
    defer app.transcript.deinit(t.allocator);
    var id = [_]u8{ 'b', 'g', '_', '1' };
    try Turn.emit(&turn, .{ .background = .{ .id = &id, .kind = .agent, .state = .started } });
    id[3] = '2';
    const started = (try loop.tryEvent()).?;
    try t.expectEqualStrings("bg_1", started.background.id);
    _ = try app.handle(started);
    try t.expectEqual(@as(usize, 1), app.background_count);
    try t.expectEqual(@as(usize, 0), app.transcript.entries.items.len);
    try Turn.emit(&turn, .{ .background = .{ .id = "bg_1", .kind = .agent, .state = .finished, .ok = true, .result = "{\"ok\":true,\"text\":\"done\"}" } });
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqual(@as(usize, 0), app.background_count);
    try t.expectEqual(EntryKind.background, app.transcript.entries.items[0].kind);
    try t.expectEqualStrings("bg agent bg_1 · ok=true · done", app.transcript.entries.items[0].label.items);
}

test "Step events own effort and Runs keep their generating Step metadata" {
    const t = std.testing;
    var app: App = undefined;
    app.gpa = t.allocator;
    app.io = t.io;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.step_effort = null;
    defer app.clearStepEffort();
    app.activity = .start(t.io, .thinking);
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.gpa = t.allocator;
    turn.loop = &loop;
    var effort = [_]u8{ 'h', 'i', 'g', 'h' };
    try Turn.emit(&turn, .{ .step = .{ .n = 3, .effort = &effort, .source = .guard } });
    effort[0] = 'x';
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqual(@as(u32, 3), app.live_steps);
    _ = try app.handle(.{ .run_start = .{ .code = try t.allocator.dupe(u8, "tools.read({})"), .step = 3 } });
    _ = try app.handle(.{ .run_end = .{ .ok = true, .output = try t.allocator.dupe(u8, "out"), .changes = .{} } });
    _ = try app.handle(.{ .step = .{ .n = 4, .effort = try t.allocator.dupe(u8, "low"), .source = .model } });
    try t.expectEqualStrings("high", app.transcript.entries.items[0].step_effort.?.effort);
    try t.expectEqualStrings("low", app.step_effort.?.effort);
    try t.expect(std.mem.endsWith(u8, app.transcript.entries.items[0].label.items, " · high (guard)"));
}

test "Run summary survives event queue and original summary destruction" {
    const t = std.testing;
    var app: App = undefined;
    app.gpa = t.allocator;
    app.io = t.io;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.activity = .start(t.io, .running);
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.gpa = t.allocator;
    turn.loop = &loop;
    try app.transcript.startRun(t.allocator, "// tools.llm(");
    {
        const source = try (ToolSummary{ .counts = &.{.{ .name = "edit", .count = 2 }}, .omitted = 3 }).clone(t.allocator);
        defer source.deinit(t.allocator);
        try Turn.emit(&turn, .{ .run_end = .{ .ok = true, .output = "done", .tool_summary = source } });
    }
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqualStrings("edit", app.transcript.entries.items[0].tool_summary.?.counts[0].name);
    try t.expectEqual(@as(u64, 2), app.transcript.entries.items[0].tool_summary.?.counts[0].count);
    try t.expect(std.mem.startsWith(u8, app.transcript.entries.items[0].label.items, "edit ×2, +3 · "));
}
