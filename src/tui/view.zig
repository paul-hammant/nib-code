const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../provider.zig");
const commands = @import("commands.zig");
const Editor = @import("editor.zig").Editor;
const Entry = @import("transcript.zig").Entry;
const Transcript = @import("transcript.zig").Transcript;
const Viewport = @import("viewport.zig").Viewport;
const status = @import("status.zig");

pub const Frame = @import("selection/history.zig").Frame;

const max_menu_rows = 11;

pub fn draw(win: vaxis.Window, entries: []Entry, input: *Editor, scroll: *Viewport, menu: []const commands.Candidate, menu_sel: usize, s: status.Status, text: *status.Text) void {
    _ = drawFrame(win, entries, input, scroll, menu, menu_sel, s, text);
}

pub fn drawFrame(outer: vaxis.Window, entries: []Entry, input: *Editor, scroll: *Viewport, menu: []const commands.Candidate, menu_sel: usize, s: status.Status, text: *status.Text) ?Frame {
    outer.clear();
    const width: u16 = if (s.cfg.simple and outer.width > 110) 100 else outer.width;
    const win = outer.child(.{ .x_off = (outer.width - width) / 2, .width = width });
    win.hideCursor();
    for (entries, 0..) |*e, i| {
        if (e.simple != s.cfg.simple) e.cached = null;
        e.simple = s.cfg.simple;
        e.gap = if (s.cfg.simple and e.kind == .bill) @as(u16, @intFromBool(i + 1 < entries.len and entries[i + 1].kind == .user)) else if (s.cfg.simple and i + 1 < entries.len and entries[i + 1].kind == .user) 2 else 1;
    }
    if (win.height == 0 or win.width == 0) return null;

    const separator = s.cfg.simple and win.height >= 2;
    const framed = !s.cfg.simple and win.height >= 6 and win.width >= 8;
    const bottom_space: u16 = @intFromBool((framed or s.cfg.simple) and win.height >= 8);
    const borders: u16 = if (framed) 2 else if (separator) 1 else 0;
    const x: u16 = if (framed) 2 else @min(3, win.width - 1);
    const input_w = win.width - x - @as(u16, if (framed) 2 else 0);
    const input_h = @min(input.rows(win.child(.{ .width = input_w })), @max(1, win.height / 3));
    const saved_scroll = scroll.*;
    var activity_h = activityHeight(s.busy != null or s.background_count > 0 or s.notice != null or s.hint.len > 0 or scroll.top != null or scroll.pending < 0, win.height - input_h - borders - bottom_space, win.height);
    const menu_layout = menuLayout(menu, menu_sel, @min(max_menu_rows, (win.height - input_h - borders - bottom_space - activity_h) / 2));
    const menu_h = menu_layout.rows;
    var body_h = win.height - input_h - borders - bottom_space - menu_h - activity_h;
    var body = win.child(.{ .x_off = @min(1, win.width - 1), .width = @max(1, win.width -| 2), .height = body_h });
    var top = scroll.layout(entries, body);
    scroll.observe(s.revision, saved_scroll.top != null);
    var activity_status = s;
    activity_status.new_output = scroll.new_output;
    const actual_h = activityHeight(text.formatWidth(activity_status, scroll.top != null, win.width -| 2).len > 0, win.height - input_h - borders - bottom_space - menu_h, win.height);
    if (actual_h != activity_h) {
        activity_h = actual_h;
        body_h = win.height - input_h - borders - bottom_space - menu_h - activity_h;
        body.height = body_h;
        scroll.* = saved_scroll;
        top = scroll.layout(entries, body);
        scroll.observe(s.revision, saved_scroll.top != null);
        activity_status.new_output = scroll.new_output;
    }
    var y: i32 = -@as(i32, top.row);
    for (entries[top.entry..], top.entry..) |*e, index| {
        if (y >= body_h) break;
        e.user_bg = s.user_bg;
        const h = e.height(body);
        if (y + h > 0) _ = e.print(body.child(.{ .y_off = @intCast(y), .height = h }), true);
        if (s.hovered == index) {
            const rows = e.toggleRows(body);
            for (0..body_h) |row| {
                if (@as(i32, @intCast(row)) < y or @as(i32, @intCast(row)) >= y + rows) continue;
                for (0..body.width) |col| {
                    const cell = &win.screen.buf[row * win.screen.width + col + @as(usize, @intCast(body.x_off))];
                    cell.style.bg = s.hover_bg;
                    cell.default = false;
                }
            }
        }
        y += e.extent(body);
    }

    if (s.signed_out and entries.len == 0 and body_h > 0) {
        _ = body.printSegment(.{ .text = "No provider · /provider to sign in", .style = .{ .dim = true } }, .{ .wrap = .none });
    }

    if (activity_h > 0) {
        _ = win.child(.{ .x_off = 1, .y_off = body_h + activity_h - 1, .height = 1 }).printSegment(.{ .text = text.formatWidth(activity_status, scroll.top != null, win.width -| 2), .style = s.activityStyle() }, .{ .wrap = .none });
    }
    var menu_y = body_h + activity_h;
    for (menu_layout.first..menu_layout.end) |i| {
        const c = menu[i];
        if (groupHeader(menu, i, menu_layout.first)) |group| {
            _ = win.child(.{ .x_off = 2, .y_off = menu_y, .height = 1 }).printSegment(.{ .text = commands.groupName(group), .style = .{ .bold = true, .dim = true } }, .{ .wrap = .none });
            menu_y += 1;
        }
        const chosen = i == menu_sel;
        const row = win.child(.{ .x_off = 2, .y_off = menu_y, .height = 1 });
        const label_width = if (c.is_path) row.width else if (c.command == .model and c.value != null) row.width -| 16 else if (c.command == .provider and c.value != null) @min(row.width, 14) else @min(row.width, 12);
        printFitted(row.child(.{ .width = label_width }), c.label, if (chosen) .{ .reverse = true, .bold = true } else .{ .bold = true });
        if (row.width > label_width + 2) printFitted(row.child(.{ .x_off = label_width + 2 }), c.detail, .{ .dim = true });
        menu_y += 1;
    }

    const input_y = body_h + activity_h + menu_h;
    if (separator) {
        for (0..win.width) |col| put(win, @intCast(col), input_y, "─");
        const percent = s.context * 100 / @max(s.cfg.context_window, 1);
        if (percent >= 80) {
            const label = std.fmt.bufPrint(&text.status, "context {d}%", .{percent}) catch "";
            const w = win.gwidth(label);
            if (w <= win.width) _ = win.child(.{ .x_off = win.width - w, .y_off = input_y, .height = 1 }).printSegment(.{ .text = label, .style = .{ .dim = true } }, .{ .wrap = .none });
        }
        _ = win.child(.{ .x_off = 1, .y_off = input_y + 1, .height = 1 }).printSegment(.{ .text = "›", .style = .{ .fg = .{ .index = 4 } } }, .{ .wrap = .none });
    } else if (framed) {
        horizontal(win, input_y, "╭", "╮");
        horizontal(win, input_y + input_h + 1, "╰", "╯");
        for (0..input_h) |i| {
            put(win, 0, @intCast(input_y + 1 + i), "│");
            put(win, win.width - 1, @intCast(input_y + 1 + i), "│");
        }
        put(win, 2, input_y + input_h + 1, " ");
        _ = win.child(.{ .x_off = 3, .y_off = input_y + input_h + 1, .width = win.width - 6, .height = 1 }).printSegment(.{ .text = text.footer(s, win.width - 6), .style = .{ .dim = true } }, .{ .wrap = .none });
    } else if (win.width >= 3) {
        _ = win.child(.{ .x_off = 1, .y_off = input_y, .height = 1 }).printSegment(.{ .text = "› ", .style = .{ .fg = .{ .index = 4 } } }, .{ .wrap = .none });
    }
    const placeholder = input.placeholder;
    if (s.cfg.simple) input.placeholder = "";
    defer input.placeholder = placeholder;
    input.draw(win.child(.{ .x_off = x, .y_off = input_y + @as(u16, if (framed or separator) 1 else 0), .width = input_w, .height = input_h }));
    return .{ .top = top, .window = body };
}

fn activityHeight(visible: bool, available: u16, terminal_height: u16) u16 {
    if (!visible or available == 0) return 0;
    return if (terminal_height >= 10 and available >= 4) 2 else 1;
}

const MenuLayout = struct { first: usize = 0, end: usize = 0, rows: u16 = 0 };

fn groupHeader(menu: []const commands.Candidate, index: usize, first: usize) ?commands.Group {
    const group = menu[index].group() orelse return null;
    return if (index == first or menu[index - 1].group() != group) group else null;
}

fn menuLayout(menu: []const commands.Candidate, selected: usize, limit: u16) MenuLayout {
    if (menu.len == 0 or limit == 0) return .{};
    var first: usize = 0;
    while (first < selected) : (first += 1) {
        var needed: usize = 0;
        for (first..selected + 1) |i| needed += 1 + @as(usize, @intFromBool(groupHeader(menu, i, first) != null));
        if (needed <= limit) break;
    }
    var layout: MenuLayout = .{ .first = first, .end = first };
    while (layout.end < menu.len) {
        const rows: u16 = 1 + @as(u16, @intFromBool(groupHeader(menu, layout.end, first) != null));
        if (layout.rows + rows > limit) break;
        layout.rows += rows;
        layout.end += 1;
    }
    return layout;
}

fn printFitted(win: vaxis.Window, text: []const u8, style: vaxis.Style) void {
    const fitted = @import("format.zig").fit(text, win.width);
    _ = win.print(&.{ .{ .text = fitted.text, .style = style }, .{ .text = fitted.suffix, .style = style } }, .{ .wrap = .none });
}

fn put(win: vaxis.Window, x: u16, y: u16, glyph: []const u8) void {
    _ = win.child(.{ .x_off = x, .y_off = y, .width = 1, .height = 1 }).printSegment(.{ .text = glyph, .style = .{ .dim = true } }, .{ .wrap = .none });
}

fn horizontal(win: vaxis.Window, y: u16, left: []const u8, right: []const u8) void {
    put(win, 0, y, left);
    for (1..win.width - 1) |i| put(win, @intCast(i), y, "─");
    put(win, win.width - 1, y, right);
}

const testing = std.testing;
const mock_cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };

test "draw benchmark: 5000 entries" {
    const benchmark = testing.environ.getPosix("NIB_TUI_BENCH") != null;
    const frames: u8 = if (benchmark) 32 else 1;
    const gpa = testing.allocator;
    const entries = try gpa.alloc(Entry, 5000);
    defer gpa.free(entries);
    const sample = "A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. ";
    for (entries) |*e| e.* = .{ .kind = .assistant, .text = .fromOwnedSlice(@constCast(sample)) };
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 24, .screen = &screen };
    var text: status.Text = .{};
    var input: Editor = .{};
    defer input.deinit(gpa);
    for ([_]u32{ 0, 1200 }) |offset| {
        var samples: [5]i96 = undefined;
        for (&samples) |*sample_ns| {
            var scroll: Viewport = .{ .pending = -@as(i64, offset) };
            draw(win, entries, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg }, &text);
            const before = std.Io.Clock.awake.now(testing.io);
            for (0..frames) |_| {
                draw(win, entries, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg }, &text);
            }
            sample_ns.* = @divTrunc(before.untilNow(testing.io, .awake).nanoseconds, frames);
        }
        std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
        if (benchmark) std.debug.print("\nTUI draw: 5000 entries, offset {d}, median {d} ns/frame\n", .{ offset, samples[2] });
        try testing.expect(screen.cursor_vis);
    }
}

test "draw keeps scrolled body fixed while output arrives and caps input height" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 24, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    var paragraph: std.ArrayList(u8) = .empty;
    defer paragraph.deinit(gpa);
    for (0..40) |i| try paragraph.print(gpa, "line {d}\n", .{i});
    try t.add(gpa, .assistant, paragraph.items);
    try t.add(gpa, .assistant, "stream");
    var input: Editor = .{};
    defer input.deinit(gpa);
    var text: status.Text = .{};
    var view: Viewport = .{ .pending = -30 };
    const busy: status.Status = .{ .cfg = mock_cfg, .busy = .{ .phase = .thinking, .ms = 0 } };
    draw(win, t.entries.items, &input, &view, &.{}, 0, busy, &text);
    const body_before = try gpa.dupe(vaxis.Cell, screen.buf[0 .. 19 * 100]);
    defer gpa.free(body_before);
    try t.entries.items[1].text.appendSlice(gpa, "\nmore streamed text");
    try t.add(gpa, .info, "Run output");
    draw(win, t.entries.items, &input, &view, &.{}, 0, busy, &text);
    try testing.expectEqualDeep(body_before, screen.buf[0 .. 19 * 100]);
    for (0..16) |i| try input.buf.print(gpa, "input {d}\n", .{i});
    input.cursor = input.buf.items.len;
    draw(win, t.entries.items, &input, &view, &.{}, 0, busy, &text);
    try testing.expectEqual(@as(u16, 9), input.top_row);
    try testing.expectEqual(@as(u16, 21), screen.cursor.row);
    try testing.expect(screen.cursor_vis);
    try testing.expectEqualStrings("i", screen.readCell(2, 14).?.char.grapheme);
}

fn snapshot(gpa: std.mem.Allocator, screen: *const vaxis.Screen) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..screen.height) |row| {
        const start = out.items.len;
        var col: u16 = 0;
        while (col < screen.width) {
            const cell = screen.readCell(col, @intCast(row)).?;
            try out.appendSlice(gpa, cell.char.grapheme);
            col += @max(1, vaxis.gwidth.gwidth(cell.char.grapheme, screen.width_method));
        }
        while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "layout snapshots: normal, short, tiny, narrow, menu, busy and history" {
    const gpa = testing.allocator;
    const cases = [_]struct { name: []const u8, w: u16 = 80, h: u16 = 12, busy: bool = false, history: bool = false, menu: bool = false, notice: bool = false }{
        .{ .name = "normal" },
        .{ .name = "standard", .w = 80, .h = 24 },
        .{ .name = "large", .w = 120, .h = 40 },
        .{ .name = "compact", .w = 60, .h = 16 },
        .{ .name = "small", .w = 40, .h = 10 },
        .{ .name = "short", .h = 7 },
        .{ .name = "tiny", .h = 4 },
        .{ .name = "narrow", .w = 18 },
        .{ .name = "menu", .menu = true },
        .{ .name = "busy", .busy = true },
        .{ .name = "history", .history = true },
        .{ .name = "notice", .notice = true },
    };
    var images: std.ArrayList(u8) = .empty;
    defer images.deinit(gpa);
    for (cases) |c| {
        var screen = try vaxis.Screen.init(gpa, .{ .cols = c.w, .rows = c.h, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = c.w, .height = c.h, .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(gpa);
        var t: Transcript = .{};
        defer t.deinit(gpa);
        try t.add(gpa, .assistant, if (c.history) "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14" else "Answer");
        var viewport: Viewport = .{ .pending = if (c.history) -100 else 0 };
        var text: status.Text = .{};
        const candidates = [_]commands.Candidate{.{ .command = .help, .label = "/help", .detail = "show help" }};
        draw(win, t.entries.items, &input, &viewport, if (c.menu) &candidates else &.{}, 0, .{ .cfg = mock_cfg, .busy = if (c.busy) .{ .phase = .thinking, .ms = 1200 } else null, .notice = if (c.notice) "copied 3 chars" else null }, &text);
        try testing.expect(screen.cursor_vis);
        try testing.expectEqual(@as(u16, if (c.h >= 8) c.h - 3 else if (c.h >= 6) c.h - 2 else c.h - 1), screen.cursor.row);
        const image = try snapshot(gpa, &screen);
        defer gpa.free(image);
        try images.print(gpa, "--- {s} {d}x{d} ---\n{s}", .{ c.name, c.w, c.h, image });
        if (testing.environ.getPosix("NIB_TUI_SNAPSHOTS") != null) std.debug.print("\n--- {s} {d}x{d} ---\n{s}", .{ c.name, c.w, c.h, image });
        if (c.h >= 8) for (0..c.w) |col| {
            try testing.expectEqualStrings(" ", screen.readCell(@intCast(col), c.h - 1).?.char.grapheme);
        };
        if (c.h >= 6) {
            try testing.expectEqualStrings("╰", screen.readCell(0, if (c.h >= 8) c.h - 2 else c.h - 1).?.char.grapheme);
            try testing.expectEqualStrings("╯", screen.readCell(c.w - 1, if (c.h >= 8) c.h - 2 else c.h - 1).?.char.grapheme);
        } else try testing.expect(std.mem.indexOf(u8, image, "› Ask about this project · / for commands") != null);
        if (c.busy) try testing.expect(std.mem.indexOf(u8, image, "Waiting for model · turn <1s") != null);

        if (c.notice) try testing.expect(std.mem.indexOf(u8, image, "copied 3 chars") != null);
        if (c.menu) try testing.expect(std.mem.indexOf(u8, image, "/help") != null);
    }
    try testing.expectEqualStrings(@embedFile("layout_snapshots.txt"), images.items);
}

test "activity has breathing room at 60, 120 and 160 columns without wasting short terminals" {
    const gpa = testing.allocator;
    for ([_]u16{ 60, 120, 160 }) |width| for ([_]u16{ 7, 9, 12, 32 }) |height| {
        var screen = try vaxis.Screen.init(gpa, .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(gpa);
        var transcript: Transcript = .{};
        defer transcript.deinit(gpa);
        var lines: std.ArrayList(u8) = .empty;
        defer lines.deinit(gpa);
        for (0..40) |i| try lines.print(gpa, "line-{d}\n", .{i});
        try transcript.add(gpa, .assistant, lines.items);
        const states = [_]status.Status{
            .{ .cfg = mock_cfg, .busy = .{ .phase = .scripting, .ms = 0 } },
            .{ .cfg = mock_cfg, .background_count = 1 },
            .{ .cfg = mock_cfg, .notice = "copied 3 chars" },
        };
        for (states) |s| {
            var viewport: Viewport = .{ .pending = 0 };
            var text: status.Text = .{};
            const frame = drawFrame(win, transcript.entries.items, &input, &viewport, &.{}, 0, s, &text).?;
            const status_y = height - @as(u16, if (height >= 8) 5 else 4);
            try testing.expectEqual(status_y - @as(u16, @intFromBool(height >= 10)), frame.window.height);
            if (height >= 10) for (0..width) |col| {
                try testing.expectEqualStrings(" ", screen.readCell(@intCast(col), status_y - 1).?.char.grapheme);
            };
            try testing.expect(!std.mem.eql(u8, " ", screen.readCell(1, status_y).?.char.grapheme));
            try testing.expect(screen.cursor_vis);
            try testing.expectEqual(height - @as(u16, if (height >= 8) 3 else 2), screen.cursor.row);
        }
        var viewport: Viewport = .{};
        var text: status.Text = .{};
        const frame = drawFrame(win, transcript.entries.items, &input, &viewport, &.{}, 0, .{ .cfg = mock_cfg }, &text).?;
        try testing.expectEqual(height - @as(u16, if (height >= 8) 4 else 3), frame.window.height);
    };
}

test "selection copies displayed blocks at the framed input coordinates" {
    const Selection = @import("selection.zig").Selection;
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 60, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 12, .screen = &screen };
    var input: Editor = .{};
    defer input.deinit(gpa);
    try input.insert(gpa, "你");
    try input.paste(gpa, "1\n2\n3\n4\n5\n6");
    var viewport: Viewport = .{};
    var text: status.Text = .{};
    draw(win, &.{}, &input, &viewport, &.{}, 0, .{ .cfg = mock_cfg }, &text);
    try testing.expectEqual(@as(u16, 29), screen.cursor.col);
    try testing.expectEqual(@as(u16, 9), screen.cursor.row);
    var selection: Selection = .{};
    _ = selection.mouse(.{ .col = 28, .row = 9, .type = .press, .button = .left, .mods = .{} }, &screen);
    _ = selection.mouse(.{ .col = 2, .row = 9, .type = .drag, .button = .left, .mods = .{} }, &screen);
    try testing.expect(selection.mouse(.{ .col = 2, .row = 9, .type = .release, .button = .left, .mods = .{} }, &screen));
    const copied = try selection.text(gpa, &screen);
    defer gpa.free(copied);
    try testing.expectEqualStrings("你[Pasted #1 · 6 lines · 1]", copied);
    selection.highlight(&screen);
    try testing.expect(screen.readCell(2, 9).?.style.reverse);
    try testing.expect(!screen.readCell(0, 9).?.style.reverse);
}

test "minimal terminal dimensions retain an input cursor" {
    const gpa = testing.allocator;
    for (1..9) |w| for (1..9) |h| {
        var screen = try vaxis.Screen.init(gpa, .{ .cols = @intCast(w), .rows = @intCast(h), .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = @intCast(w), .height = @intCast(h), .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(gpa);
        var viewport: Viewport = .{};
        var text: status.Text = .{};
        draw(win, &.{}, &input, &viewport, &.{}, 0, .{ .cfg = mock_cfg, .busy = .{ .phase = .thinking, .ms = 0 } }, &text);
        try testing.expect(screen.cursor_vis);
        try testing.expect(screen.cursor.col < w and screen.cursor.row < h);
    };
}

test "grouped menus keep the selected command visible within their row budget" {
    var buf: [16]commands.Candidate = undefined;
    const menu = commands.candidates("/", &.{}, &.{}, &.{}, &.{}, &buf);
    for (2..12) |limit| for (0..menu.len) |selected| {
        const layout = menuLayout(menu, selected, @intCast(limit));
        try testing.expect(layout.rows <= limit);
        try testing.expect(layout.first <= selected and layout.end > selected);
    };
}

test "empty screen has one guidance line and no zero statistics" {
    const a = testing.allocator;
    var screen = try vaxis.Screen.init(a, .{ .cols = 60, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 12, .screen = &screen };
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    draw(win, &.{}, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg }, &text);
    const image = try snapshot(a, &screen);
    defer a.free(image);
    try testing.expect(std.mem.indexOf(u8, image, "Ask about this project · / for commands") != null);
    try testing.expect(std.mem.indexOf(u8, image, "Enter send") == null);
    try testing.expect(std.mem.indexOf(u8, image, "0%") == null);
}

test "model menu shows distinct model names and current marker at common widths" {
    const a = testing.allocator;
    for ([_]u16{ 60, 120, 160 }) |width| {
        var screen = try vaxis.Screen.init(a, .{ .cols = width, .rows = 16, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 16, .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(a);
        var scroll: Viewport = .{};
        var text: status.Text = .{};
        const menu = [_]commands.Candidate{
            .{ .command = .model, .value = "openai/gpt-6.1-sol", .label = "openai · gpt-6.1-sol", .detail = "current" },
            .{ .command = .model, .value = "openai/gpt-6.1-terra", .label = "openai · gpt-6.1-terra", .detail = "" },
        };
        draw(win, &.{}, &input, &scroll, &menu, 0, .{ .cfg = mock_cfg }, &text);
        const rendered = try snapshot(a, &screen);
        defer a.free(rendered);
        try testing.expect(std.mem.indexOf(u8, rendered, "openai · gpt-6.1-sol") != null);
        try testing.expect(std.mem.indexOf(u8, rendered, "openai · gpt-6.1-terra") != null);
        try testing.expect(std.mem.indexOf(u8, rendered, "current") != null);
    }
}

test "stream stress frame timings" {
    const a = testing.allocator;
    var screen = try vaxis.Screen.init(a, .{ .cols = 120, .rows = 32, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 32, .screen = &screen };
    var transcript: Transcript = .{};
    defer transcript.deinit(a);
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    const sample = "English 中文 👩‍💻 🙂 **late bold\n- list `late code\n```zig\n" ++ "const value = 123; // 中文\n" ++ "```\nclose` bold**\n";
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(a);
    while ((std.unicode.utf8CountCodepoints(answer.items) catch 0) < 30000) try answer.appendSlice(a, sample);
    for ([_]usize{ 1000, 10000, 30000 }) |size| {
        transcript.clear(a);
        var it = (try std.unicode.Utf8View.init(answer.items)).iterator();
        var end: usize = 0;
        for (0..size) |_| end += it.nextCodepointSlice().?.len;
        try transcript.add(a, .assistant, answer.items[0..end]);
        var times: [100]i64 = undefined;
        for (&times, 0..) |*elapsed, i| {
            transcript.entries.items[0].cached = null;
            if (i % 2 == 0) try input.insert(a, "x") else try input.insert(a, "y");
            const start = std.Io.Clock.Timestamp.now(testing.io, .awake);
            draw(win, transcript.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg }, &text);
            elapsed.* = @intCast(start.durationTo(.now(testing.io, .awake)).raw.toNanoseconds());
        }
        std.mem.sort(i64, &times, {}, std.sort.asc(i64));
        std.debug.print("stress chars={d} frame p95={d}us max={d}us input-to-draw max={d}us\n", .{ size, @divTrunc(times[94], 1000), @divTrunc(times[99], 1000), @divTrunc(times[99], 1000) });
    }
}

test "hover covers full summary width and leaves expanded details unchanged" {
    const a = testing.allocator;
    var screen = try vaxis.Screen.init(a, .{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 24, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.startRun(a, "console.log('details')");
    const entry = &t.entries.items[0];
    try entry.files.appendSlice(a, "read example.zig");
    entry.open = true;
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    const color: vaxis.Color = .{ .rgb = .{ 8, 8, 8 } };
    const frame = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg, .hovered = 0, .hover_bg = color }, &text).?;
    const rows = entry.toggleRows(frame.window);
    try testing.expect(rows >= 2);
    for (0..rows) |row| for (1..79) |col| {
        try testing.expectEqualDeep(color, screen.readCell(@intCast(col), @intCast(row)).?.style.bg);
    };
    try testing.expect(!std.meta.eql(color, screen.readCell(1, rows).?.style.bg));
}

test "Simple layout snapshots and centered hit testing" {
    const gpa = testing.allocator;
    var images: std.ArrayList(u8) = .empty;
    defer images.deinit(gpa);
    for ([_]struct { w: u16, h: u16 }{ .{ .w = 80, .h = 24 }, .{ .w = 120, .h = 40 }, .{ .w = 160, .h = 50 }, .{ .w = 40, .h = 10 } }) |size| {
        for ([_]bool{ false, true }) |simple| {
            var screen = try vaxis.Screen.init(gpa, .{ .cols = size.w, .rows = size.h, .x_pixel = 0, .y_pixel = 0 });
            defer screen.deinit(gpa);
            const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = size.w, .height = size.h, .screen = &screen };
            var t: Transcript = .{};
            defer t.deinit(gpa);
            try t.add(gpa, .user, "Check the change");
            try t.add(gpa, .assistant, "I will edit and verify it.");
            for (0..2) |_| {
                try t.add(gpa, .run, "await tools.bash({command: 'zig build'});");
                const e = &t.entries.items[t.entries.items.len - 1];
                e.run = .ok;
                try e.refreshLabel(gpa);
            }
            try t.add(gpa, .assistant, "Done.");
            try t.add(gpa, .bill, "2 Runs · 2 steps · 41s · 6.6k tokens");
            try t.add(gpa, .user, "Thanks");
            var input: Editor = .{};
            defer input.deinit(gpa);
            var scroll: Viewport = .{};
            var text: status.Text = .{};
            var cfg = mock_cfg;
            cfg.simple = simple;
            cfg.context_window = 100;
            const frame = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = cfg, .context = 84 }, &text).?;
            const image = try snapshot(gpa, &screen);
            defer gpa.free(image);
            try images.print(gpa, "--- {s} {d}x{d} ---\n{s}", .{ if (simple) "simple" else "normal", size.w, size.h, image });
            try testing.expectEqual(@as(u16, if (simple and size.w > 110) (size.w - 100) / 2 + 1 else 1), frame.window.x_off);
            try testing.expect(std.mem.indexOf(u8, image, "context 84%") != null);
            if (simple) {
                try testing.expect(std.mem.indexOf(u8, image, "╭") == null);
                try testing.expect(std.mem.indexOf(u8, image, "6.6k") == null);
                try testing.expect(std.mem.indexOf(u8, image, "Ask about") == null);
                try testing.expectEqual(@as(u16, 1), t.entries.items[2].height(frame.window));
                const p = @import("selection/history.zig").position(frame, t.entries.items, @intCast(frame.window.x_off + 4), 0).?;
                try testing.expect(p.entry < t.entries.items.len);
            }
            for (0..size.w) |col| try testing.expectEqualStrings(" ", screen.readCell(@intCast(col), size.h - 1).?.char.grapheme);
        }
    }
    if (testing.environ.getPosix("NIB_TUI_SNAPSHOTS") != null) std.debug.print("\nSIMPLE_SNAPSHOTS_BEGIN\n{s}SIMPLE_SNAPSHOTS_END\n", .{images.items});
    try testing.expectEqualStrings(@embedFile("simple_snapshots.txt"), images.items);
}

test "Simple Run marks and centered selection preserve details" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 120, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 40, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.add(gpa, .run, "script");
    const e = &t.entries.items[0];
    try e.output.appendSlice(gpa, "result");
    var input: Editor = .{};
    defer input.deinit(gpa);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    var cfg = mock_cfg;
    cfg.simple = true;
    for ([_]@FieldType(Entry, "run"){ .ok, .failed, .running, .warning }) |state| {
        e.run = state;
        try e.refreshLabel(gpa);
        const frame = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = cfg, .hovered = 0, .hover_bg = .{ .rgb = .{ 18, 18, 18 } } }, &text).?;
        try testing.expectEqual(@as(u16, 1), e.height(frame.window));
        const image = try snapshot(gpa, &screen);
        defer gpa.free(image);
        try testing.expect(std.mem.indexOf(u8, image, switch (state) {
            .ok => "✓ Run",
            .failed => "✗ Run",
            .running => "Run · running",
            else => "! Run",
        }) != null);
        try testing.expect(std.mem.indexOf(u8, image, "mock") == null);
        const p = @import("selection/history.zig").position(frame, t.entries.items, 15, 0).?;
        try testing.expectEqual(@as(usize, 0), p.entry);
        try testing.expectEqual(@as(u16, 0), p.row);
        try testing.expectEqualDeep(vaxis.Color{ .rgb = .{ 18, 18, 18 } }, screen.readCell(11, 0).?.style.bg);
        try testing.expectEqualDeep(vaxis.Color.default, screen.readCell(9, 0).?.style.bg);
        e.open = true;
        const expanded = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = cfg }, &text).?;
        try testing.expect(e.height(expanded.window) > 1);
        const history: @import("selection/history.zig").History = .{ .anchor = .{ .entry = 0, .row = 0, .col = 0 }, .end = .{ .entry = 0, .row = 0, .col = 119 } };
        const copied = try history.text(gpa, expanded, t.entries.items);
        defer gpa.free(copied);
        try testing.expect(!std.mem.startsWith(u8, copied, "          "));
        e.open = false;
    }
}
