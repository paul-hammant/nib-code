const std = @import("std");
const index = @import("index.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
const field = index.field;
const string = index.string;

pub fn encode(a: A, text: []const u8) ![]const u8 {
    var safe = std.mem.eql(u8, text, std.mem.trim(u8, text, " \t")) and !(std.mem.startsWith(u8, text, "=?base64?") and std.mem.endsWith(u8, text, "?="));
    for (text) |c| if (c < 0x20 or c > 0x7e) {
        safe = false;
    };
    if (safe) return text;
    const codec = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, codec.calcSize(text.len));
    return std.fmt.allocPrint(a, "=?base64?{s}?=", .{codec.encode(encoded, text)});
}

pub fn valid(a: A, schema: V) !bool {
    var names: std.StringHashMap(void) = .init(a);
    return validate(a, schema, true, &names);
}
fn validate(a: A, schema: V, reachable: bool, names: *std.StringHashMap(void)) anyerror!bool {
    if (schema == .array) {
        for (schema.array.items) |v| if (!try validate(a, v, false, names)) return false;
    }
    if (schema != .object) return true;
    const annotation = field(schema, "x-mcp-header");
    if (annotation != .null) {
        const name = string(annotation) orelse return false;
        if (!reachable or name.len == 0) return false;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
        const t = string(field(schema, "type")) orelse return false;
        if (!std.mem.eql(u8, t, "string") and !std.mem.eql(u8, t, "integer") and !std.mem.eql(u8, t, "boolean")) return false;
        const entry = try names.getOrPut(try std.ascii.allocLowerString(a, name));
        if (entry.found_existing) return false;
    }
    var it = schema.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "properties") and entry.value_ptr.* == .object) {
            var props = entry.value_ptr.object.iterator();
            while (props.next()) |p| if (!try validate(a, p.value_ptr.*, reachable, names)) return false;
        } else if (!try validate(a, entry.value_ptr.*, false, names)) return false;
    }
    return true;
}

pub fn append(a: A, headers: *std.ArrayList(std.http.Header), schema: V, args: V) anyerror!void {
    if (field(schema, "x-mcp-header") == .string and args != .null) {
        const kind = string(field(schema, "type")) orelse return error.InvalidHeaderParameter;
        if ((std.mem.eql(u8, kind, "string") and args != .string) or (std.mem.eql(u8, kind, "boolean") and args != .bool) or (std.mem.eql(u8, kind, "integer") and (args != .integer or args.integer < -9007199254740991 or args.integer > 9007199254740991))) return error.InvalidHeaderParameter;
        const text = if (args == .string) args.string else try std.json.Stringify.valueAlloc(a, args, .{});
        try headers.append(a, .{ .name = try std.fmt.allocPrint(a, "Mcp-Param-{s}", .{field(schema, "x-mcp-header").string}), .value = try encode(a, text) });
    }
    const props = field(schema, "properties");
    if (props == .object and args == .object) {
        var it = props.object.iterator();
        while (it.next()) |entry| try append(a, headers, entry.value_ptr.*, field(args, entry.key_ptr.*));
    }
}

test "header encoding and annotation validation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hello", try encode(a, "hello"));
    try std.testing.expectEqualStrings("=?base64?eAo=?=", try encode(a, "x\n"));
    const good = try std.json.parseFromSliceLeaky(V, a, "{\"properties\":{\"q\":{\"type\":\"string\",\"x-mcp-header\":\"Query\"}}}", .{});
    try std.testing.expect(try valid(a, good));
    const bad = try std.json.parseFromSliceLeaky(V, a, "{\"items\":{\"type\":\"string\",\"x-mcp-header\":\"Q\"}}", .{});
    try std.testing.expect(!try valid(a, bad));
}
