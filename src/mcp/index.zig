const std = @import("std");
const A = std.mem.Allocator;
const V = std.json.Value;
pub const max_tools = 40;
pub const max_description = 120;

pub fn field(v: V, name: []const u8) V {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}
pub fn string(v: V) ?[]const u8 {
    return if (v == .string) v.string else null;
}

fn kind(a: A, out: *std.ArrayList(u8), schema: V) anyerror!void {
    const values = field(schema, "enum");
    if (values == .array and values.array.items.len > 0 and values.array.items.len <= 8 and (try std.json.Stringify.valueAlloc(a, values, .{})).len <= 120) {
        for (values.array.items, 0..) |v, i| {
            if (i > 0) try out.appendSlice(a, "|");
            try out.print(a, "{f}", .{std.json.fmt(v, .{})});
        }
        return;
    }
    const t = string(field(schema, "type")) orelse "unknown";
    if (std.mem.eql(u8, t, "object")) return out.appendSlice(a, "{…}");
    if (std.mem.eql(u8, t, "array")) {
        try kind(a, out, field(schema, "items"));
        return out.appendSlice(a, "[]");
    }
    const primitive = for ([_][]const u8{ "string", "boolean", "number", "null" }) |name| {
        if (std.mem.eql(u8, t, name)) break name;
    } else if (std.mem.eql(u8, t, "integer")) "number" else "unknown";
    try out.appendSlice(a, primitive);
}

fn compact(a: A, text: []const u8, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (out.items.len >= max) break;
        try out.append(a, if (std.ascii.isWhitespace(c) or c < 0x20 or c == 0x7f) ' ' else c);
    }
    while (out.items.len > 0 and !std.unicode.utf8ValidateSlice(out.items)) _ = out.pop();
    return out.items;
}

pub fn signature(a: A, schema: V) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const properties = field(schema, "properties");
    if (properties != .object) return "";
    const required = field(schema, "required");
    var it = properties.object.iterator();
    while (it.next()) |entry| {
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        const mandatory = if (required == .array) for (required.array.items) |v| {
            if (v == .string and std.mem.eql(u8, v.string, entry.key_ptr.*)) break true;
        } else false else false;
        try out.print(a, "{s}{s}: ", .{ try compact(a, entry.key_ptr.*, 40), if (mandatory) "" else "?" });
        try kind(a, &out, entry.value_ptr.*);
        if (out.items.len >= 200) {
            try out.appendSlice(a, ", …");
            break;
        }
    }
    return out.items;
}

pub fn append(a: A, out: *std.ArrayList(u8), id: []const u8, tools: []const V) !void {
    for (tools[0..@min(max_tools, tools.len)]) |tool| {
        const name = string(field(tool, "name")) orelse continue;
        const description = string(field(tool, "description")) orelse "";
        const end = for (description, 0..) |c, i| {
            if (std.mem.indexOfScalar(u8, ".!?", c) != null and (i + 1 == description.len or std.ascii.isWhitespace(description[i + 1]))) break i + 1;
        } else description.len;
        try out.print(a, "{s}.{s}({s}) — {s}\n", .{ id, try compact(a, name, name.len), try signature(a, field(tool, "inputSchema")), try compact(a, description[0..end], max_description) });
    }
    if (tools.len > max_tools) try out.print(a, "{s}: {d} tools omitted; use tools.mcp_schema(\"server.tool\") for full schemas.\n", .{ id, tools.len - max_tools });
}

test "compact schema signature preserves required, enums and nested objects" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try std.json.parseFromSliceLeaky(V, a,
        \\{"properties":{"q":{"type":"string"},"limit":{"type":"integer"},"state":{"enum":["open","closed"]},"filter":{"type":"object"}},"required":["q"]}
    , .{});
    try std.testing.expectEqualStrings("q: string, limit?: number, state?: \"open\"|\"closed\", filter?: {…}", try signature(a, schema));
}

test "index caps tools and descriptions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tool = try std.json.parseFromSliceLeaky(V, a, "{\"name\":\"search\",\"description\":\"First sentence. Second sentence.\",\"inputSchema\":{}}", .{});
    const tools = try a.alloc(V, 43);
    @memset(tools, tool);
    var out: std.ArrayList(u8) = .empty;
    try append(a, &out, "docs", tools);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "3 tools omitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Second sentence") == null);
    const long_name = "search_search_search_search_search_search_search_search_search_search_search_search_search_search_search_search_";
    const named = try @import("../mcp.zig").value(a, .{ .name = long_name, .inputSchema = V{ .object = .empty } });
    out = .empty;
    try append(a, &out, "docs", &.{named});
    try std.testing.expect(std.mem.indexOf(u8, out.items, long_name) != null);
}
