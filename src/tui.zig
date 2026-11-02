const std = @import("std");
const vaxis = @import("vaxis");
const js = @import("js.zig");
const agent = @import("agent.zig");
const openai = @import("provider/openai.zig");
const Editor = @import("editor.zig").Editor;

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
    var scroll: u32 = 0;

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
                    scroll +|= page;
                } else if (key.matches(vaxis.Key.page_down, .{})) {
                    scroll -|= page;
                } else if (key.matches(vaxis.Key.up, .{ .shift = true })) {
                    scroll +|= 3;
                } else if (key.matches(vaxis.Key.down, .{ .shift = true })) {
                    scroll -|= 3;
                } else if (isNewline(key, pasting)) {
                    try input.insert(gpa, "\n");
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (turn != null) continue; // one Turn at a time
                    scroll = 0;
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

/// `scroll` counts rows above the bottom and is clamped to the transcript.
fn draw(win: vaxis.Window, entries: []const Entry, input: *const Editor, scroll: *u32, cfg: openai.Config, usage: openai.Usage, steps: u32, context: u64, busy: bool) void {
    win.clear();
    win.hideCursor();
    if (win.height < 6 or win.width < 8) return;

    // Measuring needs a window taller than the content, or print() clips.
    const input_rows = input.rows(win.child(.{ .x_off = 3, .y_off = -10_000 }));
    const input_h: u16 = @min(input_rows, win.height / 3);
    const body_h: u16 = win.height - 1 - input_h;
    const body = win.child(.{ .x_off = 1, .width = win.width - 2, .height = body_h });
    const tall = body.child(.{ .y_off = -10_000 });

    var heights: [1024]u16 = undefined;
    const want: i64 = @as(i64, body_h) + scroll.*;
    var content: i64 = -1;
    var start = entries.len;
    while (start > 0 and entries.len - start < heights.len and content < want) {
        start -= 1;
        var segs: [2]vaxis.Segment = undefined;
        const r = tall.print(segmentsFor(&entries[start], &segs), .{ .wrap = .word, .commit = false });
        const h: u16 = if (r.col == 0 and r.row > 0) r.row else r.row + 1;
        heights[entries.len - 1 - start] = h;
        content += h + 1;
    }
    content = @max(content, 0);
    if (content < want) scroll.* = @intCast(@max(content - body_h, 0));

    var y: i64 = if (content > body_h) @as(i64, body_h) + scroll.* - content else 0;
    for (entries[start..], start..) |*e, i| {
        const h = heights[entries.len - 1 - i];
        if (y < body_h and y + h > 0) {
            var segs: [2]vaxis.Segment = undefined;
            _ = body.child(.{ .y_off = @intCast(y), .height = h }).print(segmentsFor(e, &segs), .{ .wrap = .word });
        }
        y += h + 1;
    }

    var status_buf: [256]u8 = undefined;
    const status = if (scroll.* > 0)
        std.fmt.bufPrint(&status_buf, "↑ {d} rows up · PgDn / shift+↓ to return", .{scroll.*}) catch ""
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
