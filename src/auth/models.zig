//! Model listing for custom endpoints: `GET <base>/models` (OpenAI style) or
//! `<base>/v1/models` (Anthropic). Only used when adding an endpoint.

const std = @import("std");
const provider = @import("../provider.zig");

pub const Listed = struct { id: []const u8, context_window: ?u64 = null };

pub fn url(a: std.mem.Allocator, base_url: []const u8, protocol: provider.Protocol) ![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    return switch (protocol) {
        .anthropic_messages => std.fmt.allocPrint(a, "{s}/v1/models?limit=1000", .{base}),
        else => std.fmt.allocPrint(a, "{s}/models", .{base}),
    };
}

fn windowOf(item: std.json.ObjectMap) ?u64 {
    for ([_][]const u8{ "context_window", "context_length", "max_context_length", "max_input_tokens" }) |name| {
        const value = item.get(name) orelse continue;
        switch (value) {
            .integer => |n| if (n > 0) return @intCast(n),
            .float => |f| if (f >= 1) return @intFromFloat(f),
            else => {},
        }
    }
    return null;
}

/// `{ "data": [ { "id": ..., ... } ] }`; entries without a string id are skipped.
pub fn parse(a: std.mem.Allocator, body: []const u8) ![]const Listed {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.InvalidModelList;
    if (root != .object) return error.InvalidModelList;
    const data = root.object.get("data") orelse return error.InvalidModelList;
    if (data != .array) return error.InvalidModelList;
    var out: std.ArrayList(Listed) = .empty;
    for (data.array.items) |item| {
        if (item != .object) continue;
        const id = item.object.get("id") orelse continue;
        if (id != .string or id.string.len == 0) continue;
        try out.append(a, .{ .id = id.string, .context_window = windowOf(item.object) });
    }
    return out.toOwnedSlice(a);
}

pub fn fetch(a: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, protocol: provider.Protocol, key: []const u8) ![]const Listed {
    var response: std.Io.Writer.Allocating = .init(a);
    const target = try url(a, base_url, protocol);
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{key});
    const anthropic = protocol == .anthropic_messages;
    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "x-api-key", .value = key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };
    const result = try client.fetch(.{
        .location = .{ .url = target },
        .method = .GET,
        .headers = .{ .authorization = if (key.len > 0 and !anthropic) .{ .override = bearer } else .omit },
        .extra_headers = if (anthropic) (if (key.len > 0) headers[0..] else headers[0..1]) else headers[0..1],
        .response_writer = &response.writer,
    });
    const status = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return error.ModelListRejected;
    return parse(a, response.written());
}

const testing = std.testing;

test "model list URLs follow the protocol" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://h/v1/models", try url(a, "https://h/v1/", .chat_completions));
    try testing.expectEqualStrings("https://h/models", try url(a, "https://h", .responses));
    try testing.expectEqualStrings("https://h/v1/models?limit=1000", try url(a, "https://h/", .anthropic_messages));
}

test "model lists parse ids and optional windows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parse(a, "{\"object\":\"list\",\"data\":[{\"id\":\"a\"},{\"id\":\"b\",\"context_length\":32768},{\"nope\":1},{\"id\":\"\"},{\"id\":\"c\",\"max_input_tokens\":200000},3]}");
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("a", list[0].id);
    try testing.expect(list[0].context_window == null);
    try testing.expectEqual(@as(u64, 32768), list[1].context_window.?);
    try testing.expectEqual(@as(u64, 200000), list[2].context_window.?);
    try testing.expectError(error.InvalidModelList, parse(a, "[]"));
    try testing.expectError(error.InvalidModelList, parse(a, "{\"data\":1}"));
    try testing.expectError(error.InvalidModelList, parse(a, "<html>"));
    try testing.expectEqual(@as(usize, 0), (try parse(a, "{\"data\":[]}")).len);
}
