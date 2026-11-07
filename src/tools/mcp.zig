const std = @import("std");
const tools = @import("../tools.zig");
const sandbox = @import("../sandbox.zig");
const client = @import("../mcp.zig");
const image = @import("../image.zig");
const V = std.json.Value;
const field = client.index.field;
const string = client.index.string;

fn failure(a: std.mem.Allocator, message: []const u8) !sandbox.ToolResult {
    return .{ .ok = try std.json.Stringify.valueAlloc(a, .{ .ok = false, .content = "", .@"error" = message }, .{}) };
}

pub fn mcp(t: *tools.Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    return execute(t, gpa, args, false);
}
pub fn mcp_schema(t: *tools.Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    return execute(t, gpa, args, true);
}

fn execute(t: *tools.Tools, gpa: std.mem.Allocator, args: []const u8, schema: bool) !sandbox.ToolResult {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const input = std.json.parseFromSliceLeaky(V, a, args, .{}) catch return tools.fail(gpa, "expected a server.tool name and argument object", .{});
    const name = string(field(input, "name")) orelse return tools.fail(gpa, "expected a server.tool name", .{});
    _ = client.split(name) catch return tools.fail(gpa, "expected server.tool", .{});
    const arguments = field(input, "arguments");
    if (!schema and arguments != .object) return tools.fail(gpa, "arguments must be an object", .{});
    const c = t.mcp_client orelse return failure(gpa, "MCP is unavailable");
    c.mutex.lockUncancelable(t.io);
    defer c.mutex.unlock(t.io);
    if (schema) {
        const result = c.schema(a, name, t.cancelFlag()) catch |err| return failure(gpa, @errorName(err));
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, result, .{}) };
    }
    const result = c.call(a, name, arguments, t.cancelFlag()) catch |err| {
        const parts = try client.split(name);
        if (c.state(parts.server)) |s| s.failure = try s.catalog.allocator().dupe(u8, @errorName(err));
        const message = if (err == error.ServerError) if (c.state(parts.server)) |s| s.transport.last_error orelse @errorName(err) else @errorName(err) else @errorName(err);
        return failure(gpa, message);
    };
    var content: std.ArrayList(u8) = .empty;
    try mapContent(t, gpa, a, &content, field(result, "content"));
    const is_error = field(result, "isError");
    const ok = !(is_error == .bool and is_error.bool);
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = ok, .content = content.items, .structured = field(result, "structuredContent"), .@"error" = if (ok) null else @as(?[]const u8, if (content.items.len > 0) content.items else "MCP tool failed") }, .{}) };
}

fn mapContent(t: *tools.Tools, gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), content: V) !void {
    if (content != .array) return;
    for (content.array.items, 0..) |item, i| {
        if (i > 0) try out.append(a, '\n');
        const kind = string(field(item, "type")) orelse "unknown";
        if (std.mem.eql(u8, kind, "text")) {
            try out.appendSlice(a, string(field(item, "text")) orelse "");
        } else if (std.mem.eql(u8, kind, "image")) {
            const status = attach(t, gpa, a, item) catch |err| try std.fmt.allocPrint(a, "[image omitted: {s}]", .{@errorName(err)});
            try out.appendSlice(a, status);
        } else if (std.mem.eql(u8, kind, "resource_link")) {
            try out.print(a, "[resource link: {s}]", .{string(field(item, "uri")) orelse ""});
        } else if (std.mem.eql(u8, kind, "resource")) {
            try out.print(a, "[resource: {s}]", .{string(field(field(item, "resource"), "uri")) orelse ""});
        } else if (std.mem.eql(u8, kind, "audio")) try out.appendSlice(a, "[audio omitted]") else try out.appendSlice(a, "[unsupported content omitted]");
    }
}

fn attach(t: *tools.Tools, gpa: std.mem.Allocator, a: std.mem.Allocator, item: V) ![]const u8 {
    if (t.cfg) |cfg| if (!cfg.vision()) return "[image omitted]";
    if (t.viewedImages() >= image.max_per_run) return "[image omitted: Run image limit]";
    const home = t.data_home orelse return "[image omitted]";
    const id = t.session_id orelse return "[image omitted]";
    const data = string(field(item, "data")) orelse return error.InvalidImage;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(data);
    if (size > image.max_bytes) return error.ImageTooLarge;
    const bytes = try a.alloc(u8, size);
    try std.base64.standard.Decoder.decode(bytes, data);
    const directory = try std.fmt.allocPrint(a, "{s}/sessions/{s}.images", .{ home, id });
    const stored = try image.store(t.io, gpa, directory, "mcp", bytes);
    errdefer stored.deinit(gpa);
    if (!try t.attachImage(gpa, stored)) {
        stored.deinit(gpa);
        return "[image omitted: Run image limit]";
    }
    return "[image attached]";
}

test "MCP content text and nonvision images keep full text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: tools.Tools = .{ .io = std.testing.io, .home = "/unused", .cfg = .{ .provider = .deepseek, .base_url = "", .api_key = "", .model = "deepseek-flash" } };
    const content = try std.json.parseFromSliceLeaky(V, a, "[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"image\",\"data\":\"fake\"},{\"type\":\"audio\"}]", .{});
    var out: std.ArrayList(u8) = .empty;
    try mapContent(&t, std.testing.allocator, a, &out, content);
    try std.testing.expectEqualStrings("hello\n[image omitted]\n[audio omitted]", out.items);
    const empty = try std.json.parseFromSliceLeaky(V, a, "[{\"type\":\"text\",\"text\":\"\"},{\"type\":\"text\",\"text\":\"next\"},{\"type\":\"text\",\"text\":\"\"}]", .{});
    out = .empty;
    try mapContent(&t, std.testing.allocator, a, &out, empty);
    try std.testing.expectEqualStrings("\nnext\n", out.items);
}
