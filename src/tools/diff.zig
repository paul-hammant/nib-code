const std = @import("std");

/// What a Run did to one file through edit/write.
pub const Change = struct {
    path: []const u8,
    added: usize,
    removed: usize,
    /// The file did not exist before the Run.
    created: bool = false,
    /// Changed lines with one line of context, prefixed "+", "-" or " ", gaps as "…";
    /// cut after `max_lines` lines with a final "… N more lines".
    diff: []const u8,
};

const max_lines = 200;
const context = 1;
/// Larger changed regions are reported as fully replaced instead of aligned line by line.
const max_cells = 1 << 20;

pub const Stat = struct { added: usize, removed: usize, diff: []const u8 };

pub fn compare(a: std.mem.Allocator, before: []const u8, after: []const u8) !Stat {
    const old = try lines(a, before);
    const new = try lines(a, after);

    var prefix: usize = 0;
    while (prefix < old.len and prefix < new.len and std.mem.eql(u8, old[prefix], new[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and
        std.mem.eql(u8, old[old.len - 1 - suffix], new[new.len - 1 - suffix])) suffix += 1;

    var ops: std.ArrayList(Op) = .empty;
    for (0..prefix) |i| try ops.append(a, .{ .kind = .same, .text = old[i] });
    try alignMiddle(a, old[prefix .. old.len - suffix], new[prefix .. new.len - suffix], &ops);
    for (old.len - suffix..old.len) |i| try ops.append(a, .{ .kind = .same, .text = old[i] });

    var stat: Stat = .{ .added = 0, .removed = 0, .diff = "" };
    for (ops.items) |op| switch (op.kind) {
        .add => stat.added += 1,
        .remove => stat.removed += 1,
        .same => {},
    };
    stat.diff = try render(a, ops.items);
    return stat;
}

const Op = struct { kind: enum { same, add, remove }, text: []const u8 };

fn lines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return out.items;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| try out.append(a, line);
    return out.items;
}

/// Longest common subsequence over the changed middle.
fn alignMiddle(a: std.mem.Allocator, old: []const []const u8, new: []const []const u8, ops: *std.ArrayList(Op)) !void {
    const n = old.len;
    const m = new.len;
    if (n == 0 or m == 0 or (n + 1) * (m + 1) > max_cells) {
        for (old) |l| try ops.append(a, .{ .kind = .remove, .text = l });
        for (new) |l| try ops.append(a, .{ .kind = .add, .text = l });
        return;
    }
    const w = m + 1;
    const table = try a.alloc(u32, (n + 1) * w);
    defer a.free(table);
    var i = n + 1;
    while (i > 0) {
        i -= 1;
        var j = m + 1;
        while (j > 0) {
            j -= 1;
            table[i * w + j] = if (i == n or j == m)
                0
            else if (std.mem.eql(u8, old[i], new[j]))
                table[(i + 1) * w + j + 1] + 1
            else
                @max(table[(i + 1) * w + j], table[i * w + j + 1]);
        }
    }
    i = 0;
    var j: usize = 0;
    while (i < n or j < m) {
        if (i < n and j < m and std.mem.eql(u8, old[i], new[j])) {
            try ops.append(a, .{ .kind = .same, .text = old[i] });
            i += 1;
            j += 1;
        } else if (i < n and (j == m or table[(i + 1) * w + j] >= table[i * w + j + 1])) {
            try ops.append(a, .{ .kind = .remove, .text = old[i] });
            i += 1;
        } else {
            try ops.append(a, .{ .kind = .add, .text = new[j] });
            j += 1;
        }
    }
}

fn render(a: std.mem.Allocator, ops: []const Op) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var shown: usize = 0;
    var last: ?usize = null;
    for (ops, 0..) |op, i| {
        if (!near(ops, i)) continue;
        if (shown == max_lines) {
            var rest: usize = 0;
            for (ops[i..], i..) |_, k| rest += @intFromBool(near(ops, k));
            try out.print(a, "… {d} more lines\n", .{rest});
            break;
        }
        if (last) |l| if (i > l + 1) try out.appendSlice(a, "…\n");
        try out.append(a, switch (op.kind) {
            .same => ' ',
            .add => '+',
            .remove => '-',
        });
        try out.appendSlice(a, op.text);
        try out.append(a, '\n');
        shown += 1;
        last = i;
    }
    return out.items;
}

/// A change, or within `context` lines of one.
fn near(ops: []const Op, i: usize) bool {
    const lo = i -| context;
    const hi = @min(ops.len, i + context + 1);
    for (ops[lo..hi]) |op| if (op.kind != .same) return true;
    return false;
}

const testing = std.testing;

fn expectDiff(before: []const u8, after: []const u8, added: usize, removed: usize, diff: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try compare(arena.allocator(), before, after);
    try testing.expectEqualStrings(diff, s.diff);
    try testing.expectEqual(added, s.added);
    try testing.expectEqual(removed, s.removed);
}

test "line diff with context and gaps" {
    try expectDiff("a\nb\nc\nd\ne\nf\ng\n", "a\nB\nc\nd\ne\nf\nG\n", 2, 2, " a\n-b\n+B\n c\n…\n f\n-g\n+G\n");
    try expectDiff("", "x\ny\n", 2, 0, "+x\n+y\n");
    try expectDiff("x\n", "", 0, 1, "-x\n");
    try expectDiff("same\n", "same\n", 0, 0, "");
    try expectDiff("a\nb\nc\n", "a\nc\n", 0, 1, " a\n-b\n c\n");
}

test "long diffs are cut with a count of the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var after: std.ArrayList(u8) = .empty;
    for (0..250) |i| try after.print(a, "line {d}\n", .{i});
    const s = try compare(a, "", after.items);
    try testing.expectEqual(@as(usize, 250), s.added);
    try testing.expect(std.mem.endsWith(u8, s.diff, "+line 199\n… 50 more lines\n"));
}
