const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../provider.zig");
const commands = @import("commands.zig");
const Editor = @import("editor.zig").Editor;
const Entry = @import("transcript.zig").Entry;
const Transcript = @import("transcript.zig").Transcript;
const Viewport = @import("viewport.zig").Viewport;
const status = @import("status.zig");

const max_menu_rows = 8;

pub fn draw(win: vaxis.Window, entries: []Entry, input: *Editor, scroll: *Viewport, menu: []const commands.Candidate, menu_sel: usize, s: status.Status, text: *status.Text) void {
    win.clear();
    win.hideCursor();
    if (win.height == 0 or win.width == 0) return;

    const framed = win.height >= 6 and win.width >= 8;
    const hints: u16 = @intFromBool(framed and win.height >= 8);
    const borders: u16 = if (framed) 2 else 0;
    const x: u16 = if (framed) 2 else @min(3, win.width - 1);
    const input_w = win.width - x - @as(u16, if (framed) 2 else 0);
    const input_h = @min(input.rows(win.child(.{ .width = input_w })), @max(1, win.height / 3));
    const saved_scroll = scroll.*;
    var activity_h: u16 = @intFromBool(s.busy != null or s.notice != null or scroll.top != null or scroll.pending < 0);
    activity_h = @min(activity_h, win.height - input_h - borders - hints);
    const menu_h: u16 = @intCast(@min(menu.len, max_menu_rows, (win.height - input_h - borders - hints - activity_h) / 2));
    var body_h = win.height - input_h - borders - hints - menu_h - activity_h;
    var body = win.child(.{ .x_off = @min(1, win.width - 1), .width = @max(1, win.width -| 2), .height = body_h });
    var top = scroll.layout(entries, body);
    const actual_h: u16 = @intFromBool(text.format(s, scroll.top != null).len > 0 and win.height > input_h + borders + hints + menu_h);
    if (actual_h != activity_h) {
        activity_h = actual_h;
        body_h = win.height - input_h - borders - hints - menu_h - activity_h;
        body.height = body_h;
        scroll.* = saved_scroll;
        top = scroll.layout(entries, body);
    }
    var y: i32 = -@as(i32, top.row);
    for (entries[top.entry..]) |*e| {
        if (y >= body_h) break;
        const h = e.height(body);
        if (y + h > 0) _ = e.print(body.child(.{ .y_off = @intCast(y), .height = h }), true);
        y += @as(i32, h) + 1;
    }

    if (activity_h > 0) {
        _ = win.child(.{ .x_off = 1, .y_off = body_h, .height = 1 }).printSegment(.{ .text = text.format(s, scroll.top != null), .style = if (s.busy != null) .{ .fg = .{ .index = 3 } } else .{ .dim = true } }, .{ .wrap = .none });
    }
    const first = if (menu_sel >= menu_h) menu_sel + 1 - menu_h else 0;
    for (0..menu_h) |i| {
        const c = menu[first + i];
        const chosen = first + i == menu_sel;
        const row = win.child(.{ .x_off = 1, .y_off = @intCast(body_h + activity_h + i), .height = 1 });
        _ = row.printSegment(.{ .text = c.label, .style = if (chosen) .{ .reverse = true, .bold = true } else .{ .bold = true } }, .{ .wrap = .none });
        if (win.width > 16) _ = row.child(.{ .x_off = 14 }).printSegment(.{ .text = c.detail, .style = .{ .dim = true } }, .{ .wrap = .none });
    }

    const input_y = body_h + activity_h + menu_h;
    if (framed) {
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
    input.draw(win.child(.{ .x_off = x, .y_off = input_y + @as(u16, if (framed) 1 else 0), .width = input_w, .height = input_h }));
    if (hints > 0) _ = win.child(.{ .x_off = 2, .y_off = win.height - 1, .height = 1 }).printSegment(.{ .text = "⏎ send · ⇧⏎ newline · / commands · ctrl+o expand", .style = .{ .dim = true } }, .{ .wrap = .none });
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
        if (c.h >= 6) {
            try testing.expectEqualStrings("╰", screen.readCell(0, if (c.h >= 8) c.h - 2 else c.h - 1).?.char.grapheme);
            try testing.expectEqualStrings("╯", screen.readCell(c.w - 1, if (c.h >= 8) c.h - 2 else c.h - 1).?.char.grapheme);
        } else try testing.expect(std.mem.indexOf(u8, image, "› Message nib") != null);
        if (c.busy) try testing.expect(std.mem.indexOf(u8, image, "thinking 1s · step 1 · esc to cancel") != null);
        if (c.history) try testing.expect(std.mem.indexOf(u8, image, "↑ history · PgDn to return") != null);
        if (c.notice) try testing.expect(std.mem.indexOf(u8, image, "copied 3 chars") != null);
        if (c.menu) try testing.expect(std.mem.indexOf(u8, image, "/help") != null);
    }
    try testing.expectEqualStrings(@embedFile("layout_snapshots.txt"), images.items);
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
    try testing.expectEqual(@as(u16, 25), screen.cursor.col);
    try testing.expectEqual(@as(u16, 9), screen.cursor.row);
    var selection: Selection = .{};
    _ = selection.mouse(.{ .col = 24, .row = 9, .type = .press, .button = .left, .mods = .{} }, &screen);
    _ = selection.mouse(.{ .col = 2, .row = 9, .type = .drag, .button = .left, .mods = .{} }, &screen);
    try testing.expect(selection.mouse(.{ .col = 2, .row = 9, .type = .release, .button = .left, .mods = .{} }, &screen));
    const copied = try selection.text(gpa, &screen);
    defer gpa.free(copied);
    try testing.expectEqualStrings("你[Pasted #1 · 6 lines]", copied);
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
