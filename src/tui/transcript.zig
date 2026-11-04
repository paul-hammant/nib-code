const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../provider.zig");
const long_text = @import("long_text.zig");
const markdown = @import("markdown.zig");
const Change = @import("../tools/diff.zig").Change;
const Progress = @import("../session/events.zig").Progress;
const Background = @import("../session/events.zig").Background;
const BackgroundKind = @FieldType(Background, "kind");
const bill = @import("bill.zig");

const run_output_lines = 12;
const max_diff_lines = 60;
const max_segments = 8 + max_diff_lines + 2;

pub const Kind = enum { user, assistant, run, background, info, err, bill };

pub const Entry = struct {
    kind: Kind,
    queued: ?u64 = null,
    /// For `.run`: the script.
    text: std.ArrayList(u8) = .empty,
    /// For `.run`: the first lines of its output.
    output: std.ArrayList(u8) = .empty,
    /// For `.run`: see `ChangeText`.
    changes: ChangeText = .{},
    agents: std.ArrayList(Progress) = .empty,
    run_number: usize = 0,
    agent_lines: std.ArrayList(u8) = .empty,
    /// One-line summary of a collapsible entry. vaxis keeps printed slices
    /// until render, so this must outlive draw(); see `refreshLabel`.
    label: std.ArrayList(u8) = .empty,
    run: enum { running, ok, failed } = .running,
    elapsed_ms: u64 = 0,
    step_effort: ?provider.StepEffort = null,
    /// Collapsible entries share the transcript ctrl+o state.
    open: bool = false,
    cached: ?struct { width: u16, len: usize, open: bool, rows: u16 } = null,

    pub fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        if (e.step_effort) |effort| gpa.free(effort.effort);
        e.text.deinit(gpa);
        e.output.deinit(gpa);
        e.label.deinit(gpa);
        e.changes.deinit(gpa);
        for (e.agents.items) |*p| p.deinit(gpa);
        e.agents.deinit(gpa);
        e.agent_lines.deinit(gpa);
    }

    fn refreshLabel(e: *Entry, gpa: std.mem.Allocator) !void {
        e.label.clearRetainingCapacity();
        switch (e.kind) {
            .run => {
                var buf: [96]u8 = undefined;
                const used = toolSummary(e.text.items, &buf);
                if (e.agents.items.len > 0) {
                    const agents = e.agents.items;
                    if (agents.len == 1) {
                        const p = agents[0];
                        if (p.kind == .bash) {
                            try e.label.print(gpa, "bash · {s} · ", .{if (e.run == .running) "running" else "background"});
                            try appendPreview(gpa, &e.label, p.prompt);
                            try e.label.print(gpa, " · {d}.{d}s · {s}", .{ p.elapsed_ms / 1000, p.elapsed_ms % 1000 / 100, @tagName(p.state) });
                        } else {
                            try e.label.print(gpa, "agent · {s} · step {d}", .{ if (e.run == .running) "running" else "background", p.step });
                            try appendAction(gpa, &e.label, p);
                            try appendTokens(gpa, &e.label, p.usage.prompt_tokens + p.usage.completion_tokens);
                        }
                    } else {
                        var working: usize = 0;
                        var queued: usize = 0;
                        var done: usize = 0;
                        var failed: usize = 0;
                        var bash_count: usize = 0;
                        var tokens: u64 = 0;
                        for (agents) |p| {
                            if (p.kind == .bash) bash_count += 1;
                            switch (p.state) {
                                .working => working += 1,
                                .queued => queued += 1,
                                .done => done += 1,
                                else => failed += 1,
                            }
                            tokens += p.usage.prompt_tokens + p.usage.completion_tokens;
                        }
                        try e.label.print(gpa, "{s} ×{d} · {s} · {d} working, {d} done", .{ if (bash_count == agents.len) "bash" else if (bash_count == 0) "agent" else "task", agents.len, if (e.run == .running) "running" else "background", working, done });
                        if (queued > 0) try e.label.print(gpa, ", {d} queued", .{queued});
                        if (failed > 0) try e.label.print(gpa, ", {d} failed", .{failed});
                        if (bash_count < agents.len) try appendTokens(gpa, &e.label, tokens);
                    }
                } else if (e.run == .running) {
                    try e.label.print(gpa, "{s} · running", .{used});
                } else {
                    try e.label.print(gpa, "{s} · {d}.{d}s", .{ used, e.elapsed_ms / 1000, e.elapsed_ms % 1000 / 100 });
                }
                if (e.changes.summary.len > 0) try e.label.print(gpa, " · {s}", .{e.changes.summary});
                if (e.step_effort) |effort| {
                    try e.label.print(gpa, " · {s}{s}", .{ effort.effort, if (effort.source == .guard) " (guard)" else "" });
                }
            },
            .user => {
                try e.label.print(gpa, " … +{d} lines", .{long_text.lines(e.text.items) - 1});
            },
            else => {},
        }
    }

    fn refreshAgents(e: *Entry, gpa: std.mem.Allocator) !void {
        e.agent_lines.clearRetainingCapacity();
        for (e.agents.items, 0..) |p, i| {
            if (i > 0) try e.agent_lines.append(gpa, '\n');
            try e.agent_lines.print(gpa, "#{d} ", .{p.agent});
            if (p.kind == .bash) {
                try e.agent_lines.appendSlice(gpa, "bash ");
                try appendPreview(gpa, &e.agent_lines, p.prompt);
                try e.agent_lines.print(gpa, " · {d}.{d}s · {s}", .{ p.elapsed_ms / 1000, p.elapsed_ms % 1000 / 100, @tagName(p.state) });
            } else {
                try appendPreview(gpa, &e.agent_lines, p.prompt);
                try e.agent_lines.print(gpa, " · {s} · step {d}", .{ @tagName(p.state), p.step });
                try appendAction(gpa, &e.agent_lines, p);
            }
        }
    }

    fn collapsible(e: *const Entry) bool {
        return e.kind == .run or e.kind == .background or (e.kind == .user and long_text.isLong(e.text.items));
    }

    pub fn print(e: *const Entry, win: vaxis.Window, commit: bool) u16 {
        if (e.kind == .assistant) return markdown.print(win, e.text.items, commit);
        if (e.kind == .bill) {
            _ = win.print(&.{.{ .text = bill.fit(e.text.items, win.width), .style = .{ .dim = true } }}, .{ .wrap = .none, .commit = commit });
            return 1;
        }
        var segs: [max_segments]vaxis.Segment = undefined;
        const folded = e.collapsible() and !e.open;
        const wrap: @FieldType(vaxis.Window.PrintOptions, "wrap") = if (folded) .none else if (e.kind == .run or e.kind == .background) .grapheme else .word;
        const shown = segments(e, &segs);
        if (folded and e.kind == .user) {
            const suffix_width = vaxis.gwidth.gwidth(e.label.items, win.screen.width_method) + @as(u16, if (e.queued != null) 9 else 0);
            const available = win.width -| (suffix_width +| 2);
            var end: usize = 0;
            while (end < segs[1].text.len) {
                const n = end + (std.unicode.utf8ByteSequenceLength(segs[1].text[end]) catch 1);
                if (vaxis.gwidth.gwidth(segs[1].text[0..n], win.screen.width_method) > available) break;
                end = n;
            }
            segs[1].text = segs[1].text[0..end];
        }
        const r = win.print(shown, .{ .wrap = wrap, .commit = commit });
        return if (folded) 1 else @max(1, r.row +| @intFromBool(r.col > 0));
    }

    pub fn height(e: *Entry, win: vaxis.Window) u16 {
        const len = e.text.items.len + e.output.items.len + e.changes.diff.len;
        if (e.cached) |c| {
            if (c.width == win.width and c.len == len and c.open == e.open) return c.rows;
        }
        var measure = win;
        measure.height = std.math.maxInt(u16);
        const rows = e.print(measure, false);
        e.cached = .{ .width = win.width, .len = len, .open = e.open, .rows = rows };
        return rows;
    }

    fn segments(e: *const Entry, segs: *[max_segments]vaxis.Segment) []const vaxis.Segment {
        const dim: vaxis.Style = .{ .dim = true };
        switch (e.kind) {
            .user => {
                segs[0] = .{ .text = "› ", .style = .{ .bold = true, .fg = .{ .index = 4 } } };
                const folded = e.collapsible() and !e.open;
                segs[1] = .{ .text = if (folded) e.text.items[0 .. std.mem.indexOfScalar(u8, e.text.items, '\n') orelse e.text.items.len] else e.text.items, .style = .{ .bold = true } };
                var n: usize = 2;
                if (folded) {
                    segs[n] = .{ .text = e.label.items, .style = dim };
                    n += 1;
                }
                if (e.queued != null) {
                    segs[n] = .{ .text = " · queued", .style = dim };
                    n += 1;
                }
                return segs[0..n];
            },
            .assistant => segs[0] = .{ .text = e.text.items },
            .run => {
                segs[0] = switch (e.run) {
                    .running => .{ .text = "◌ ", .style = .{ .fg = .{ .index = 3 } } },
                    .ok => .{ .text = "✓ ", .style = .{ .fg = .{ .index = 2 } } },
                    .failed => .{ .text = "✗ ", .style = .{ .fg = .{ .index = 1 } } },
                };
                segs[1] = .{ .text = if (e.agents.items.len > 0) "" else "run ", .style = .{ .fg = .{ .index = 3 }, .bold = true } };
                segs[2] = .{ .text = e.label.items, .style = dim };
                if (!e.open) return segs[0..3];
                segs[3] = .{ .text = "\n" };
                segs[4] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 3 } } };
                var n: usize = 5;
                if (e.agent_lines.items.len > 0) {
                    segs[n] = .{ .text = "\n" };
                    segs[n + 1] = .{ .text = e.agent_lines.items, .style = dim };
                    return segs[0 .. n + 2];
                }
                if (e.output.items.len > 0) {
                    segs[5] = .{ .text = "\n" };
                    segs[6] = .{ .text = e.output.items, .style = if (e.run == .failed) .{ .fg = .{ .index = 1 }, .dim = true } else dim };
                    n = 7;
                }
                const diff = std.mem.trimEnd(u8, e.changes.diff, "\n");
                if (diff.len == 0) return segs[0..n];
                segs[n] = .{ .text = "\n" };
                n += 1;
                var start: usize = 0;
                while (start < diff.len and n < segs.len) : (n += 1) {
                    const end = if (std.mem.indexOfScalarPos(u8, diff, start, '\n')) |nl| nl + 1 else diff.len;
                    const line = diff[start..end];
                    segs[n] = .{ .text = line, .style = switch (line[0]) {
                        '+' => .{ .fg = .{ .index = 2 } },
                        '-' => .{ .fg = .{ .index = 1 } },
                        ' ' => dim,
                        else => if (std.mem.startsWith(u8, line, "…")) dim else .{ .bold = true },
                    } };
                    start = end;
                }
                return segs[0..n];
            },
            .background => {
                segs[0] = .{ .text = if (e.run == .ok) "✓ " else "✗ ", .style = .{ .fg = .{ .index = if (e.run == .ok) 2 else 1 } } };
                segs[1] = .{ .text = e.label.items, .style = dim };
                if (!e.open) return segs[0..2];
                segs[2] = .{ .text = "\n" };
                segs[3] = .{ .text = e.text.items, .style = dim };
                return segs[0..4];
            },
            .info, .bill => segs[0] = .{ .text = e.text.items, .style = dim },
            .err => segs[0] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 1 } } },
        }
        return segs[0..1];
    }
};

/// What the conversation area shows, built from Session events or replayed history.
pub const Transcript = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// ctrl+o state; streamed collapsible entries start in it.
    expanded: bool = false,
    next_run: usize = 0,

    pub fn deinit(t: *Transcript, gpa: std.mem.Allocator) void {
        t.clear(gpa);
        t.entries.deinit(gpa);
    }

    pub fn clear(t: *Transcript, gpa: std.mem.Allocator) void {
        for (t.entries.items) |*e| e.deinit(gpa);
        t.entries.clearRetainingCapacity();
        t.next_run = 0;
    }

    pub fn add(t: *Transcript, gpa: std.mem.Allocator, kind: Kind, text: []const u8) !void {
        var e: Entry = .{ .kind = kind, .open = t.expanded };
        errdefer e.deinit(gpa);
        try e.text.appendSlice(gpa, text);
        try e.refreshLabel(gpa);
        try t.entries.append(gpa, e);
    }

    pub fn backgroundResult(t: *Transcript, gpa: std.mem.Allocator, kind: BackgroundKind, id: []const u8, ok: bool, result: []const u8) !void {
        try t.removeBackgroundProgress(gpa, id);
        var e: Entry = .{ .kind = .background, .run = if (ok) .ok else .failed, .open = t.expanded };
        errdefer e.deinit(gpa);
        try e.text.appendSlice(gpa, result);
        try e.label.print(gpa, "bg {s} {s} · ok={s}", .{ @tagName(kind), id, if (ok) "true" else "false" });
        const Summary = struct { text: ?[]const u8 = null, output: ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(Summary, gpa, result, .{ .ignore_unknown_fields = true }) catch null;
        if (parsed) |summary| {
            defer summary.deinit();
            const preview = if (kind == .agent) summary.value.text orelse "" else summary.value.output orelse "";
            if (preview.len > 0) {
                try e.label.appendSlice(gpa, " · ");
                try appendPreview(gpa, &e.label, preview);
            }
        } else if (std.mem.indexOf(u8, result, if (kind == .agent) "\"text\":" else "\"output\":")) |at| {
            const tail = std.mem.trimStart(u8, result[at + (if (kind == .agent) @as(usize, 7) else 9) ..], " \t\r\n");
            if (tail.len > 0 and tail[0] == '"') {
                const preview = tail[1..@min(tail.len, 1 + promptPrefix(tail[1..]).len)];
                const end = std.mem.indexOfScalar(u8, preview, '"') orelse preview.len;
                if (end > 0) {
                    try e.label.appendSlice(gpa, " · ");
                    try appendPreview(gpa, &e.label, preview[0..end]);
                }
            }
        }
        try t.entries.append(gpa, e);
    }

    pub fn lostBackground(t: *Transcript, gpa: std.mem.Allocator, kind: BackgroundKind, id: []const u8, result: []const u8) !void {
        try t.removeBackgroundProgress(gpa, id);
        var e: Entry = .{ .kind = .background, .run = .failed, .open = t.expanded };
        errdefer e.deinit(gpa);
        try e.label.print(gpa, "bg {s} {s} · lost", .{ @tagName(kind), id });
        try e.text.appendSlice(gpa, result);
        try t.entries.append(gpa, e);
    }

    fn removeBackgroundProgress(t: *Transcript, gpa: std.mem.Allocator, id: []const u8) !void {
        for (t.entries.items) |*e| {
            if (e.kind != .run) continue;
            var i: usize = 0;
            while (i < e.agents.items.len) {
                if (e.agents.items[i].background_id) |background_id| {
                    if (std.mem.eql(u8, background_id, id)) {
                        var removed = e.agents.orderedRemove(i);
                        removed.deinit(gpa);
                        try e.refreshAgents(gpa);
                        try e.refreshLabel(gpa);
                        e.cached = null;
                        continue;
                    }
                }
                i += 1;
            }
        }
    }

    pub fn clearBackgroundProgress(t: *Transcript, gpa: std.mem.Allocator) !void {
        for (t.entries.items) |*e| {
            if (e.kind != .run) continue;
            var changed = false;
            var i: usize = 0;
            while (i < e.agents.items.len) {
                if (e.agents.items[i].background_id == null) {
                    i += 1;
                } else {
                    var removed = e.agents.orderedRemove(i);
                    removed.deinit(gpa);
                    changed = true;
                }
            }
            if (changed) {
                try e.refreshAgents(gpa);
                try e.refreshLabel(gpa);
                e.cached = null;
            }
        }
    }

    pub fn userInserted(t: *Transcript, id: u64) void {
        for (t.entries.items) |*e| {
            if (e.queued == id) {
                e.queued = null;
                e.cached = null;
                return;
            }
        }
    }

    pub fn removeQueued(t: *Transcript, gpa: std.mem.Allocator) void {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (t.entries.items[i].queued != null) {
                var entry = t.entries.orderedRemove(i);
                entry.deinit(gpa);
            }
        }
    }

    pub fn toggleExpanded(t: *Transcript) void {
        t.expanded = !t.expanded;
        for (t.entries.items) |*e| if (e.collapsible()) {
            e.open = t.expanded;
        };
    }

    pub fn lastAnswer(t: *const Transcript) ?[]const u8 {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (t.entries.items[i].kind == .assistant) return t.entries.items[i].text.items;
        }
        return null;
    }

    pub fn appendDelta(t: *Transcript, gpa: std.mem.Allocator, kind: provider.Kind, text: []const u8) !void {
        if (kind == .reasoning) return;
        const entry_kind: Kind = .assistant;
        const items = t.entries.items;
        if (items.len == 0 or items[items.len - 1].kind != entry_kind) try t.entries.append(gpa, .{ .kind = entry_kind, .open = t.expanded });
        const current = &t.entries.items[t.entries.items.len - 1];
        try current.text.appendSlice(gpa, text);
    }

    pub fn startRun(t: *Transcript, gpa: std.mem.Allocator, code: []const u8) !void {
        try t.startRunWithEffort(gpa, code, null);
    }

    pub fn startRunWithEffort(t: *Transcript, gpa: std.mem.Allocator, code: []const u8, effort: ?provider.StepEffort) !void {
        try t.addRun(gpa, code, t.expanded, effort);
        t.next_run += 1;
        t.entries.items[t.entries.items.len - 1].run_number = t.next_run;
    }

    pub fn progress(t: *Transcript, gpa: std.mem.Allocator, p: Progress) !void {
        const e = if (p.run == 0) t.lastRunning() orelse return else for (t.entries.items) |*entry| {
            if (entry.kind == .run and entry.run_number == p.run and (entry.run == .running or p.background_id != null)) break entry;
        } else return;
        var copy = try p.clone(gpa);
        var transferred = false;
        errdefer if (!transferred) copy.deinit(gpa);
        var index: usize = 0;
        while (index < e.agents.items.len and e.agents.items[index].agent < p.agent) : (index += 1) {}
        if (index < e.agents.items.len and e.agents.items[index].agent == p.agent) {
            e.agents.items[index].deinit(gpa);
            e.agents.items[index] = copy;
        } else try e.agents.insert(gpa, index, copy);
        transferred = true;
        try e.refreshAgents(gpa);
        try e.refreshLabel(gpa);
        e.cached = null;
    }

    /// Takes ownership of `changes`.
    pub fn endRun(t: *Transcript, gpa: std.mem.Allocator, ok: bool, output: []const u8, elapsed_ms: u64, changes: ChangeText) !void {
        const e = t.lastRunning() orelse {
            var c = changes;
            c.deinit(gpa);
            return;
        };
        e.run = if (ok) .ok else .failed;
        e.elapsed_ms = elapsed_ms;
        var i: usize = 0;
        while (i < e.agents.items.len) {
            if (e.agents.items[i].background_id != null) {
                i += 1;
            } else {
                var removed = e.agents.orderedRemove(i);
                removed.deinit(gpa);
            }
        }
        try e.refreshAgents(gpa);
        e.changes.deinit(gpa);
        e.changes = changes;
        try appendHead(gpa, &e.output, output, run_output_lines);
        try e.refreshLabel(gpa);
        e.cached = null;
    }

    pub fn addHistory(t: *Transcript, gpa: std.mem.Allocator, history: []const provider.Message) !void {
        for (history) |m| {
            const content = m.content orelse "";
            if (m.source == .background) {
                const kind = m.background_kind orelse .agent;
                if (std.mem.startsWith(u8, content, "[background ") and std.mem.indexOf(u8, content, " lost:") != null) {
                    try t.lostBackground(gpa, kind, m.background_id orelse "?", content);
                    continue;
                }
                const result = if (std.mem.indexOfScalar(u8, content, '\n')) |nl| content[nl + 1 ..] else content;
                const Result = struct { ok: ?bool = null, exit_code: ?i64 = null };
                const parsed = std.json.parseFromSlice(Result, gpa, result, .{ .ignore_unknown_fields = true }) catch null;
                defer if (parsed) |value| value.deinit();
                const parsed_ok = if (parsed) |value| (if (kind == .agent) value.value.ok orelse false else value.value.exit_code != null and value.value.exit_code.? == 0) else false;
                try t.backgroundResult(gpa, kind, m.background_id orelse "?", m.background_ok orelse parsed_ok, result);
            } else if (std.mem.eql(u8, m.role, "user")) {
                try t.add(gpa, .user, content);
            } else if (std.mem.eql(u8, m.role, "assistant")) {
                if (content.len > 0) try t.add(gpa, .assistant, content);
                for (m.tool_calls orelse &.{}) |call| {
                    const Args = struct { code: []const u8 = "" };
                    const args = std.json.parseFromSlice(Args, gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch continue;
                    defer args.deinit();
                    try t.addRun(gpa, args.value.code, false, m.step_effort);
                }
            } else if (std.mem.eql(u8, m.role, "tool")) {
                if (t.lastRunning()) |e| {
                    e.run = .ok;
                    try appendHead(gpa, &e.output, content, run_output_lines);
                    try e.refreshLabel(gpa);
                }
            }
        }
    }

    fn addRun(t: *Transcript, gpa: std.mem.Allocator, code: []const u8, open: bool, effort: ?provider.StepEffort) !void {
        var e: Entry = .{ .kind = .run, .open = open };
        errdefer e.deinit(gpa);
        if (effort) |value| e.step_effort = .{ .effort = try gpa.dupe(u8, value.effort), .source = value.source };
        try e.text.appendSlice(gpa, std.mem.trim(u8, code, "\n"));
        try e.refreshLabel(gpa);
        try t.entries.append(gpa, e);
    }

    fn lastRunning(t: *Transcript) ?*Entry {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &t.entries.items[i];
            if (e.kind == .run and e.run == .running) return e;
        }
        return null;
    }
};

/// What a Run changed, as shown: the one-line summary and the colored diff.
pub const ChangeText = struct {
    /// "src/a.zig +3 −1", or "4 files +20 −5"; empty when nothing changed.
    summary: []u8 = &.{},
    /// Per file a header line, then its diff lines; at most `max_diff_lines` in all.
    diff: []u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, changes: []const Change) !ChangeText {
        if (changes.len == 0) return .{};
        var summary: std.ArrayList(u8) = .empty;
        errdefer summary.deinit(gpa);
        if (changes.len <= 2) {
            for (changes, 0..) |c, i| {
                if (i > 0) try summary.appendSlice(gpa, ", ");
                try summary.print(gpa, "{s}{s} +{d} −{d}", .{ c.path, if (c.created) " (new)" else "", c.added, c.removed });
            }
        } else {
            var added: usize = 0;
            var removed: usize = 0;
            for (changes) |c| {
                added += c.added;
                removed += c.removed;
            }
            try summary.print(gpa, "{d} files +{d} −{d}", .{ changes.len, added, removed });
        }
        var diff: std.ArrayList(u8) = .empty;
        errdefer diff.deinit(gpa);
        var shown: usize = 0;
        var hidden: usize = 0;
        for (changes) |c| {
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, c.diff, "\n"), '\n');
            if (shown < max_diff_lines) {
                try diff.print(gpa, "{s}{s} +{d} −{d}\n", .{ c.path, if (c.created) " (new)" else "", c.added, c.removed });
                shown += 1;
            } else hidden += 1;
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (shown < max_diff_lines) {
                    try diff.print(gpa, "{s}\n", .{line});
                    shown += 1;
                } else hidden += 1;
            }
        }
        if (hidden > 0) try diff.print(gpa, "… {d} more lines\n", .{hidden});
        return .{ .summary = try summary.toOwnedSlice(gpa), .diff = try diff.toOwnedSlice(gpa) };
    }

    pub fn deinit(c: *ChangeText, gpa: std.mem.Allocator) void {
        gpa.free(c.summary);
        gpa.free(c.diff);
        c.* = .{};
    }
};

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

/// "bash ×2, read" from the `tools.<name>(` calls in a script.
fn toolSummary(code: []const u8, buf: []u8) []const u8 {
    var names: [8][]const u8 = undefined;
    var counts: [8]u32 = undefined;
    var n: usize = 0;
    var rest = code;
    while (std.mem.indexOf(u8, rest, "tools.")) |i| {
        rest = rest[i + 6 ..];
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
        if (end == 0) continue;
        const name = rest[0..end];
        for (names[0..n], counts[0..n]) |known, *count| {
            if (std.mem.eql(u8, known, name)) {
                count.* += 1;
                break;
            }
        } else if (n < names.len) {
            names[n] = name;
            counts[n] = 1;
            n += 1;
        }
    }
    if (n == 0) return "js";
    var w: std.Io.Writer = .fixed(buf);
    for (names[0..n], counts[0..n], 0..) |name, count, i| {
        if (i > 0) w.writeAll(", ") catch break;
        w.writeAll(name) catch break;
        if (count > 1) w.print(" ×{d}", .{count}) catch break;
    }
    return w.buffered();
}

const testing = std.testing;

test "background results fold to an id and text summary and expand to complete JSON" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const result = "{\"ok\":true,\"text\":\"found it\\nsecond line\",\"changes\":[],\"usage\":{}}";
    try t.backgroundResult(gpa, .agent, "bg_1", true, result);
    const e = &t.entries.items[0];
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expect(e.collapsible());
    try testing.expectEqual(@as(usize, 2), e.segments(&segs).len);
    try testing.expectEqualStrings("bg agent bg_1 · ok=true · found it second line", segs[1].text);
    t.toggleExpanded();
    try testing.expectEqual(@as(usize, 4), e.segments(&segs).len);
    try testing.expectEqualStrings(result, segs[3].text);
    try testing.expect(t.lastAnswer() == null);
    try t.backgroundResult(gpa, .agent, "bg_2", false, "{\"ok\":false,\"text\":\"failed\"}");
    try testing.expect(t.entries.items[1].open);
    try testing.expectEqualStrings("✗ ", t.entries.items[1].segments(&segs)[0].text);
}

test "restored background results retain their kind and complete result" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const result = "{\"ok\":true,\"text\":\"result\"}";
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "background agent bg_1 finished\n" ++ result, .source = .background, .background_kind = .agent, .background_id = "bg_1" }});
    try testing.expectEqual(Kind.background, t.entries.items[0].kind);
    try testing.expectEqualStrings(result, t.entries.items[0].text.items);
    try testing.expectEqualStrings("bg agent bg_1 · ok=true · result", t.entries.items[0].label.items);
}

test "background progress stays with its Run until the matching result arrives" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.agent({})");
    try t.progress(gpa, .{ .agent = 7, .run = 1, .prompt = "first", .background_id = "a1", .step = 1 });
    try t.endRun(gpa, true, "started", 100, .{});
    try t.startRun(gpa, "tools.read({})");
    try t.progress(gpa, .{ .agent = 7, .run = 1, .prompt = "first", .background_id = "a1", .step = 2 });
    try testing.expectEqual(@as(usize, 1), t.entries.items[0].agents.items.len);
    try testing.expectEqual(@as(u32, 2), t.entries.items[0].agents.items[0].step);
    try testing.expectEqual(@as(usize, 0), t.entries.items[1].agents.items.len);
    try testing.expect(std.mem.indexOf(u8, t.entries.items[0].label.items, "background") != null);
    try t.backgroundResult(gpa, .agent, "a1", true, "{\"ok\":true,\"text\":\"done\"}");
    try testing.expectEqual(@as(usize, 0), t.entries.items[0].agents.items.len);
    try testing.expectEqualStrings("agent · 0.1s", t.entries.items[0].label.items);
    try testing.expectEqual(Kind.background, t.entries.items[2].kind);
}

test "turn cleanup removes background working rows without removing delivered results" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.bash({})");
    try t.progress(gpa, .{ .agent = 1, .run = 1, .kind = .bash, .background_id = "b1", .prompt = "sleep 60" });
    try t.progress(gpa, .{ .agent = 2, .run = 1, .kind = .bash, .background_id = "b2", .prompt = "echo done" });
    try t.endRun(gpa, true, "started", 100, .{});
    try t.backgroundResult(gpa, .bash, "b2", true, "{\"exit_code\":0,\"output\":\"done\"}");
    try testing.expectEqual(@as(usize, 1), t.entries.items[0].agents.items.len);
    try t.clearBackgroundProgress(gpa);
    try testing.expectEqual(@as(usize, 0), t.entries.items[0].agents.items.len);
    try testing.expectEqualStrings("bash · 0.1s", t.entries.items[0].label.items);
    try testing.expectEqualStrings("bg bash b2 · ok=true · done", t.entries.items[1].label.items);
}

test "truncated background result still previews text and lost result is visible" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.backgroundResult(gpa, .agent, "a1", false, "{\"ok\":false,\"text\":\"partial result");
    try testing.expectEqualStrings("bg agent a1 · ok=false · partial result", t.entries.items[0].label.items);
    try t.lostBackground(gpa, .agent, "a2", "[background agent a2 lost: process ended]");
    try testing.expectEqualStrings("bg agent a2 · lost", t.entries.items[1].label.items);
    try testing.expectEqualStrings("[background agent a2 lost: process ended]", t.entries.items[1].text.items);
}

test "background bash shows command and elapsed time until its result arrives" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.bash({})");
    try t.progress(gpa, .{ .agent = 3, .run = 1, .kind = .bash, .background_id = "b1", .prompt = "sleep 2\necho done", .elapsed_ms = 1200 });
    try t.endRun(gpa, true, "started", 100, .{});
    try testing.expectEqualStrings("bash · background · sleep 2 echo done · 1.2s · working", t.entries.items[0].label.items);
    t.toggleExpanded();
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("#3 bash sleep 2 echo done · 1.2s · working", t.entries.items[0].segments(&segs)[6].text);
    try t.backgroundResult(gpa, .bash, "b1", true, "{\"exit_code\":0,\"output\":\"done\\n\"}");
    try testing.expectEqual(@as(usize, 0), t.entries.items[0].agents.items.len);
    try testing.expectEqualStrings("bg bash b1 · ok=true · done ", t.entries.items[1].label.items);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"done\\n\"}", t.entries.items[1].segments(&segs)[3].text);
}

test "restored background bash uses its persisted kind" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b1 finished]\n{\"exit_code\":0,\"output\":\"ready\"}", .source = .background, .background_kind = .bash, .background_id = "b1" }});
    try testing.expectEqualStrings("bg bash b1 · ok=true · ready", t.entries.items[0].label.items);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b2 finished]\n{\"exit_code\":1,\"output\":\"failed\"}", .source = .background, .background_kind = .bash, .background_id = "b2" }});
    try testing.expectEqualStrings("bg bash b2 · ok=false · failed", t.entries.items[1].label.items);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b3 finished]\n{\"output\":\"partial", .source = .background, .background_kind = .bash, .background_id = "b3", .background_ok = true }});
    try testing.expectEqualStrings("bg bash b3 · ok=true · partial", t.entries.items[2].label.items);
}

test "runs fold to one line until expanded" {
    const gpa = testing.allocator;
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 24, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "const a = await tools.bash({});\nconst b = await tools.bash({});\nawait tools.read({})");
    try t.endRun(gpa, true, "line 1\nline 2", 1234, .{});
    const e = &t.entries.items[0];
    try testing.expectEqual(@as(u16, 1), e.height(win));
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("bash ×2, read · 1.2s", e.segments(&segs)[2].text);
    t.toggleExpanded();
    try testing.expectEqual(@as(u16, 6), e.height(win));
}

test "toolSummary" {
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("js", toolSummary("1 + 1", &buf));
    try testing.expectEqualStrings("agent ×2", toolSummary("Promise.all([tools.agent({}), tools.agent({})])", &buf));
}

test "entry height cache reuses measurements and invalidates on width or append" {
    const gpa = testing.allocator;
    var screen: vaxis.Screen = .{};
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 24, .screen = &screen };
    var e: Entry = .{ .kind = .assistant };
    defer e.text.deinit(gpa);
    try e.text.appendSlice(gpa, "1234567890");
    try testing.expectEqual(@as(u16, 1), e.height(win));
    e.cached.?.rows = 123;
    try testing.expectEqual(@as(u16, 123), e.height(win));
    win.width = 5;
    try testing.expectEqual(@as(u16, 2), e.height(win));
    try e.text.appendSlice(gpa, "12345");
    try testing.expectEqual(@as(u16, 3), e.height(win));
}

test "thinking stays hidden in streamed and restored transcripts" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.appendDelta(gpa, .reasoning, "think");
    try testing.expectEqual(@as(usize, 0), t.entries.items.len);
    try t.appendDelta(gpa, .text, "an");
    try t.appendDelta(gpa, .reasoning, "more thinking");
    try t.appendDelta(gpa, .text, "swer");
    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try testing.expectEqualStrings("answer", t.lastAnswer().?);

    t.clear(gpa);
    try t.addHistory(gpa, &.{
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .reasoning = .{ .provider = .chat_completions, .data = "hidden thinking" }, .tool_calls = &.{.{ .id = "1", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.bash({})\"}" } }} },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
        .{ .role = "assistant", .content = "answer", .reasoning = .{ .provider = .codex, .data = "[{\"summary\":[{\"text\":\"hidden summary\"}]}]" } },
    });
    try testing.expectEqual(@as(usize, 3), t.entries.items.len);
    try testing.expectEqualStrings("answer", t.lastAnswer().?);
    try testing.expectEqualStrings("out", t.entries.items[1].output.items);
    try testing.expect(t.entries.items[1].run == .ok);
}

test "a Run shows changed files in its summary and a colored diff when open" {
    const gpa = testing.allocator;
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 24, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.edit({})");
    const changes = [_]Change{
        .{ .path = "src/a.zig", .added = 1, .removed = 1, .diff = " keep\n-old\n+new\n" },
        .{ .path = "b.md", .added = 1, .removed = 0, .created = true, .diff = "+hi\n" },
    };
    try t.endRun(gpa, true, "", 300, try .init(gpa, &changes));
    const e = &t.entries.items[0];
    try testing.expectEqualStrings("edit · 0.3s · src/a.zig +1 −1, b.md (new) +1 −0", e.label.items);
    try testing.expectEqual(@as(u16, 1), e.height(win));
    t.toggleExpanded();
    var segs: [max_segments]vaxis.Segment = undefined;
    const shown = e.segments(&segs);
    try testing.expectEqualStrings("-old\n", shown[8].text);
    try testing.expectEqual(@as(u8, 1), shown[8].style.fg.index);
    try testing.expectEqualStrings("+hi", shown[11].text);
    try testing.expectEqual(@as(u16, 8), e.height(win));

    var many: [3]Change = undefined;
    for (&many) |*c| c.* = .{ .path = "x", .added = 2, .removed = 1, .diff = "" };
    var text: ChangeText = try .init(gpa, &many);
    defer text.deinit(gpa);
    try testing.expectEqualStrings("3 files +6 −3", text.summary);
}

fn appendAction(gpa: std.mem.Allocator, out: *std.ArrayList(u8), p: Progress) !void {
    if (p.tools.len == 0 and p.files.len == 0) return;
    try out.appendSlice(gpa, " · ");
    for (p.tools, 0..) |name, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, name);
    }
    for (p.files, 0..) |path, i| {
        if (i > 0) try out.appendSlice(gpa, ", ") else if (p.tools.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, path);
    }
}

fn appendTokens(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tokens: u64) !void {
    if (tokens >= 1000) {
        try out.print(gpa, " · {d}k tok", .{tokens / 1000});
    } else try out.print(gpa, " · {d} tok", .{tokens});
}

fn promptPrefix(prompt: []const u8) []const u8 {
    var end: usize = 0;
    var count: usize = 0;
    while (end < prompt.len and count < 40) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(prompt[end]) catch 1;
        end = @min(prompt.len, end + len);
    }
    return prompt[0..end];
}

fn appendPreview(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (promptPrefix(value)) |byte| try out.append(gpa, if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte);
}

test "running agent folds to progress and expands to child details until Run ends" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.agent({prompt: 'fix it'})");
    try t.progress(gpa, .{ .agent = 1, .prompt = "fix it", .step = 3, .tools = &.{"edit"}, .files = &.{"src/x.zig"}, .usage = .{ .prompt_tokens = 41000 } });
    const e = &t.entries.items[0];
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("agent · running · step 3 · edit src/x.zig · 41k tok", e.segments(&segs)[2].text);
    try testing.expectEqualStrings("", e.segments(&segs)[1].text);
    t.toggleExpanded();
    try testing.expectEqualStrings("#1 fix it · working · step 3 · edit src/x.zig", e.segments(&segs)[6].text);
    try t.endRun(gpa, true, "done", 1234, .{});
    try testing.expectEqualStrings("agent · 1.2s", e.segments(&segs)[2].text);
    try testing.expectEqualStrings("run ", e.segments(&segs)[1].text);
    try testing.expectEqualStrings("done", e.segments(&segs)[6].text);
    try t.progress(gpa, .{ .agent = 1, .prompt = "late" });
    try testing.expectEqualStrings("agent · 1.2s", e.label.items);
}

test "multiple child progress is sorted, replaced and summed without double counting cache" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await Promise.all([tools.agent({}), tools.agent({}), tools.agent({})])");
    try t.progress(gpa, .{ .agent = 3, .prompt = "third", .step = 1, .usage = .{ .prompt_tokens = 40000 } });
    try t.progress(gpa, .{ .agent = 1, .prompt = "first", .step = 2, .state = .done, .tools = &.{"read"}, .usage = .{ .prompt_tokens = 39000, .completion_tokens = 1000, .prompt_cache_hit_tokens = 39000 } });
    try t.progress(gpa, .{ .agent = 2, .prompt = "second", .step = 3, .tools = &.{"edit"}, .files = &.{"a.zig"}, .usage = .{ .prompt_tokens = 40000 } });
    const e = &t.entries.items[0];
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("agent ×3 · running · 2 working, 1 done · 120k tok", e.segments(&segs)[2].text);
    t.toggleExpanded();
    try testing.expectEqualStrings("#1 first · done · step 2 · read\n#2 second · working · step 3 · edit a.zig\n#3 third · working · step 1", e.segments(&segs)[6].text);
    try t.progress(gpa, .{ .agent = 3, .prompt = "third", .state = .timed_out, .step = 1, .usage = .{ .prompt_tokens = 40000 } });
    try testing.expectEqual(@as(usize, 3), e.agents.items.len);
    try testing.expectEqualStrings("agent ×3 · running · 1 working, 1 done, 1 failed · 120k tok", e.label.items);
    try t.endRun(gpa, true, "out", 9000, .{});
    try testing.expectEqualStrings("agent ×3 · 9.0s", e.label.items);
}

test "child prompt preview uses forty Unicode characters and one logical line" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.agent({})");
    const prompt = "中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中" ++ "\nnot shown";
    try t.progress(gpa, .{ .agent = 1, .prompt = prompt, .state = .queued });
    const e = &t.entries.items[0];
    try testing.expectEqualStrings("#1 " ++ "中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中" ++ "  · queued · step 0", e.agent_lines.items);
    e.cached = .{ .width = 80, .len = e.text.items.len, .open = false, .rows = 10 };
    try t.progress(gpa, .{ .agent = 1, .prompt = prompt, .state = .working });
    try testing.expect(e.cached == null);
}

test "long user messages fold live and replayed, truncate the first line, and expand" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 30, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 30, .height = 12, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const raw = "a very long first line that must be clipped\n2\n3\n4\n5\n6";
    try t.add(gpa, .user, raw);
    var e = &t.entries.items[0];
    try testing.expectEqual(@as(u16, 1), e.height(win));
    _ = e.print(win, true);
    try testing.expectEqualStrings("s", screen.readCell(29, 0).?.char.grapheme);
    try testing.expect(screen.readCell(29, 0).?.style.dim);
    t.toggleExpanded();
    try testing.expect(e.height(win) > 5);
    t.clear(gpa);
    t.expanded = false;
    try t.addHistory(gpa, &.{.{ .role = "user", .content = raw }});
    e = &t.entries.items[0];
    try testing.expectEqual(@as(u16, 1), e.height(win));
    t.toggleExpanded();
    try testing.expect(e.height(win) > 5);
    try t.add(gpa, .user, raw);
    try testing.expect(t.entries.items[1].open);
    t.toggleExpanded();
    try testing.expectEqual(@as(u16, 1), t.entries.items[1].height(win));
    const long = try gpa.alloc(u8, 801);
    defer gpa.free(long);
    @memset(long, 'x');
    try t.add(gpa, .user, long);
    try testing.expectEqual(@as(u16, 1), t.entries.items[2].height(win));
    try t.add(gpa, .user, long[0..800]);
    try testing.expect(t.entries.items[3].height(win) > 1);
}

test "bills stay dim and one row when resized or expanded" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 120, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 3, .screen = &screen };
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);
    var text: bill.Text = .{};
    const full = text.format(.{ .steps = 12, .timing = .{ .wall_ms = 190_000, .llm_calls = 8, .agent_calls = 1 } }, 120);
    try transcript.add(gpa, .bill, full);
    const entry = &transcript.entries.items[0];
    for ([_]u16{ 120, 40, 8, 1, 0, 120 }) |width| {
        win.width = width;
        win.clear();
        transcript.toggleExpanded();
        try testing.expectEqual(@as(u16, 1), entry.height(win));
        try testing.expectEqual(@as(u16, 1), entry.print(win, true));
        const expected = bill.fit(full, width);
        var col: u16 = 0;
        var it = std.unicode.Utf8View.initUnchecked(expected).iterator();
        while (it.nextCodepointSlice()) |cp| : (col += 1) {
            const cell = screen.readCell(col, 0).?;
            try testing.expectEqualStrings(cp, cell.char.grapheme);
            try testing.expect(cell.style.dim);
        }
        for (0..120) |x| try testing.expectEqualStrings(" ", screen.readCell(@intCast(x), 1).?.char.grapheme);
    }
}

test "queued users have a dim marker until their insertion event" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.add(gpa, .user, "first");
    t.entries.items[0].queued = 1;
    try t.add(gpa, .user, "second");
    t.entries.items[1].queued = 2;
    var segs: [max_segments]vaxis.Segment = undefined;
    const queued = t.entries.items[0].segments(&segs);
    try testing.expectEqualStrings(" · queued", queued[2].text);
    try testing.expect(queued[2].style.dim);
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 24, .screen = &screen };
    _ = t.entries.items[0].height(win);
    t.userInserted(1);
    try testing.expectEqual(@as(?u64, null), t.entries.items[0].queued);
    try testing.expect(t.entries.items[0].cached == null);
    try testing.expectEqual(@as(usize, 2), t.entries.items[0].segments(&segs).len);
    t.removeQueued(gpa);
    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try testing.expectEqualStrings("first", t.entries.items[0].text.items);
}

test "Run summaries retain their generating Step effort while running and done" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    for ([_]provider.StepEffort{
        .{ .effort = "low", .source = .model },
        .{ .effort = "high", .source = .default },
        .{ .effort = "high", .source = .guard },
        .{ .effort = "default", .source = .default },
    }) |effort| {
        try t.startRunWithEffort(gpa, "tools.edit({})", effort);
        const e = &t.entries.items[t.entries.items.len - 1];
        const suffix = try std.fmt.allocPrint(gpa, " · {s}{s}", .{ effort.effort, if (effort.source == .guard) " (guard)" else "" });
        defer gpa.free(suffix);
        try testing.expect(std.mem.endsWith(u8, e.label.items, suffix));
        try testing.expect(std.mem.indexOf(u8, e.label.items, "running") != null);
        try t.endRun(gpa, effort.source != .guard, "output", 1234, .{ .summary = try gpa.dupe(u8, "a.zig +1 −0") });
        try testing.expect(std.mem.endsWith(u8, e.label.items, suffix));
        try testing.expect(std.mem.indexOf(u8, e.label.items, "a.zig +1 −0") != null);
    }
}

test "history Run effort is copied from assistant metadata and absent in legacy history" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    var effort = [_]u8{ 'h', 'i', 'g', 'h' };
    const calls: []const provider.ToolCall = &.{.{ .id = "1", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.bash({})\"}" } }};
    try t.addHistory(gpa, &.{
        .{ .role = "assistant", .tool_calls = calls, .step_effort = .{ .effort = &effort, .source = .guard } },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
        .{ .role = "assistant", .tool_calls = calls },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
    });
    effort[0] = 'x';
    try t.entries.items[0].refreshLabel(gpa);
    try testing.expectEqualStrings("bash · 0.0s · high (guard)", t.entries.items[0].label.items);
    try testing.expectEqualStrings("bash · 0.0s", t.entries.items[1].label.items);
}
