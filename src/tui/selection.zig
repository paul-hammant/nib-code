const std = @import("std");
const vaxis = @import("vaxis");

pub const Point = struct { col: u16, row: u16 };

pub const Selection = struct {
    anchor: ?Point = null,
    end: Point = .{ .col = 0, .row = 0 },
    active: bool = false,
    dragged: bool = false,

    pub fn clear(s: *Selection) void {
        s.* = .{};
    }

    pub fn mouse(s: *Selection, m: vaxis.Mouse, screen: *const vaxis.Screen) bool {
        if (screen.width == 0 or screen.height == 0) return false;
        const p: Point = .{
            .col = @intCast(@min(@max(m.col, 0), screen.width - 1)),
            .row = @intCast(@min(@max(m.row, 0), screen.height - 1)),
        };
        if (m.type == .press and m.button == .left) {
            s.* = .{ .anchor = p, .end = p, .active = true };
        } else if (s.active and (m.type == .drag or m.type == .motion) and m.button == .left) {
            s.end = p;
            s.dragged = s.dragged or !std.meta.eql(s.anchor.?, p);
        } else if (s.active and m.type == .release and (m.button == .left or m.button == .none)) {
            s.end = p;
            s.active = false;
            if (!s.dragged) {
                s.clear();
                return false;
            }
            return true;
        }
        return false;
    }

    const Range = struct { first: Point, last: Point };

    fn range(s: Selection) ?Range {
        const a = s.anchor orelse return null;
        if (!s.dragged) return null;
        const forward = a.row < s.end.row or (a.row == s.end.row and a.col <= s.end.col);
        return .{ .first = if (forward) a else s.end, .last = if (forward) s.end else a };
    }

    pub fn highlight(s: Selection, screen: *vaxis.Screen) void {
        const r = s.range() orelse return;
        var row: usize = r.first.row;
        while (row <= r.last.row and row < screen.height) : (row += 1) {
            const first: usize = if (row == r.first.row) r.first.col else 0;
            const last: usize = if (row == r.last.row) r.last.col else screen.width -| 1;
            var col = first;
            while (col <= last and col < screen.width) : (col += 1) {
                const cell = &screen.buf[row * screen.width + col];
                cell.style.reverse = !cell.style.reverse;
                cell.default = false;
            }
        }
    }

    pub fn text(s: Selection, gpa: std.mem.Allocator, screen: *const vaxis.Screen) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (s.range()) |r| {
            var row: usize = r.first.row;
            while (row <= r.last.row and row < screen.height) : (row += 1) {
                if (row != r.first.row) try out.append(gpa, '\n');
                const start = out.items.len;
                const first: usize = if (row == r.first.row) r.first.col else 0;
                const last: usize = if (row == r.last.row) r.last.col else screen.width -| 1;
                var col: usize = 0;
                while (col <= last and col < screen.width) {
                    const cell = screen.readCell(@intCast(col), @intCast(row)).?;
                    if (col >= first) try out.appendSlice(gpa, cell.char.grapheme);
                    // Vaxis leaves covered cells untouched; only the leading cell owns the glyph.
                    const width = if (cell.char.width != 0) cell.char.width else vaxis.gwidth.gwidth(cell.char.grapheme, screen.width_method);
                    col += @max(1, width);
                }
                while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

pub fn copy(vx: *vaxis.Vaxis, w: *std.Io.Writer, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, text: []const u8) !void {
    try vx.copyToSystemClipboard(w, text, gpa);
    try w.flush();
    localCopy(io, env, text) catch {};
}

fn localCopy(io: std.Io, env: *const std.process.Environ.Map, text: []const u8) !void {
    if (!env.contains("WAYLAND_DISPLAY") and !env.contains("DISPLAY")) return;
    const Worker = struct {
        fn run(i: std.Io, e: *const std.process.Environ.Map, bytes: []const u8, done: *std.Io.Event) !void {
            defer done.set(i);
            try localCopyProcess(i, e, bytes);
        }
    };
    var done: std.Io.Event = .unset;
    var task = try io.concurrent(Worker.run, .{ io, env, text, &done });
    defer task.cancel(io) catch {};
    try done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try task.await(io);
}

fn localCopyProcess(io: std.Io, env: *const std.process.Environ.Map, text: []const u8) !void {
    if (!env.contains("WAYLAND_DISPLAY") and !env.contains("DISPLAY")) return;
    const script =
        \\if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then exec wl-copy
        \\elif [ -n "$DISPLAY" ]; then
        \\  if command -v xsel >/dev/null 2>&1; then exec xsel --clipboard --input
        \\  elif command -v xclip >/dev/null 2>&1; then exec xclip -selection clipboard; fi
        \\fi
        \\exit 1
    ;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", script }, .environ_map = env, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io);
    const file = child.stdin.?;
    child.stdin = null;
    {
        defer file.close(io);
        var writer = file.writer(io, &.{});
        try writer.interface.writeAll(text);
        try writer.interface.flush();
    }
    const term = try child.wait(io);
    if (!term.success()) return error.ClipboardFailed;
}

fn mouse(col: i16, row: i16, kind: vaxis.Mouse.Type) vaxis.Mouse {
    return .{ .col = col, .row = row, .button = .left, .mods = .{}, .type = kind };
}

fn expectText(s: Selection, screen: *vaxis.Screen, expected: []const u8) !void {
    const actual = try s.text(std.testing.allocator, screen);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn testScreen() !vaxis.Screen {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 8, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 8, .height = 3, .screen = &screen };
    _ = win.printSegment(.{ .text = "abc  \n中x y  \nend" }, .{});
    return screen;
}

test "selection forward and reverse on one row, click clears" {
    var screen = try testScreen();
    defer screen.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |reverse| {
        var s: Selection = .{};
        _ = s.mouse(mouse(if (reverse) 2 else 0, 0, .press), &screen);
        _ = s.mouse(mouse(if (reverse) 0 else 2, 0, .drag), &screen);
        try std.testing.expect(s.mouse(mouse(if (reverse) 0 else 2, 0, .release), &screen));
        try expectText(s, &screen, "abc");
        s.highlight(&screen);
        try std.testing.expect(screen.readCell(0, 0).?.style.reverse);
        try std.testing.expect(!screen.readCell(3, 0).?.style.reverse);
        s.highlight(&screen);
        _ = s.mouse(mouse(1, 0, .press), &screen);
        try std.testing.expect(!s.mouse(mouse(1, 0, .release), &screen));
        try expectText(s, &screen, "");
    }
}

test "selection multiline in both directions trims trailing spaces and skips wide continuations" {
    var screen = try testScreen();
    defer screen.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |reverse| {
        var s: Selection = .{};
        _ = s.mouse(mouse(1, if (reverse) 2 else 0, .press), &screen);
        _ = s.mouse(mouse(1, if (reverse) 0 else 2, .drag), &screen);
        _ = s.mouse(mouse(1, if (reverse) 0 else 2, .release), &screen);
        try expectText(s, &screen, "bc\n中x y\nen");
        s.clear();
        try expectText(s, &screen, "");
    }
    var s: Selection = .{};
    _ = s.mouse(mouse(1, 1, .press), &screen);
    _ = s.mouse(mouse(7, 1, .drag), &screen);
    _ = s.mouse(mouse(7, 1, .release), &screen);
    try expectText(s, &screen, "x y");
}

test "selection preserves empty rows and clamps coordinates to the screen" {
    var screen = try testScreen();
    defer screen.deinit(std.testing.allocator);
    for (0..screen.width) |col| screen.writeCell(@intCast(col), 1, .{});
    var s: Selection = .{};
    _ = s.mouse(mouse(-10, -10, .press), &screen);
    _ = s.mouse(mouse(100, 100, .drag), &screen);
    try std.testing.expect(s.mouse(mouse(100, 100, .release), &screen));
    try expectText(s, &screen, "abc\n\nend");
    s.highlight(&screen);
    for (screen.buf) |cell| try std.testing.expect(cell.style.reverse);
    s.clear();
    try expectText(s, &screen, "");
    try std.testing.expect(!s.mouse(mouse(0, 0, .release), &screen));
}

test "selection reads the screen at release rather than press" {
    var screen = try testScreen();
    defer screen.deinit(std.testing.allocator);
    var s: Selection = .{};
    _ = s.mouse(mouse(0, 0, .press), &screen);
    _ = s.mouse(mouse(2, 0, .drag), &screen);
    screen.writeCell(1, 0, .{ .char = .{ .grapheme = "新", .width = 2 } });
    _ = s.mouse(mouse(2, 0, .release), &screen);
    try expectText(s, &screen, "a新");
}
