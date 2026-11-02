const std = @import("std");
const vaxis = @import("vaxis");
const js = @import("js.zig");
const agent = @import("agent.zig");
const openai = @import("provider/openai.zig");
const Editor = @import("editor.zig").Editor;
const markdown = @import("markdown.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    paste_start,
    paste_end,
    /// Slices are owned by the receiver.
    delta: struct { kind: openai.Kind, text: []u8 },
    run_start: []u8,
    run_end: struct { ok: bool, output: []u8 },
    retry: []u8,
    notice: []u8,
    done,
    failed: []u8,
};

const Entry = struct {
    kind: enum { user, assistant, reasoning, run_code, run_output, run_error, info, err },
    text: std.ArrayList(u8) = .empty,
    cached: ?struct { width: u16, len: usize, rows: u16 } = null,

    fn print(e: *const Entry, win: vaxis.Window, commit: bool) u16 {
        if (e.kind == .assistant) return markdown.print(win, e.text.items, commit);
        var segs: [2]vaxis.Segment = undefined;
        const r = win.print(segmentsFor(e, &segs), .{ .wrap = .word, .commit = commit });
        return @max(1, r.row +| @intFromBool(r.col > 0));
    }

    fn height(e: *Entry, win: vaxis.Window) u16 {
        if (e.cached) |c| {
            if (c.width == win.width and c.len == e.text.items.len) return c.rows;
        }
        var measure = win;
        measure.height = std.math.maxInt(u16);
        const rows = e.print(measure, false);
        e.cached = .{ .width = win.width, .len = e.text.items.len, .rows = rows };
        return rows;
    }
};

const Anchor = struct {
    entry: usize = 0,
    row: u16 = 0,

    fn atOrAfter(a: Anchor, b: Anchor) bool {
        return a.entry > b.entry or (a.entry == b.entry and a.row >= b.row);
    }
};

const Viewport = struct {
    top: ?Anchor = null,
    pending: i64 = 0,

    fn bottom(entries: []Entry, win: vaxis.Window) Anchor {
        var i = entries.len;
        var rows: i64 = -1;
        while (i > 0 and rows < win.height) {
            i -= 1;
            rows += @as(i64, entries[i].height(win)) + 1;
        }
        return .{ .entry = i, .row = @intCast(@max(rows - win.height, 0)) };
    }

    fn layout(v: *Viewport, entries: []Entry, win: vaxis.Window) Anchor {
        const end = bottom(entries, win);
        var top = v.top orelse end;
        if (entries.len > 0) top.row = @min(top.row, entries[top.entry].height(win));
        var left = @abs(v.pending);
        while (left > 0 and entries.len > 0) {
            if (v.pending < 0) {
                const step = @min(left, top.row);
                top.row -= @intCast(step);
                left -= step;
                if (left == 0 or top.entry == 0) break;
                top.entry -= 1;
                top.row = entries[top.entry].height(win) +| 1;
            } else {
                const step = @min(left, @as(u32, entries[top.entry].height(win)) + 1 - top.row);
                top.row += @intCast(step);
                left -= step;
                if (top.row <= entries[top.entry].height(win)) break;
                if (top.entry + 1 == entries.len) break;
                top.entry += 1;
                top.row = 0;
            }
        }
        v.pending = 0;
        if (top.atOrAfter(end)) {
            v.top = null;
            return end;
        }
        v.top = top;
        return top;
    }
};

const run_output_lines = 12;

/// The UI thread must not touch the Session while a Turn is running.
const Turn = struct {
    gpa: std.mem.Allocator,
    session: *agent.Session,
    text: []const u8,
    loop: *vaxis.Loop(Event),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn work(t: *Turn) void {
        var detail: ?[]u8 = null;
        t.session.turn(t.text, .{ .ctx = t, .emit = emit }, &t.cancel, &detail) catch |err| {
            const msg = detail orelse (t.gpa.dupe(u8, @errorName(err)) catch return);
            t.loop.postEvent(.{ .failed = msg }) catch t.gpa.free(msg);
            return;
        };
        t.loop.postEvent(.done) catch {};
    }

    fn emit(ctx: *anyopaque, ev: agent.Event) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        const gpa = t.gpa;
        try t.loop.postEvent(switch (ev) {
            .delta => |d| .{ .delta = .{ .kind = d.kind, .text = try gpa.dupe(u8, d.text) } },
            .run_start => |code| .{ .run_start = try gpa.dupe(u8, code) },
            .run_end => |r| .{ .run_end = .{ .ok = r.ok, .output = try gpa.dupe(u8, r.output) } },
            .retry => |r| .{ .retry = try std.fmt.allocPrint(gpa, "retry {d} in {d}s: {s}", .{ r.attempt, r.delay_ms / 1000, r.reason }) },
            .notice => |m| .{ .notice = try gpa.dupe(u8, m) },
        });
    }

    fn finish(t: *Turn) void {
        t.thread.join();
        t.gpa.free(t.text);
        t.gpa.destroy(t);
    }
};

/// `session` may already hold history (a resumed Session); it is shown first.
pub fn run(init: std.process.Init, session: *agent.Session) !void {
    const io = init.io;
    const gpa = init.gpa;
    const cfg = session.cfg;

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
    var input: Editor = .{};
    defer input.deinit(gpa);
    var pasting = false;
    var scroll: Viewport = .{};

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| e.text.deinit(gpa);
        entries.deinit(gpa);
    }

    var usage: openai.Usage = .{};
    var steps: u32 = 0;
    var context: u64 = session.context_tokens;
    var turn: ?*Turn = null;
    defer if (turn) |t| {
        t.cancel.store(true, .release);
        t.finish();
    };

    try addHistory(gpa, &entries, session.history.items);
    for (session.history.items) |m| {
        if (std.mem.eql(u8, m.role, "user")) try input.remember(gpa, m.content orelse "");
    }
    if (cfg.api_key.len == 0) try addEntry(gpa, &entries, .err, "no API key: set DEEPSEEK_API_KEY (or NIB_API_KEY). /js <code> still works.");

    while (true) {
        switch (try loop.nextEvent()) {
            .key_press => |key| {
                const page = @max(vx.window().height / 2, 1);
                if (key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('d', .{ .ctrl = true }) and input.text().len == 0) break;
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (turn) |t| t.cancel.store(true, .release);
                } else if (key.matches(vaxis.Key.page_up, .{})) {
                    scroll.pending -= page;
                } else if (key.matches(vaxis.Key.page_down, .{})) {
                    scroll.pending += page;
                } else if (key.matches(vaxis.Key.up, .{ .shift = true })) {
                    scroll.pending -= 3;
                } else if (key.matches(vaxis.Key.down, .{ .shift = true })) {
                    scroll.pending += 3;
                } else if (isNewline(key, pasting)) {
                    try input.insert(gpa, "\n");
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (turn != null) continue; // one Turn at a time
                    scroll = .{};
                    const line = try input.take(gpa);
                    if (line.len == 0) {
                        gpa.free(line);
                        continue;
                    }
                    if (std.mem.startsWith(u8, line, "/js ")) {
                        defer gpa.free(line);
                        try addEntry(gpa, &entries, .user, line);
                        const r = try js.eval(gpa, io, line[4..], .{}, session.tools.host(), null);
                        defer r.deinit(gpa);
                        if (r.logs.len > 0) try addEntry(gpa, &entries, .run_output, std.mem.trimEnd(u8, r.logs, "\n"));
                        try addEntry(gpa, &entries, if (r.ok) .info else .err, r.text);
                    } else if (std.mem.eql(u8, line, "/compact")) {
                        const t = try gpa.create(Turn);
                        t.* = .{ .gpa = gpa, .session = session, .text = line, .loop = &loop };
                        t.thread = try std.Thread.spawn(.{}, struct {
                            fn work(task: *Turn) void {
                                var detail: ?[]u8 = null;
                                _ = task.session.compact(.{ .ctx = task, .emit = Turn.emit }, &task.cancel, &detail) catch |err| {
                                    const msg = detail orelse (task.gpa.dupe(u8, @errorName(err)) catch return);
                                    task.loop.postEvent(.{ .failed = msg }) catch task.gpa.free(msg);
                                    return;
                                };
                                task.loop.postEvent(.done) catch {};
                            }
                        }.work, .{t});
                        turn = t;
                    } else if (cfg.api_key.len == 0) {
                        gpa.free(line);
                        try addEntry(gpa, &entries, .err, "no API key");
                    } else {
                        try addEntry(gpa, &entries, .user, line);
                        const t = try gpa.create(Turn);
                        t.* = .{ .gpa = gpa, .session = session, .text = line, .loop = &loop };
                        t.thread = try std.Thread.spawn(.{}, Turn.work, .{t});
                        turn = t;
                    }
                } else {
                    _ = try input.key(gpa, key);
                }
            },
            .paste_start => pasting = true,
            .paste_end => pasting = false,
            .winsize => |ws| try vx.resize(gpa, w, ws),
            .delta => |d| {
                defer gpa.free(d.text);
                const kind: @FieldType(Entry, "kind") = if (d.kind == .reasoning) .reasoning else .assistant;
                const last = if (entries.items.len > 0) &entries.items[entries.items.len - 1] else null;
                if (last == null or last.?.kind != kind) try entries.append(gpa, .{ .kind = kind });
                try entries.items[entries.items.len - 1].text.appendSlice(gpa, d.text);
            },
            .run_start => |code| {
                defer gpa.free(code);
                try addEntry(gpa, &entries, .run_code, std.mem.trim(u8, code, "\n"));
            },
            .run_end => |r| {
                defer gpa.free(r.output);
                var e: Entry = .{ .kind = if (r.ok) .run_output else .run_error };
                try appendHead(gpa, &e.text, r.output, run_output_lines);
                try entries.append(gpa, e);
            },
            .retry, .notice => |msg| {
                defer gpa.free(msg);
                try addEntry(gpa, &entries, .info, msg);
            },
            .done => {
                turn.?.finish();
                turn = null;
                usage = session.usage;
                steps = session.steps;
                context = session.context_tokens;
            },
            .failed => |msg| {
                defer gpa.free(msg);
                const canceled = turn.?.cancel.load(.acquire);
                try addEntry(gpa, &entries, if (canceled) .info else .err, if (canceled) "canceled" else msg);
                turn.?.finish();
                turn = null;
                usage = session.usage;
                steps = session.steps;
                context = session.context_tokens;
            },
        }

        draw(vx.window(), entries.items, &input, &scroll, cfg, usage, steps, context, turn != null);
        try vx.render(w);
        try w.flush();
    }
}

fn appendHead(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, max_lines: usize) !void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        if (n == max_lines) {
            var rest: usize = 1;
            while (it.next()) |_| rest += 1;
            try out.print(gpa, "\n… {d} more lines", .{rest});
            return;
        }
        if (n > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, line);
    }
}

fn addHistory(gpa: std.mem.Allocator, entries: *std.ArrayList(Entry), history: []const openai.Message) !void {
    for (history) |m| {
        const content = m.content orelse "";
        if (std.mem.eql(u8, m.role, "user")) {
            try addEntry(gpa, entries, .user, content);
        } else if (std.mem.eql(u8, m.role, "assistant")) {
            if (m.reasoning_content) |r| try addEntry(gpa, entries, .reasoning, r);
            if (content.len > 0) try addEntry(gpa, entries, .assistant, content);
            for (m.tool_calls orelse &.{}) |call| {
                const Args = struct { code: []const u8 = "" };
                const args = std.json.parseFromSlice(Args, gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch continue;
                defer args.deinit();
                try addEntry(gpa, entries, .run_code, std.mem.trim(u8, args.value.code, "\n"));
            }
        } else if (std.mem.eql(u8, m.role, "tool")) {
            var e: Entry = .{ .kind = .run_output };
            try appendHead(gpa, &e.text, content, run_output_lines);
            try entries.append(gpa, e);
        }
    }
}

fn addEntry(gpa: std.mem.Allocator, entries: *std.ArrayList(Entry), kind: @FieldType(Entry, "kind"), text: []const u8) !void {
    var e: Entry = .{ .kind = kind };
    try e.text.appendSlice(gpa, text);
    try entries.append(gpa, e);
}

fn segmentsFor(e: *const Entry, buf: *[2]vaxis.Segment) []const vaxis.Segment {
    switch (e.kind) {
        .user => {
            buf[0] = .{ .text = "› ", .style = .{ .bold = true, .fg = .{ .index = 4 } } };
            buf[1] = .{ .text = e.text.items, .style = .{ .bold = true } };
            return buf[0..2];
        },
        .assistant => buf[0] = .{ .text = e.text.items },
        .reasoning => buf[0] = .{ .text = e.text.items, .style = .{ .dim = true, .italic = true } },
        .run_code => {
            buf[0] = .{ .text = "run ▸ ", .style = .{ .fg = .{ .index = 3 }, .bold = true } };
            buf[1] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 3 } } };
            return buf[0..2];
        },
        .run_output => buf[0] = .{ .text = e.text.items, .style = .{ .dim = true } },
        .run_error => buf[0] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 1 }, .dim = true } },
        .info => buf[0] = .{ .text = e.text.items, .style = .{ .dim = true } },
        .err => buf[0] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 1 } } },
    }
    return buf[0..1];
}

fn isNewline(key: vaxis.Key, pasting: bool) bool {
    const enter = vaxis.Key.enter;
    return (pasting and key.matches(enter, .{})) or key.matches(enter, .{ .shift = true }) or
        key.matches(enter, .{ .alt = true }) or key.matches('j', .{ .ctrl = true });
}

fn draw(win: vaxis.Window, entries: []Entry, input: *Editor, scroll: *Viewport, cfg: openai.Config, usage: openai.Usage, steps: u32, context: u64, busy: bool) void {
    win.clear();
    win.hideCursor();
    if (win.height < 6 or win.width < 8) return;

    const input_rows = input.rows(win.child(.{ .x_off = 3 }));
    const input_h: u16 = @min(input_rows, win.height / 3);
    const body_h: u16 = win.height - 1 - input_h;
    const body = win.child(.{ .x_off = 1, .width = win.width - 2, .height = body_h });
    const top = scroll.layout(entries, body);
    var y: i32 = -@as(i32, top.row);
    for (entries[top.entry..]) |*e| {
        if (y >= body_h) break;
        const h = e.height(body);
        if (y + h > 0) _ = e.print(body.child(.{ .y_off = @intCast(y), .height = h }), true);
        y += @as(i32, h) + 1;
    }

    var status_buf: [256]u8 = undefined;
    const status = if (scroll.top != null)
        "↑ history · PgDn / shift+↓ to return"
    else
        std.fmt.bufPrint(&status_buf, "{s} · ctx {d}% · last turn: {d} steps, in {d} (cache {d}), out {d} · {s}", .{
            cfg.model,
            context * 100 / @max(cfg.context_window, 1),
            steps,
            usage.prompt_tokens,
            usage.prompt_cache_hit_tokens,
            usage.completion_tokens,
            if (busy) "working… esc to cancel" else "shift+enter newline · ctrl-c quit",
        }) catch "";
    _ = win.child(.{ .x_off = 1, .y_off = body_h, .height = 1 }).printSegment(.{ .text = status, .style = .{ .dim = true } }, .{ .wrap = .none });

    _ = win.child(.{ .x_off = 1, .y_off = body_h + 1, .height = 1 }).printSegment(.{ .text = "› ", .style = .{ .fg = .{ .index = 4 } } }, .{});
    input.draw(win.child(.{ .x_off = 3, .y_off = body_h + 1, .height = input_h }));
}

test "draw benchmark: 5000 entries" {
    const benchmark = std.testing.environ.getPosix("NIB_TUI_BENCH") != null;
    const frames: u8 = if (benchmark) 32 else 1;
    const gpa = std.testing.allocator;
    const entries = try gpa.alloc(Entry, 5000);
    defer gpa.free(entries);
    const sample = "A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. ";
    for (entries) |*e| e.* = .{ .kind = .assistant, .text = .fromOwnedSlice(@constCast(sample)) };
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 24, .screen = &screen };
    var input: Editor = .{};
    defer input.deinit(gpa);
    const cfg: openai.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    for ([_]u32{ 0, 1200 }) |offset| {
        var samples: [5]i96 = undefined;
        for (&samples) |*sample_ns| {
            var scroll: Viewport = .{ .pending = -@as(i64, offset) };
            draw(win, entries, &input, &scroll, cfg, .{}, 0, 0, false);
            const before = std.Io.Clock.awake.now(std.testing.io);
            for (0..frames) |_| {
                draw(win, entries, &input, &scroll, cfg, .{}, 0, 0, false);
            }
            sample_ns.* = @divTrunc(before.untilNow(std.testing.io, .awake).nanoseconds, frames);
        }
        std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
        if (benchmark) std.debug.print("\nTUI draw: 5000 entries, offset {d}, median {d} ns/frame\n", .{ offset, samples[2] });
        try std.testing.expect(screen.cursor_vis);
    }
}

test "entry height cache reuses measurements and invalidates on width or append" {
    const gpa = std.testing.allocator;
    var screen: vaxis.Screen = .{};
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 24, .screen = &screen };
    var e: Entry = .{ .kind = .assistant };
    defer e.text.deinit(gpa);
    try e.text.appendSlice(gpa, "1234567890");
    try std.testing.expectEqual(@as(u16, 1), e.height(win));
    e.cached.?.rows = 123;
    try std.testing.expectEqual(@as(u16, 123), e.height(win));
    win.width = 5;
    try std.testing.expectEqual(@as(u16, 2), e.height(win));
    try e.text.appendSlice(gpa, "12345");
    try std.testing.expectEqual(@as(u16, 3), e.height(win));
}

test "viewport anchors survive streaming and appended Run output then resume following" {
    const gpa = std.testing.allocator;
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 20, .height = 4, .screen = &screen };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| e.text.deinit(gpa);
        entries.deinit(gpa);
    }
    try addEntry(gpa, &entries, .user, "one");
    try addEntry(gpa, &entries, .assistant, "two\nthree\nfour");
    var view: Viewport = .{ .pending = -2 };
    const top = view.layout(entries.items, win);
    try std.testing.expect(view.top != null);
    try entries.items[1].text.appendSlice(gpa, "\nfive\nsix");
    try std.testing.expectEqualDeep(top, view.layout(entries.items, win));
    try addEntry(gpa, &entries, .run_output, "output\nmore output");
    try std.testing.expectEqualDeep(top, view.layout(entries.items, win));
    view.pending = 100;
    _ = view.layout(entries.items, win);
    try std.testing.expect(view.top == null);
    try addEntry(gpa, &entries, .assistant, "done");
    try std.testing.expectEqualDeep(Viewport.bottom(entries.items, win), view.layout(entries.items, win));
}

test "viewport can traverse all 5000 entries and gaps in both directions" {
    const gpa = std.testing.allocator;
    const entries = try gpa.alloc(Entry, 5000);
    defer gpa.free(entries);
    for (entries) |*e| e.* = .{ .kind = .info };
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 4, .screen = &screen };
    var view: Viewport = .{ .pending = -100_000 };
    try std.testing.expectEqualDeep(Anchor{}, view.layout(entries, win));
    view.pending = 1;
    try std.testing.expectEqualDeep(Anchor{ .row = 1 }, view.layout(entries, win));
    view.pending = 1;
    try std.testing.expectEqualDeep(Anchor{ .entry = 1 }, view.layout(entries, win));
    view.pending = -1;
    try std.testing.expectEqualDeep(Anchor{ .row = 1 }, view.layout(entries, win));
    view.pending = 100_000;
    try std.testing.expectEqualDeep(Viewport.bottom(entries, win), view.layout(entries, win));
    try std.testing.expect(view.top == null);
}

test "draw keeps scrolled body fixed while output arrives and caps input height" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 24, .screen = &screen };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| e.text.deinit(gpa);
        entries.deinit(gpa);
    }
    var paragraph: std.ArrayList(u8) = .empty;
    defer paragraph.deinit(gpa);
    for (0..40) |i| try paragraph.print(gpa, "line {d}\n", .{i});
    try addEntry(gpa, &entries, .assistant, paragraph.items);
    try addEntry(gpa, &entries, .assistant, "stream");
    var input: Editor = .{};
    defer input.deinit(gpa);
    var view: Viewport = .{ .pending = -30 };
    const cfg: openai.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    draw(win, entries.items, &input, &view, cfg, .{}, 0, 0, true);
    const body_before = try gpa.dupe(vaxis.Cell, screen.buf[0 .. 22 * 100]);
    defer gpa.free(body_before);
    try entries.items[1].text.appendSlice(gpa, "\nmore streamed text");
    try addEntry(gpa, &entries, .run_output, "Run output");
    draw(win, entries.items, &input, &view, cfg, .{}, 0, 0, true);
    try std.testing.expectEqualDeep(body_before, screen.buf[0 .. 22 * 100]);
    for (0..16) |i| try input.buf.print(gpa, "input {d}\n", .{i});
    input.cursor = input.buf.items.len;
    draw(win, entries.items, &input, &view, cfg, .{}, 0, 0, true);
    try std.testing.expectEqual(@as(u16, 9), input.top_row);
    try std.testing.expectEqual(@as(u16, 23), screen.cursor.row);
    try std.testing.expect(screen.cursor_vis);
    try std.testing.expectEqualStrings("i", screen.readCell(3, 16).?.char.grapheme);
}
