const std = @import("std");
const vaxis = @import("vaxis");
const js = @import("js.zig");
const agent = @import("agent.zig");
const openai = @import("provider/openai.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    /// Slices are owned by the receiver.
    delta: struct { kind: openai.Kind, text: []u8 },
    run_start: []u8,
    run_end: struct { ok: bool, output: []u8 },
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
        });
    }

    fn finish(t: *Turn) void {
        t.thread.join();
        t.gpa.free(t.text);
        t.gpa.destroy(t);
    }
};

pub fn run(init: std.process.Init, client: *std.http.Client, cfg: openai.Config) !void {
    const io = init.io;
    const gpa = init.gpa;

    var session = try agent.Session.init(gpa, io, client, cfg);
    defer session.deinit();

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
    defer {
        for (entries.items) |*e| e.text.deinit(gpa);
        entries.deinit(gpa);
    }

    var usage: openai.Usage = .{};
    var steps: u32 = 0;
    var turn: ?*Turn = null;
    defer if (turn) |t| {
        t.cancel.store(true, .release);
        t.finish();
    };

    if (cfg.api_key.len == 0) try addEntry(gpa, &entries, .err, "no API key: set DEEPSEEK_API_KEY (or NIB_API_KEY). /js <code> still works.");

    while (true) {
        switch (try loop.nextEvent()) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('d', .{ .ctrl = true })) break;
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (turn) |t| t.cancel.store(true, .release);
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (turn != null) continue; // one Turn at a time
                    const line = try input.toOwnedSlice();
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
                        t.* = .{ .gpa = gpa, .session = &session, .text = line, .loop = &loop };
                        t.thread = try std.Thread.spawn(.{}, Turn.work, .{t});
                        turn = t;
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
            .done => {
                turn.?.finish();
                turn = null;
                usage = session.usage;
                steps = session.steps;
            },
            .failed => |msg| {
                defer gpa.free(msg);
                const canceled = turn.?.cancel.load(.acquire);
                try addEntry(gpa, &entries, if (canceled) .info else .err, if (canceled) "canceled" else msg);
                turn.?.finish();
                turn = null;
                usage = session.usage;
                steps = session.steps;
            },
        }

        draw(vx.window(), entries.items, &input, cfg.model, usage, steps, turn != null);
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

fn draw(win: vaxis.Window, entries: []const Entry, input: *vaxis.widgets.TextInput, model: []const u8, usage: openai.Usage, steps: u32, busy: bool) void {
    win.clear();
    if (win.height < 4 or win.width < 4) return;

    const body = win.child(.{ .x_off = 1, .width = win.width - 2, .height = win.height - 3 });
    // Measuring needs a window taller than the content, or print() clips.
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
    const status = std.fmt.bufPrint(&status_buf, "{s} · last turn: {d} steps, in {d} (cache {d}), out {d} · {s}", .{
        model,
        steps,
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
