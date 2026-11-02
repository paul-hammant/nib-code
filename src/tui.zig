//! Chat TUI: transcript above, input line below. The model streams on a
//! worker thread that posts deltas into the vaxis event queue, so the UI
//! thread never blocks on the network.

const std = @import("std");
const vaxis = @import("vaxis");
const js = @import("js.zig");
const openai = @import("provider/openai.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    /// `text` is owned by the receiver.
    delta: struct { kind: openai.Kind, text: []u8 },
    done: openai.Usage,
    /// Owned by the receiver.
    failed: []u8,
};

const Entry = struct {
    kind: enum { user, assistant, reasoning, info, err },
    text: std.ArrayList(u8) = .empty,
};

/// State shared with the worker thread for one model turn. `messages` is not
/// mutated while the turn runs.
const Turn = struct {
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    cfg: openai.Config,
    messages: []const openai.Message,
    loop: *vaxis.Loop(Event),
    cancel: std.atomic.Value(bool) = .init(false),

    fn work(t: *Turn) void {
        var detail: ?[]u8 = null;
        const sink: openai.Sink = .{ .ctx = t, .onDelta = onDelta };
        const usage = openai.stream(t.gpa, t.client, t.cfg, t.messages, sink, &t.cancel, &detail) catch |err| {
            const msg = detail orelse (t.gpa.dupe(u8, @errorName(err)) catch return);
            t.loop.postEvent(.{ .failed = msg }) catch t.gpa.free(msg);
            return;
        };
        t.loop.postEvent(.{ .done = usage }) catch {};
    }

    fn onDelta(ctx: *anyopaque, kind: openai.Kind, text: []const u8) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        try t.loop.postEvent(.{ .delta = .{ .kind = kind, .text = try t.gpa.dupe(u8, text) } });
    }
};

pub fn run(init: std.process.Init, client: *std.http.Client, cfg: openai.Config) !void {
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

    var input = vaxis.widgets.TextInput.init(gpa);
    defer input.deinit();

    var entries: std.ArrayList(Entry) = .empty;
    var history: std.ArrayList(openai.Message) = .empty;
    defer {
        for (entries.items) |*e| e.text.deinit(gpa);
        entries.deinit(gpa);
        for (history.items) |m| gpa.free(m.content);
        history.deinit(gpa);
    }

    var turn: ?*Turn = null;
    var thread: ?std.Thread = null;
    defer if (turn) |t| {
        t.cancel.store(true, .release);
        thread.?.join();
        gpa.destroy(t);
    };
    var usage: openai.Usage = .{};

    if (cfg.api_key.len == 0) try addEntry(gpa, &entries, .err, "no API key: set DEEPSEEK_API_KEY (or NIB_API_KEY). /js <code> still works.");

    while (true) {
        switch (try loop.nextEvent()) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('d', .{ .ctrl = true })) break;
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (turn) |t| t.cancel.store(true, .release);
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (turn != null) continue; // one turn at a time
                    const line = try input.toOwnedSlice();
                    defer gpa.free(line);
                    if (line.len == 0) continue;

                    if (std.mem.startsWith(u8, line, "/js ")) {
                        try addEntry(gpa, &entries, .user, line);
                        const r = try js.eval(gpa, line[4..], .{});
                        defer gpa.free(r.text);
                        try addEntry(gpa, &entries, if (r.ok) .info else .err, r.text);
                    } else if (cfg.api_key.len == 0) {
                        try addEntry(gpa, &entries, .err, "no API key");
                    } else {
                        try addEntry(gpa, &entries, .user, line);
                        try history.append(gpa, .{ .role = "user", .content = try gpa.dupe(u8, line) });
                        const t = try gpa.create(Turn);
                        t.* = .{ .gpa = gpa, .client = client, .cfg = cfg, .messages = history.items, .loop = &loop };
                        turn = t;
                        thread = try std.Thread.spawn(.{}, Turn.work, .{t});
                    }
                } else {
                    try input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| try vx.resize(gpa, w, ws),
            .delta => |d| {
                defer gpa.free(d.text);
                const kind: @FieldType(Entry, "kind") = if (d.kind == .reasoning) .reasoning else .assistant;
                const last = if (entries.items.len > 0) &entries.items[entries.items.len - 1] else null;
                if (last == null or last.?.kind != kind) try entries.append(gpa, .{ .kind = kind });
                try entries.items[entries.items.len - 1].text.appendSlice(gpa, d.text);
            },
            .done => |u| {
                usage = u;
                // The answer joins the history; reasoning stays display-only.
                const last = &entries.items[entries.items.len - 1];
                const answer = if (last.kind == .assistant) last.text.items else "";
                try history.append(gpa, .{ .role = "assistant", .content = try gpa.dupe(u8, answer) });
                endTurn(gpa, &turn, &thread);
            },
            .failed => |msg| {
                defer gpa.free(msg);
                const canceled = turn.?.cancel.load(.acquire);
                try addEntry(gpa, &entries, if (canceled) .info else .err, if (canceled) "canceled" else msg);
                // Drop the unanswered user message so history stays well-formed.
                const m = history.pop().?;
                gpa.free(m.content);
                endTurn(gpa, &turn, &thread);
            },
        }

        draw(vx.window(), entries.items, &input, cfg.model, usage, turn != null);
        try vx.render(w);
        try w.flush();
    }
}

fn endTurn(gpa: std.mem.Allocator, turn: *?*Turn, thread: *?std.Thread) void {
    thread.*.?.join();
    gpa.destroy(turn.*.?);
    turn.* = null;
    thread.* = null;
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
        .info => buf[0] = .{ .text = e.text.items, .style = .{ .dim = true } },
        .err => buf[0] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 1 } } },
    }
    return buf[0..1];
}

fn draw(win: vaxis.Window, entries: []const Entry, input: *vaxis.widgets.TextInput, model: []const u8, usage: openai.Usage, busy: bool) void {
    win.clear();
    if (win.height < 4 or win.width < 4) return;

    const body = win.child(.{ .x_off = 1, .width = win.width - 2, .height = win.height - 3 });
    // A window extending far above `body` lets us measure wrapped height
    // without clipping; nothing is drawn while measuring.
    const tall = body.child(.{ .y_off = -10_000 });

    var heights: [256]u16 = undefined;
    var total: i32 = 0;
    var start = entries.len;
    while (start > 0 and entries.len - start < heights.len and total < body.height) {
        start -= 1;
        var segs: [2]vaxis.Segment = undefined;
        const r = tall.print(segmentsFor(&entries[start], &segs), .{ .wrap = .word, .commit = false });
        const h: u16 = if (r.col == 0 and r.row > 0) r.row else r.row + 1;
        heights[entries.len - 1 - start] = h;
        total += h + 1;
    }

    var y: i32 = if (total > body.height) body.height - total + 1 else 0;
    for (entries[start..], start..) |*e, i| {
        const h = heights[entries.len - 1 - i];
        var segs: [2]vaxis.Segment = undefined;
        _ = body.child(.{ .y_off = @intCast(y), .height = h }).print(segmentsFor(e, &segs), .{ .wrap = .word });
        y += h + 1;
    }

    var status_buf: [256]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "{s} · in {d} (cache {d}) · out {d} · {s}", .{
        model,
        usage.prompt_tokens,
        usage.prompt_cache_hit_tokens,
        usage.completion_tokens,
        if (busy) "streaming… esc to cancel" else "ctrl-c to quit",
    }) catch "";
    _ = win.child(.{ .x_off = 1, .y_off = win.height - 2, .height = 1 }).printSegment(.{ .text = status, .style = .{ .dim = true } }, .{ .wrap = .none });

    const prompt = win.child(.{ .x_off = 1, .y_off = win.height - 1, .height = 1 });
    _ = prompt.printSegment(.{ .text = "› ", .style = .{ .fg = .{ .index = 4 } } }, .{});
    input.draw(prompt.child(.{ .x_off = 2 }));
}
