const std = @import("std");
const Change = @import("../../tools/diff.zig").Change;
const max_diff_lines = @import("entry.zig").max_diff_lines;

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
