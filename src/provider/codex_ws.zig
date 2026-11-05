const std = @import("std");
const websocket = @import("websocket.zig");

pub const Info = struct {
    transport: enum { sse, websocket } = .sse,
    incremental: bool = false,
    input_items: usize = 0,
    input_bytes: usize = 0,
    fallback_reason: ?[]const u8 = null,
    fallback_at: ?i64 = null,
    fallback_detail: ?[]const u8 = null,
    full_reason: ?[]const u8 = null,
    mismatch_index: ?usize = null,
};

pub const State = struct {
    socket: ?websocket.Connection = null,
    scope: ?[32]u8 = null,
    previous_id: ?[]u8 = null,
    properties: ?[]u8 = null,
    baseline: ?[]u8 = null,
    degraded: ?[]const u8 = null,
    degraded_at: ?i64 = null,
    reset_reason: []const u8 = "first_request",
    last: Info = .{},

    pub fn reset(s: *State, gpa: std.mem.Allocator) void {
        if (s.socket) |*socket| socket.close(gpa);
        s.socket = null;
        s.scope = null;
        s.clearPrevious(gpa);
    }

    pub fn clearPrevious(s: *State, gpa: std.mem.Allocator) void {
        if (s.previous_id) |v| gpa.free(v);
        if (s.properties) |v| gpa.free(v);
        if (s.baseline) |v| gpa.free(v);
        s.previous_id = null;
        s.properties = null;
        s.baseline = null;
    }

    pub fn degrade(s: *State, gpa: std.mem.Allocator, reason: []const u8) void {
        s.reset(gpa);
        s.degraded = reason;
        s.last = .{ .fallback_reason = reason };
    }

    pub fn payload(s: *State, a: std.mem.Allocator, body: []const u8, force_full: bool) ![]const u8 {
        var request = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const input = request.object.fetchOrderedRemove("input").?.value;
        const properties = try std.json.Stringify.valueAlloc(a, request, .{});
        var start: usize = 0;
        var incremental = false;
        var reason: ?[]const u8 = if (force_full) "previous_response_not_found" else s.reset_reason;
        var mismatch: ?usize = null;
        if (!force_full and s.socket != null and s.previous_id != null and s.properties != null and s.baseline != null and std.mem.eql(u8, properties, s.properties.?)) {
            const baseline = try std.json.parseFromSliceLeaky(std.json.Value, a, s.baseline.?, .{});
            mismatch = mismatchIndex(input.array.items, baseline.array.items);
            if (mismatch == null) {
                start = baseline.array.items.len;
                incremental = true;
                reason = null;
                try request.object.put(a, "previous_response_id", .{ .string = s.previous_id.? });
            } else reason = "input_prefix_mismatch";
        } else if (!force_full and s.previous_id != null) {
            reason = if (s.socket == null) "reconnect" else "properties_changed";
            if (s.properties) |old| {
                const previous = try std.json.parseFromSliceLeaky(std.json.Value, a, old, .{});
                const old_reasoning = previous.object.get("reasoning");
                const new_reasoning = request.object.get("reasoning");
                if ((old_reasoning == null) != (new_reasoning == null) or
                    (old_reasoning != null and !equal(old_reasoning.?, new_reasoning.?))) reason = "effort_changed";
            }
        }
        var delta: std.array_list.Managed(std.json.Value) = .init(a);
        try delta.appendSlice(input.array.items[start..]);
        const value: std.json.Value = .{ .array = delta };
        s.last = .{
            .transport = .websocket,
            .incremental = incremental,
            .input_items = delta.items.len,
            .input_bytes = (try std.json.Stringify.valueAlloc(a, value, .{})).len,
            .fallback_reason = s.last.fallback_reason,
            .fallback_at = s.last.fallback_at,
            .fallback_detail = s.last.fallback_detail,
            .full_reason = reason,
            .mismatch_index = mismatch,
        };
        try request.object.put(a, "input", value);
        try request.object.put(a, "type", .{ .string = "response.create" });
        if (s.socket) |socket| if (socket.turn_state) |turn_state| {
            var object: std.json.ObjectMap = .empty;
            try object.put(a, "x-codex-turn-state", .{ .string = turn_state });
            try request.object.put(a, "client_metadata", .{ .object = object });
        };
        return std.json.Stringify.valueAlloc(a, request, .{});
    }

    pub fn remember(s: *State, gpa: std.mem.Allocator, body: []const u8, id: ?[]const u8, output: []const ?std.json.Value) !void {
        s.clearPrevious(gpa);
        s.reset_reason = "missing_response_id";
        const response_id = id orelse return;
        if (response_id.len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var request = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        var input = request.object.fetchOrderedRemove("input").?.value;
        for (output) |maybe| {
            const item = maybe orelse return;
            const normalized = try normalize(a, item) orelse {
                s.reset_reason = "unsupported_output";
                return;
            };
            try input.array.append(normalized);
        }
        const properties = try std.json.Stringify.valueAlloc(gpa, request, .{});
        errdefer gpa.free(properties);
        const baseline = try std.json.Stringify.valueAlloc(gpa, input, .{});
        errdefer gpa.free(baseline);
        s.previous_id = try gpa.dupe(u8, response_id);
        s.properties = properties;
        s.baseline = baseline;
    }
};

fn mismatchIndex(input: []const std.json.Value, baseline: []const std.json.Value) ?usize {
    for (baseline, 0..) |old, i| {
        if (i >= input.len or !equal(old, input[i])) return i;
    }
    return null;
}

fn extends(input: []const std.json.Value, baseline: []const std.json.Value) bool {
    if (input.len < baseline.len) return false;
    for (baseline, input[0..baseline.len]) |old, current| if (!equal(old, current)) return false;
    return true;
}

fn equal(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => a.array.items.len == b.array.items.len and extends(a.array.items, b.array.items),
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| if (!equal(entry.value_ptr.*, b.object.get(entry.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}

pub fn normalize(a: std.mem.Allocator, item: std.json.Value) !?std.json.Value {
    if (item != .object) return null;
    const kind = item.object.get("type") orelse return null;
    if (kind != .string) return null;
    if (std.mem.eql(u8, kind.string, "reasoning")) return item;
    var object: std.json.ObjectMap = .empty;
    if (std.mem.eql(u8, kind.string, "function_call") or std.mem.eql(u8, kind.string, "custom_tool_call")) {
        for ([_][]const u8{ "type", "call_id", "name" }) |key| try object.put(a, key, item.object.get(key) orelse return null);
        const key: []const u8 = if (std.mem.eql(u8, kind.string, "function_call")) "arguments" else "input";
        try object.put(a, key, item.object.get(key) orelse return null);
    } else if (std.mem.eql(u8, kind.string, "message")) {
        const content = item.object.get("content") orelse return null;
        if (content != .array) return null;
        var text: std.Io.Writer.Allocating = .init(a);
        for (content.array.items) |part| {
            if (part != .object) return null;
            const part_type = part.object.get("type") orelse return null;
            if (part_type != .string) return null;
            const key: []const u8 = if (std.mem.eql(u8, part_type.string, "output_text")) "text" else if (std.mem.eql(u8, part_type.string, "refusal")) "refusal" else return null;
            const value = part.object.get(key) orelse return null;
            if (value != .string) return null;
            try text.writer.writeAll(value.string);
        }
        try object.put(a, "role", item.object.get("role") orelse return null);
        try object.put(a, "content", .{ .string = text.written() });
        if (item.object.get("phase")) |phase| if (phase != .null) {
            try object.put(a, "phase", phase);
        };
    } else return null;
    return .{ .object = object };
}

test "continuation requires live connection, same properties and input plus output prefix" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: State = .{};
    defer s.clearPrevious(t.allocator);
    const body = "{\"model\":\"m\",\"input\":[{\"role\":\"user\",\"content\":\"hi\"}]}";
    const item = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"type\":\"message\",\"role\":\"assistant\",\"id\":\"msg1\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}", .{});
    try s.remember(t.allocator, body, "resp1", &.{item});
    s.socket = .{ .connection = undefined };
    const next = "{\"model\":\"m\",\"input\":[{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"assistant\",\"content\":\"hello\"},{\"role\":\"user\",\"content\":\"next\"}]}";
    const delta = try std.json.parseFromSliceLeaky(std.json.Value, a, try s.payload(a, next, false), .{});
    try t.expect(s.last.incremental and s.last.input_items == 1);
    try t.expectEqualStrings("resp1", delta.object.get("previous_response_id").?.string);
    _ = try s.payload(a, next, true);
    try t.expect(!s.last.incremental and s.last.input_items == 3);
    _ = try s.payload(a, body, false);
    try t.expect(!s.last.incremental);
    try t.expectEqualStrings("input_prefix_mismatch", s.last.full_reason.?);
    try t.expectEqual(@as(?usize, 1), s.last.mismatch_index);
    _ = try s.payload(a, "{\"model\":\"other\",\"input\":[]}", false);
    try t.expect(!s.last.incremental);
    for ([_][]const u8{ "instructions", "tools", "reasoning", "text" }) |key| {
        var changed = try std.json.parseFromSliceLeaky(std.json.Value, a, next, .{});
        try changed.object.put(a, key, .{ .string = "changed" });
        _ = try s.payload(a, try std.json.Stringify.valueAlloc(a, changed, .{}), false);
        try t.expect(!s.last.incremental);
    }
    s.socket = null;
    _ = try s.payload(a, next, false);
    try t.expect(!s.last.incremental);
    s.degrade(t.allocator, "WebSocketHandshake");
    try t.expectEqualStrings("WebSocketHandshake", s.degraded.?);
    try t.expect(s.previous_id == null and s.baseline == null and s.last.transport == .sse);
}
