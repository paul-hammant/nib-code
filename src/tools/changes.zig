const std = @import("std");
const diff = @import("diff.zig");

pub const Tracker = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        path: []u8,
        added: usize = 0,
        removed: usize = 0,
        created: bool = false,
        preview: diff.Preview = .{},
    };

    pub fn record(t: *Tracker, gpa: std.mem.Allocator, path: []const u8, before: ?[]const u8, after: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const stat = try diff.compare(scratch.allocator(), before orelse "", after);
        if (stat.added == 0 and stat.removed == 0 and before != null) return;
        const entry = for (t.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) break entry;
        } else entry: {
            const owned_path = try gpa.dupe(u8, path);
            errdefer gpa.free(owned_path);
            try t.entries.append(gpa, .{ .path = owned_path });
            break :entry &t.entries.items[t.entries.items.len - 1];
        };
        try entry.preview.append(gpa, stat.preview);
        entry.added += stat.added;
        entry.removed += stat.removed;
        entry.created = entry.created or before == null;
    }

    pub fn take(t: *Tracker, gpa: std.mem.Allocator, a: std.mem.Allocator, cwd: []const u8) ![]const diff.Change {
        defer t.discard(gpa);
        const out = try a.alloc(diff.Change, t.entries.items.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |change| {
                a.free(change.path);
                a.free(change.diff);
            }
            a.free(out);
        }
        for (t.entries.items, out) |entry, *change| {
            const shown = if (std.mem.startsWith(u8, entry.path, cwd) and entry.path.len > cwd.len and entry.path[cwd.len] == '/') entry.path[cwd.len + 1 ..] else entry.path;
            const path = try a.dupe(u8, shown);
            errdefer a.free(path);
            change.* = .{
                .path = path,
                .added = entry.added,
                .removed = entry.removed,
                .created = entry.created,
                .diff = try entry.preview.format(a),
            };
            initialized += 1;
        }
        return out;
    }

    pub fn discard(t: *Tracker, gpa: std.mem.Allocator) void {
        for (t.entries.items) |*entry| {
            gpa.free(entry.path);
            entry.preview.deinit(gpa);
        }
        t.entries.clearAndFree(gpa);
    }
};

const testing = std.testing;

test "changes accumulate writes and reversals in first-seen path order" {
    var tracker: Tracker = .{};
    defer tracker.discard(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try tracker.record(testing.allocator, "/project/a", "old\n", "new\n");
    try tracker.record(testing.allocator, "/project/b", null, "");
    try tracker.record(testing.allocator, "/project/a", "new\n", "old\n");
    try tracker.record(testing.allocator, "/project/b", "", "created\n");
    try tracker.record(testing.allocator, "/project/noop", "same\n", "same\n");
    const changes = try tracker.take(testing.allocator, arena.allocator(), "/project");
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("a", changes[0].path);
    try testing.expectEqual(@as(usize, 2), changes[0].added);
    try testing.expectEqual(@as(usize, 2), changes[0].removed);
    try testing.expect(!changes[0].created);
    try testing.expectEqualStrings("-old\n+new\n…\n-new\n+old\n", changes[0].diff);
    try testing.expectEqualStrings("b", changes[1].path);
    try testing.expectEqual(@as(usize, 1), changes[1].added);
    try testing.expectEqual(@as(usize, 0), changes[1].removed);
    try testing.expect(changes[1].created);
    try testing.expectEqualStrings("+created\n", changes[1].diff);
    try testing.expectEqual(@as(usize, 0), (try tracker.take(testing.allocator, arena.allocator(), "/project")).len);
}

test "diff preview stays bounded across repeated operations while totals accumulate" {
    var tracker: Tracker = .{};
    defer tracker.discard(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (0..250) |_| try tracker.record(testing.allocator, "/f", "old\n", "new\n");
    const changes = try tracker.take(testing.allocator, arena.allocator(), "/project");
    try testing.expectEqualStrings("/f", changes[0].path);
    try testing.expectEqual(@as(usize, 250), changes[0].added);
    try testing.expectEqual(@as(usize, 250), changes[0].removed);
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, changes[0].diff, "+new\n"));
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, changes[0].diff, "-old\n"));
    try testing.expect(std.mem.endsWith(u8, changes[0].diff, "… 300 more lines\n"));
}

test "diff preview combines already-truncated operations" {
    var tracker: Tracker = .{};
    defer tracker.discard(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..250) |_| try text.appendSlice(testing.allocator, "line\n");
    try tracker.record(testing.allocator, "/f", null, text.items);
    try tracker.record(testing.allocator, "/f", text.items, "");
    const changes = try tracker.take(testing.allocator, arena.allocator(), "/project");
    try testing.expectEqual(@as(usize, 250), changes[0].added);
    try testing.expectEqual(@as(usize, 250), changes[0].removed);
    try testing.expect(changes[0].created);
    try testing.expect(std.mem.endsWith(u8, changes[0].diff, "… 300 more lines\n"));
}

pub const Recovery = struct {
    enabled: bool = false,
    mutex: std.Io.Mutex = .init,
    paths: std.ArrayList([]const u8) = .empty,
    bash: bool = false,

    pub const Reason = enum { model, tool, timeout, canceled, limit };

    pub fn classify(err: anyerror, canceled: bool, stage: Reason) Reason {
        if (canceled or err == error.Canceled) return .canceled;
        return switch (err) {
            error.Timeout, error.TimedOut, error.StreamIdleTimeout, error.StreamContentTimeout, error.ModelRequestTimeout => .timeout,
            error.TooManySteps => .limit,
            else => stage,
        };
    }

    pub fn record(r: *Recovery, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        if (!r.enabled) return;
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (r.paths.items) |old| if (std.mem.eql(u8, old, path)) return;
        const copy = try gpa.dupe(u8, path);
        errdefer gpa.free(copy);
        try r.paths.append(gpa, copy);
    }

    pub fn noteBash(r: *Recovery, io: std.Io) void {
        if (!r.enabled) return;
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.bash = true;
    }

    pub fn clear(r: *Recovery, gpa: std.mem.Allocator, io: std.Io) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (r.paths.items) |path| gpa.free(path);
        r.paths.clearAndFree(gpa);
        r.bash = false;
    }

    pub fn hint(r: *Recovery, gpa: std.mem.Allocator, io: std.Io, reason: Reason, cwd: []const u8) ![]u8 {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        try text.appendSlice(gpa, switch (reason) {
            .model => "model connection/request failed",
            .tool => "tool/script failed",
            .timeout => "Timed out",
            .canceled => "Canceled",
            .limit => "step limit reached",
        });
        try text.appendSlice(gpa, if (r.paths.items.len == 0) " · no recorded edit/write changes" else " · edited: ");
        for (r.paths.items, 0..) |path, i| {
            if (i > 0) try text.appendSlice(gpa, ", ");
            const shown = if (path.len > cwd.len and std.mem.startsWith(u8, path, cwd) and path[cwd.len] == '/') path[cwd.len + 1 ..] else path;
            try text.appendSlice(gpa, shown);
        }
        if (r.bash) try text.appendSlice(gpa, " · bash changes untracked");
        if (r.paths.items.len > 0) try text.appendSlice(gpa, " · /undo to revert edit/write");
        try text.appendSlice(gpa, " · type continue to resume");
        for (text.items) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
            byte.* = ' ';
        };
        return text.toOwnedSlice(gpa);
    }
};

test "recovery records only this Turn's unique paths and distinguishes failure categories" {
    var r: Recovery = .{ .enabled = true };
    defer r.clear(testing.allocator, testing.io);
    try r.record(testing.allocator, testing.io, "/project/a.zig");
    try r.record(testing.allocator, testing.io, "/project/a.zig");
    try r.record(testing.allocator, testing.io, "/project/b.zig");
    r.noteBash(testing.io);
    const text = try r.hint(testing.allocator, testing.io, .canceled, "/project");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Canceled · edited: a.zig, b.zig · bash changes untracked · /undo to revert edit/write · type continue to resume", text);
    r.clear(testing.allocator, testing.io);
    const empty = try r.hint(testing.allocator, testing.io, .model, "/project");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("model connection/request failed · no recorded edit/write changes · type continue to resume", empty);
    try testing.expectEqual(Recovery.Reason.timeout, Recovery.classify(error.StreamIdleTimeout, false, .model));
    try testing.expectEqual(Recovery.Reason.canceled, Recovery.classify(error.ReadFailed, true, .model));
    try testing.expectEqual(Recovery.Reason.tool, Recovery.classify(error.TestScriptFailure, false, .tool));
}
