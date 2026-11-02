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

/// One frame, top to bottom: transcript, `/` menu, status line, input.
pub fn draw(win: vaxis.Window, entries: []Entry, input: *Editor, scroll: *Viewport, menu: []const commands.Candidate, menu_sel: usize, s: status.Status, text: *status.Text) void {
    win.clear();
    win.hideCursor();
    if (win.height < 6 or win.width < 8) return;

    const input_rows = input.rows(win.child(.{ .x_off = 3 }));
    const input_h: u16 = @min(input_rows, win.height / 3);
    const menu_h: u16 = @intCast(@min(menu.len, max_menu_rows, (win.height - 1 - input_h) / 2));
    const body_h: u16 = win.height - 1 - input_h - menu_h;
    const body = win.child(.{ .x_off = 1, .width = win.width - 2, .height = body_h });
    const top = scroll.layout(entries, body);
    var y: i32 = -@as(i32, top.row);
    for (entries[top.entry..]) |*e| {
        if (y >= body_h) break;
        const h = e.height(body);
        if (y + h > 0) _ = e.print(body.child(.{ .y_off = @intCast(y), .height = h }), true);
        y += @as(i32, h) + 1;
    }

    const first = if (menu_sel >= menu_h) menu_sel + 1 - menu_h else 0;
    for (0..menu_h) |i| {
        const c = menu[first + i];
        const chosen = first + i == menu_sel;
        const row = win.child(.{ .x_off = 1, .y_off = @intCast(body_h + i), .height = 1 });
        const name_style: vaxis.Style = if (chosen) .{ .reverse = true, .bold = true } else .{ .bold = true };
        _ = row.printSegment(.{ .text = c.label, .style = name_style }, .{ .wrap = .none });
        _ = row.child(.{ .x_off = 14 }).printSegment(.{ .text = c.detail, .style = .{ .dim = true } }, .{ .wrap = .none });
    }

    const status_style: vaxis.Style = if (s.busy != null) .{ .fg = .{ .index = 3 } } else .{ .dim = true };
    const line = text.format(s, scroll.top != null);
    _ = win.child(.{ .x_off = 1, .y_off = body_h + menu_h, .height = 1 }).printSegment(.{ .text = line, .style = status_style }, .{ .wrap = .none });

    _ = win.child(.{ .x_off = 1, .y_off = body_h + menu_h + 1, .height = 1 }).printSegment(.{ .text = "› ", .style = .{ .fg = .{ .index = 4 } } }, .{});
    input.draw(win.child(.{ .x_off = 3, .y_off = body_h + menu_h + 1, .height = input_h }));
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
    const body_before = try gpa.dupe(vaxis.Cell, screen.buf[0 .. 22 * 100]);
    defer gpa.free(body_before);
    try t.entries.items[1].text.appendSlice(gpa, "\nmore streamed text");
    try t.add(gpa, .info, "Run output");
    draw(win, t.entries.items, &input, &view, &.{}, 0, busy, &text);
    try testing.expectEqualDeep(body_before, screen.buf[0 .. 22 * 100]);
    for (0..16) |i| try input.buf.print(gpa, "input {d}\n", .{i});
    input.cursor = input.buf.items.len;
    draw(win, t.entries.items, &input, &view, &.{}, 0, busy, &text);
    try testing.expectEqual(@as(u16, 9), input.top_row);
    try testing.expectEqual(@as(u16, 23), screen.cursor.row);
    try testing.expect(screen.cursor_vis);
    try testing.expectEqualStrings("i", screen.readCell(3, 16).?.char.grapheme);
}
