const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../provider.zig");
const markdown = @import("markdown.zig");
const Change = @import("../tools/diff.zig").Change;

const run_output_lines = 12;
const max_diff_lines = 60;
const max_segments = 8 + max_diff_lines + 2;

pub const Kind = enum { user, assistant, reasoning, run, info, err };

pub const Entry = struct {
    kind: Kind,
    /// For `.run`: the script.
    text: std.ArrayList(u8) = .empty,
    /// For `.run`: the first lines of its output.
    output: std.ArrayList(u8) = .empty,
    /// For `.run`: see `ChangeText`.
    changes: ChangeText = .{},
    /// One-line summary of a collapsible entry. vaxis keeps printed slices
    /// until render, so this must outlive draw(); see `refreshLabel`.
    label: std.ArrayList(u8) = .empty,
    run: enum { running, ok, failed } = .running,
    elapsed_ms: u64 = 0,
    /// Collapsible kinds (`.run`, `.reasoning`) show one summary line unless open.
    open: bool = false,
    cached: ?struct { width: u16, len: usize, open: bool, rows: u16 } = null,

    pub fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        e.text.deinit(gpa);
        e.output.deinit(gpa);
        e.label.deinit(gpa);
        e.changes.deinit(gpa);
    }

    fn refreshLabel(e: *Entry, gpa: std.mem.Allocator) !void {
        e.label.clearRetainingCapacity();
        switch (e.kind) {
            .run => {
                var buf: [96]u8 = undefined;
                const used = toolSummary(e.text.items, &buf);
                if (e.run == .running) {
                    try e.label.print(gpa, "{s} · running", .{used});
                } else {
                    try e.label.print(gpa, "{s} · {d}.{d}s", .{ used, e.elapsed_ms / 1000, e.elapsed_ms % 1000 / 100 });
                }
                if (e.changes.summary.len > 0) try e.label.print(gpa, " · {s}", .{e.changes.summary});
            },
            .reasoning => {
                const lines = std.mem.count(u8, std.mem.trimEnd(u8, e.text.items, "\n"), "\n") + 1;
                try e.label.print(gpa, "∴ thinking · {d} line{s} · ctrl+o to expand", .{ lines, if (lines == 1) "" else "s" });
            },
            else => {},
        }
    }

    fn collapsible(e: *const Entry) bool {
        return e.kind == .run or e.kind == .reasoning;
    }

    pub fn print(e: *const Entry, win: vaxis.Window, commit: bool) u16 {
        if (e.kind == .assistant) return markdown.print(win, e.text.items, commit);
        var segs: [max_segments]vaxis.Segment = undefined;
        const folded = e.collapsible() and !e.open;
        const wrap: @FieldType(vaxis.Window.PrintOptions, "wrap") = if (folded) .none else if (e.kind == .run) .grapheme else .word;
        const r = win.print(segments(e, &segs), .{ .wrap = wrap, .commit = commit });
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
                segs[1] = .{ .text = e.text.items, .style = .{ .bold = true } };
                return segs[0..2];
            },
            .assistant => segs[0] = .{ .text = e.text.items },
            .reasoning => {
                segs[0] = .{ .text = if (e.open) e.text.items else e.label.items, .style = .{ .dim = true, .italic = true } };
            },
            .run => {
                segs[0] = switch (e.run) {
                    .running => .{ .text = "◌ ", .style = .{ .fg = .{ .index = 3 } } },
                    .ok => .{ .text = "✓ ", .style = .{ .fg = .{ .index = 2 } } },
                    .failed => .{ .text = "✗ ", .style = .{ .fg = .{ .index = 1 } } },
                };
                segs[1] = .{ .text = "run ", .style = .{ .fg = .{ .index = 3 }, .bold = true } };
                segs[2] = .{ .text = e.label.items, .style = dim };
                if (!e.open) return segs[0..3];
                segs[3] = .{ .text = "\n" };
                segs[4] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 3 } } };
                var n: usize = 5;
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
            .info => segs[0] = .{ .text = e.text.items, .style = dim },
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

    pub fn deinit(t: *Transcript, gpa: std.mem.Allocator) void {
        t.clear(gpa);
        t.entries.deinit(gpa);
    }

    pub fn clear(t: *Transcript, gpa: std.mem.Allocator) void {
        for (t.entries.items) |*e| e.deinit(gpa);
        t.entries.clearRetainingCapacity();
    }

    pub fn add(t: *Transcript, gpa: std.mem.Allocator, kind: Kind, text: []const u8) !void {
        var e: Entry = .{ .kind = kind };
        try e.text.appendSlice(gpa, text);
        try t.entries.append(gpa, e);
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
        const entry_kind: Kind = if (kind == .reasoning) .reasoning else .assistant;
        const items = t.entries.items;
        if (items.len == 0 or items[items.len - 1].kind != entry_kind) try t.entries.append(gpa, .{ .kind = entry_kind, .open = t.expanded });
        const current = &t.entries.items[t.entries.items.len - 1];
        try current.text.appendSlice(gpa, text);
        if (entry_kind == .reasoning) try current.refreshLabel(gpa);
    }

    pub fn startRun(t: *Transcript, gpa: std.mem.Allocator, code: []const u8) !void {
        try t.addRun(gpa, code, t.expanded);
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
        e.changes.deinit(gpa);
        e.changes = changes;
        try appendHead(gpa, &e.output, output, run_output_lines);
        try e.refreshLabel(gpa);
        e.cached = null;
    }

    pub fn addHistory(t: *Transcript, gpa: std.mem.Allocator, history: []const provider.Message) !void {
        for (history) |m| {
            const content = m.content orelse "";
            if (std.mem.eql(u8, m.role, "user")) {
                try t.add(gpa, .user, content);
            } else if (std.mem.eql(u8, m.role, "assistant")) {
                if (m.reasoning) |r| {
                    const text = try r.display(gpa);
                    defer gpa.free(text);
                    if (text.len > 0) {
                        try t.add(gpa, .reasoning, text);
                        try t.entries.items[t.entries.items.len - 1].refreshLabel(gpa);
                    }
                }
                if (content.len > 0) try t.add(gpa, .assistant, content);
                for (m.tool_calls orelse &.{}) |call| {
                    const Args = struct { code: []const u8 = "" };
                    const args = std.json.parseFromSlice(Args, gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch continue;
                    defer args.deinit();
                    try t.addRun(gpa, args.value.code, false);
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

    fn addRun(t: *Transcript, gpa: std.mem.Allocator, code: []const u8, open: bool) !void {
        var e: Entry = .{ .kind = .run, .open = open };
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

test "streamed deltas group by kind and history replays runs with results" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.appendDelta(gpa, .reasoning, "think");
    try t.appendDelta(gpa, .text, "an");
    try t.appendDelta(gpa, .text, "swer");
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
    try testing.expectEqualStrings("answer", t.lastAnswer().?);

    t.clear(gpa);
    try t.addHistory(gpa, &.{
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .tool_calls = &.{.{ .id = "1", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.bash({})\"}" } }} },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
    });
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
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
