const std = @import("std");
const Allocator = std.mem.Allocator;
const timing = @import("../sandbox/timing.zig");

pub const Count = struct { name: []const u8, count: u64 };

pub const Summary = struct {
    counts: []const Count = &.{},
    omitted: u64 = 0,

    pub fn init(gpa: Allocator, calls: []const timing.Call, run_index: usize, omitted: u64) !Summary {
        var counts: std.ArrayList(Count) = .empty;
        errdefer {
            for (counts.items) |item| gpa.free(item.name);
            counts.deinit(gpa);
        }
        for (calls) |call| {
            if (!call.dispatched or call.run_index != run_index) continue;
            for (counts.items) |*item| {
                if (std.mem.eql(u8, item.name, call.name)) {
                    item.count += 1;
                    break;
                }
            } else {
                const name = try gpa.dupe(u8, call.name);
                errdefer gpa.free(name);
                try counts.append(gpa, .{ .name = name, .count = 1 });
            }
        }
        return .{ .counts = try counts.toOwnedSlice(gpa), .omitted = omitted };
    }

    pub fn clone(s: Summary, gpa: Allocator) !Summary {
        const counts = try gpa.alloc(Count, s.counts.len);
        var copied: usize = 0;
        errdefer {
            for (counts[0..copied]) |item| gpa.free(item.name);
            gpa.free(counts);
        }
        for (s.counts, counts) |item, *copy| {
            copy.* = .{ .name = try gpa.dupe(u8, item.name), .count = item.count };
            copied += 1;
        }
        return .{ .counts = counts, .omitted = s.omitted };
    }

    pub fn deinit(s: Summary, gpa: Allocator) void {
        for (s.counts) |item| gpa.free(item.name);
        gpa.free(s.counts);
    }
};

test "summary filters rejected llm and other Runs in first dispatch order" {
    const t = std.testing;
    var r: timing.Run = .init(t.io, .now(t.io, .awake));
    _ = r.reserve("write");
    r.run_index = 1;
    const rejected = r.reserveEntry("llm").?;
    r.entries[rejected].dispatched = false;
    _ = r.reserve("read");
    _ = r.reserve("bash");
    _ = r.reserve("read");
    const llm = r.reserve("llm").?;
    r.complete(llm, 0, 1, false);
    const summary = try Summary.init(t.allocator, r.entries[0..r.count], 1, 0);
    defer summary.deinit(t.allocator);
    try t.expectEqualDeep(&[_]Count{
        .{ .name = "read", .count = 2 },
        .{ .name = "bash", .count = 1 },
        .{ .name = "llm", .count = 1 },
    }, summary.counts);
    const previous = try Summary.init(t.allocator, r.entries[0..r.count], 0, 0);
    defer previous.deinit(t.allocator);
    try t.expectEqualDeep(&[_]Count{.{ .name = "write", .count = 1 }}, previous.counts);
}

test "summary reports overflow delta even when Run has no retained calls" {
    const t = std.testing;
    var r: timing.Run = .init(t.io, .now(t.io, .awake));
    for (0..202) |_| _ = r.reserve("read");
    const first = try Summary.init(t.allocator, r.entries[0..r.count], 0, r.omitted);
    defer first.deinit(t.allocator);
    try t.expectEqualDeep(&[_]Count{.{ .name = "read", .count = 200 }}, first.counts);
    try t.expectEqual(@as(u64, 2), first.omitted);
    r.run_index = 1;
    const before = r.omitted;
    for (0..3) |_| _ = r.reserve("bash");
    const second = try Summary.init(t.allocator, r.entries[0..r.count], 1, r.omitted - before);
    defer second.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), second.counts.len);
    try t.expectEqual(@as(u64, 3), second.omitted);
}

test "summary and clone own names and counts" {
    const t = std.testing;
    var name = [_]u8{ 'r', 'e', 'a', 'd' };
    var calls = [_]timing.Call{.{ .name = &name, .start_ms = 0, .end_ms = 0, .ok = true, .run_index = 0 }};
    const summary = try Summary.init(t.allocator, &calls, 0, 7);
    defer summary.deinit(t.allocator);
    name[0] = 'x';
    const copy = try summary.clone(t.allocator);
    defer copy.deinit(t.allocator);
    try t.expectEqualStrings("read", summary.counts[0].name);
    try t.expectEqualDeep(summary, copy);
    try t.expect(summary.counts.ptr != copy.counts.ptr);
    try t.expect(summary.counts[0].name.ptr != copy.counts[0].name.ptr);
}

test "empty summary can be cloned and freed" {
    const t = std.testing;
    const summary = try Summary.init(t.allocator, &.{}, 0, 0);
    defer summary.deinit(t.allocator);
    const copy = try summary.clone(t.allocator);
    defer copy.deinit(t.allocator);
    try t.expectEqualDeep(Summary{}, copy);
    (Summary{}).deinit(t.allocator);
}

fn allocationFailures(gpa: Allocator) !void {
    const calls = [_]timing.Call{
        .{ .name = "read", .start_ms = 0, .end_ms = 0, .ok = true, .run_index = 0 },
        .{ .name = "bash", .start_ms = 0, .end_ms = 0, .ok = false, .run_index = 0 },
    };
    const summary = try Summary.init(gpa, &calls, 0, 1);
    defer summary.deinit(gpa);
    const copy = try summary.clone(gpa);
    defer copy.deinit(gpa);
}

test "summary allocation failures release counts and names" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
