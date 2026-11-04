const std = @import("std");
const vaxis = @import("vaxis");
const Progress = @import("../session/events.zig").Progress;

pub const Tree = struct {
    rows: std.ArrayList(Row) = .empty,

    pub fn deinit(tree: *Tree, gpa: std.mem.Allocator) void {
        for (tree.rows.items) |row| gpa.free(row.text);
        tree.rows.deinit(gpa);
        tree.* = .{};
    }

    pub fn update(tree: *Tree, gpa: std.mem.Allocator, agents: []const Progress) !void {
        var next: Tree = .{};
        errdefer next.deinit(gpa);
        try next.rows.ensureTotalCapacity(gpa, agents.len);
        for (agents, 0..) |p, i| next.rows.appendAssumeCapacity(try Row.init(gpa, p, i + 1 == agents.len));
        tree.deinit(gpa);
        tree.* = next;
    }

    pub fn print(tree: *const Tree, win: vaxis.Window, commit: bool) u16 {
        for (tree.rows.items, 0..) |*row, i| {
            row.print(win.child(.{ .y_off = @intCast(i), .height = 1 }), commit);
        }
        return @intCast(tree.rows.items.len);
    }
};

const Row = struct {
    text: []u8,
    prompt_start: usize,
    prompt_end: usize,
    status_end: usize,
    tools_end: usize,
    prompt_omitted: bool,

    fn init(gpa: std.mem.Allocator, p: Progress, last: bool) !Row {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        try text.print(gpa, "  {s} #{d} {s}", .{ if (last) "└─" else "├─", p.agent, if (p.kind == .bash) "bash " else "" });
        const prompt_start = text.items.len;
        var end: usize = 0;
        var chars: usize = 0;
        var it = vaxis.unicode.graphemeIterator(p.prompt);
        while (it.next()) |grapheme| {
            const bytes = grapheme.bytes(p.prompt);
            const count = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
            if (chars + count > 40) break;
            chars += count;
            end += bytes.len;
        }
        try text.appendSlice(gpa, p.prompt[0..end]);
        const prompt_end = text.items.len;
        if (p.kind == .bash)
            try text.print(gpa, " · {d}.{d}s · {s}", .{ p.elapsed_ms / 1000, p.elapsed_ms % 1000 / 100, @tagName(p.state) })
        else
            try text.print(gpa, " · {s} · step {d}", .{ @tagName(p.state), p.step });
        const status_end = text.items.len;
        for (p.tools, 0..) |name, i| {
            try text.appendSlice(gpa, if (i == 0) " · " else ", ");
            try text.appendSlice(gpa, name);
        }
        const tools_end = text.items.len;
        for (p.files, 0..) |path, i| {
            try text.appendSlice(gpa, if (i > 0) ", " else if (p.tools.len > 0) " " else " · ");
            try text.appendSlice(gpa, path);
        }
        for (text.items) |*byte| {
            if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
        }
        return .{
            .text = try text.toOwnedSlice(gpa),
            .prompt_start = prompt_start,
            .prompt_end = prompt_end,
            .status_end = status_end,
            .tools_end = tools_end,
            .prompt_omitted = end < p.prompt.len,
        };
    }

    fn print(row: *const Row, win: vaxis.Window, commit: bool) void {
        const prefix = row.text[0..row.prompt_start];
        const status = row.text[row.prompt_end..row.status_end];
        const used = row.text[row.status_end..row.tools_end];
        const fixed = width(win, prefix) +| width(win, status) +| width(win, used);
        const prompt = fit(win, row.text[row.prompt_start..row.prompt_end], win.width -| fixed, row.prompt_omitted);
        const files = fit(win, row.text[row.tools_end..], win.width -| (fixed +| width(win, prompt.text) +| width(win, prompt.suffix)), false);
        const dim: vaxis.Style = .{ .dim = true };
        _ = win.print(&.{
            .{ .text = prefix, .style = dim },
            .{ .text = prompt.text, .style = dim },
            .{ .text = prompt.suffix, .style = dim },
            .{ .text = status, .style = dim },
            .{ .text = used, .style = dim },
            .{ .text = files.text, .style = dim },
            .{ .text = files.suffix, .style = dim },
        }, .{ .wrap = .none, .commit = commit });
    }
};

fn width(win: vaxis.Window, text: []const u8) u16 {
    return vaxis.gwidth.gwidth(text, win.screen.width_method);
}

const Fitted = struct { text: []const u8, suffix: []const u8 = "" };

fn fit(win: vaxis.Window, text: []const u8, columns: u16, omitted: bool) Fitted {
    if (!omitted and width(win, text) <= columns) return .{ .text = text };
    if (columns == 0) return .{ .text = "" };
    const available = columns -| width(win, "…");
    var end: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |grapheme| {
        const next = end + grapheme.bytes(text).len;
        if (width(win, text[0..next]) > available) break;
        end = next;
    }
    return .{ .text = text[0..end], .suffix = "…" };
}

const testing = std.testing;

fn expectLine(screen: *vaxis.Screen, y: u16, expected: []const u8) !void {
    var x: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(expected);
    while (it.next()) |g| {
        const bytes = g.bytes(expected);
        const cell = screen.readCell(x, y).?;
        try testing.expectEqualStrings(bytes, cell.char.grapheme);
        try testing.expect(cell.style.dim);
        x += vaxis.gwidth.gwidth(bytes, screen.width_method);
    }
    while (x < screen.width) : (x += 1) try testing.expectEqualStrings(" ", screen.readCell(x, y).?.char.grapheme);
}

test "tree rows fit Unicode prompts and files around state step and tools" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 120, .rows = 4, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 4, .screen = &screen };
    var tree: Tree = .{};
    defer tree.deinit(gpa);
    try tree.update(gpa, &.{
        .{ .agent = 1, .prompt = "修复登录流程，补充测试", .step = 56, .tools = &.{ "edit", "bash" }, .files = &.{"src/auth.zig"} },
        .{ .agent = 2, .prompt = "check config", .state = .done, .step = 27, .tools = &.{ "grep", "read" } },
        .{ .agent = 3, .prompt = "test", .state = .failed, .step = 38, .files = &.{"docs/config.md"} },
    });
    try testing.expectEqual(@as(u16, 3), tree.print(win, true));
    try expectLine(&screen, 0, "  ├─ #1 修复登录流程，补充测试 · working · step 56 · edit, bash src/auth.zig");
    try expectLine(&screen, 1, "  ├─ #2 check config · done · step 27 · grep, read");
    try expectLine(&screen, 2, "  └─ #3 test · failed · step 38 · docs/config.md");
    try expectLine(&screen, 3, "");

    win.clear();
    win.width = 48;
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  ├─ #1 修复登… · working · step 56 · edit, bash");
    win.width = 120;
    win.clear();
    win.width = 75;
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  ├─ #1 修复登录流程，补充测试 · working · step 56 · edit, bash src/auth.z…");
}

test "tree previews sanitize control bytes and cap prompts without wrapping" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 120, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 3, .screen = &screen };
    var tree: Tree = .{};
    defer tree.deinit(gpa);
    try tree.update(gpa, &.{
        .{ .agent = 1, .prompt = "line\nnext\r\t\x1b", .state = .queued, .files = &.{"a\nb"} },
        .{ .agent = 2, .prompt = "12345678901234567890123456789012345678901234567890", .state = .timed_out, .step = 4 },
    });
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  ├─ #1 line next    · queued · step 0 · a b");
    try expectLine(&screen, 1, "  └─ #2 1234567890123456789012345678901234567890… · timed_out · step 4");
    try expectLine(&screen, 2, "");
    for (0..121) |columns| {
        win.width = 120;
        win.clear();
        win.width = @intCast(columns);
        try testing.expectEqual(@as(u16, 2), tree.print(win, false));
        try testing.expectEqual(@as(u16, 2), tree.print(win, true));
        try expectLine(&screen, 2, "");
    }
}

test "truncation preserves complete graphemes" {
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 8, .height = 1, .screen = &screen };
    const text = "á👩‍💻xyz";
    const fitted = fit(win, text, 4, false);
    try testing.expectEqualStrings("á👩‍💻", fitted.text);
    try testing.expectEqualStrings("…", fitted.suffix);
}
