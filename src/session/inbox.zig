const std = @import("std");
const provider = @import("../provider.zig");

pub const Batch = struct {
    items: std.ArrayList(Item) = .empty,

    pub fn deinit(b: *Batch, gpa: std.mem.Allocator) void {
        for (b.items.items) |item| gpa.free(item.text);
        b.items.deinit(gpa);
    }

    pub fn joined(b: Batch, gpa: std.mem.Allocator) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        for (b.items.items, 0..) |item, i| {
            if (i > 0) try text.appendSlice(gpa, "\n\n");
            try text.appendSlice(gpa, item.text);
        }
        return text.toOwnedSlice(gpa);
    }
};

const Item = struct { id: u64, text: []const u8 };

pub const Inbox = struct {
    mutex: std.Io.Mutex = .init,
    batch: Batch = .{},
    next_id: u64 = 1,

    pub fn enqueue(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, text: []const u8) !u64 {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        const id = q.next_id;
        try q.batch.items.append(gpa, .{ .id = id, .text = copy });
        q.next_id += 1;
        return id;
    }

    pub fn take(q: *Inbox, io: std.Io) Batch {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const batch = q.batch;
        q.batch = .{};
        return batch;
    }

    pub fn insert(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, pending: *std.ArrayList(provider.Message)) !Batch {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        var messages: std.ArrayList(provider.Message) = .empty;
        defer messages.deinit(gpa);
        for (q.batch.items.items) |item|
            try messages.append(gpa, .{ .role = "user", .content = try arena.dupe(u8, item.text) });
        try pending.appendSlice(gpa, messages.items);
        const batch = q.batch;
        q.batch = .{};
        return batch;
    }
};

test "insert drains an owned FIFO batch after tool results" {
    const t = std.testing;
    const gpa = t.allocator;
    var q: Inbox = .{};
    defer q.batch.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var pending: std.ArrayList(provider.Message) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, .{ .role = "tool", .content = "result", .tool_call_id = "run" });
    var original = [_]u8{ 'o', 'n', 'e' };
    const first = try q.enqueue(gpa, t.io, &original);
    original[0] = 'x';
    const second = try q.enqueue(gpa, t.io, "two");
    var batch = try q.insert(gpa, t.io, arena.allocator(), &pending);
    defer batch.deinit(gpa);
    try t.expectEqual(@as(usize, 0), q.batch.items.items.len);
    try t.expectEqual(first, batch.items.items[0].id);
    try t.expectEqual(second, batch.items.items[1].id);
    try t.expectEqualStrings("tool", pending.items[0].role);
    try t.expectEqualStrings("one", pending.items[1].content.?);
    try t.expectEqualStrings("user", pending.items[1].role);
    try t.expectEqualStrings("two", pending.items[2].content.?);
    _ = try q.enqueue(gpa, t.io, "later");
    var leftover = q.take(t.io);
    defer leftover.deinit(gpa);
    try t.expectEqual(@as(usize, 1), leftover.items.items.len);
    const joined = try batch.joined(gpa);
    defer gpa.free(joined);
    try t.expectEqualStrings("one\n\ntwo", joined);
}

test "concurrent enqueue assigns FIFO ids without losing messages" {
    const t = std.testing;
    var q: Inbox = .{};
    defer q.batch.deinit(t.allocator);
    const Worker = struct {
        fn run(inbox: *Inbox) void {
            for (0..25) |_| _ = inbox.enqueue(std.testing.allocator, std.testing.io, "message") catch @panic("enqueue failed");
        }
    };
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    {
        defer for (threads[0..spawned]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{&q});
            spawned += 1;
        }
    }
    var batch = q.take(t.io);
    defer batch.deinit(t.allocator);
    try t.expectEqual(@as(usize, 100), batch.items.items.len);
    for (batch.items.items, 1..) |item, id| try t.expectEqual(@as(u64, id), item.id);
}
