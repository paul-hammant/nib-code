const std = @import("std");
pub const Server = @import("mcp/config.zig").Server;
pub const index = @import("mcp/index.zig");
const Transport = @import("mcp/transport.zig").Transport;
const A = std.mem.Allocator;
const V = std.json.Value;
const field = index.field;
const string = index.string;
pub const protocol_version = "2026-07-28";
pub const legacy_version = "2025-11-25";
pub const timeout_ms = 60_000;
pub const max_message = 16 * 1024 * 1024;

pub const Client = struct {
    gpa: A,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    servers: []State,
    pub const State = struct {
        config: Server,
        transport: Transport,
        catalog: std.heap.ArenaAllocator,
        tools: []const V = &.{},
        failure: ?[]const u8 = null,
        listed: bool = false,
    };

    pub fn create(gpa: A, io: std.Io, configs: []const Server, env: ?*const std.process.Environ.Map, home: []const u8, user_home: []const u8, writable: []const []const u8, sandboxed: bool) !*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .servers = try gpa.alloc(State, configs.len) };
        for (configs, c.servers) |cfg, *entry| entry.* = .{ .config = cfg, .catalog = .init(gpa), .transport = .{ .gpa = gpa, .io = io, .config = cfg, .env = env, .home = home, .user_home = user_home, .writable = writable, .sandboxed = sandboxed } };
        return c;
    }

    pub fn destroy(c: *Client) void {
        for (c.servers) |*s| {
            s.transport.close();
            s.catalog.deinit();
        }
        c.gpa.free(c.servers);
        const gpa = c.gpa;
        gpa.destroy(c);
    }

    pub fn state(c: *Client, id: []const u8) ?*State {
        for (c.servers) |*s| if (std.mem.eql(u8, s.config.id, id)) return s;
        return null;
    }

    pub fn refresh(_: *Client, s: *State, cancel: *const std.atomic.Value(bool)) !void {
        _ = s.catalog.reset(.free_all);
        s.tools = &.{};
        s.failure = null;
        s.listed = false;
        const a = s.catalog.allocator();
        var list: std.ArrayList(V) = .empty;
        var cursor: ?[]const u8 = null;
        var cursors: std.StringHashMap(void) = .init(a);
        s.transport.dirty = false;
        while (true) {
            const params: V = if (cursor) |v| try value(a, .{ .cursor = v }) else .{ .object = .empty };
            const reply = try s.transport.rpc(a, "tools/list", params, cancel);
            const result = try checked(reply);
            const tools = field(result, "tools");
            if (tools != .array) return error.InvalidToolList;
            for (tools.array.items) |tool| {
                const name = string(field(tool, "name")) orelse return error.InvalidToolList;
                if (name.len == 0 or field(tool, "inputSchema") != .object) return error.InvalidToolList;
                if (s.config.url != null and !try @import("mcp/headers.zig").valid(a, field(tool, "inputSchema"))) continue;
                try list.append(a, tool);
            }
            cursor = string(field(result, "nextCursor"));
            if (cursor == null) break;
            const entry = try cursors.getOrPut(cursor.?);
            if (entry.found_existing) return error.RepeatedCursor;
        }
        s.tools = list.items;
        s.listed = true;
    }

    pub fn prompt(c: *Client, a: A, base: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var cancel: std.atomic.Value(bool) = .init(false);
        for (c.servers) |*s| {
            if (!s.config.enabled) continue;
            if (out.items.len == 0) try out.appendSlice(a, "\n<mcp_tools>\n");
            c.refresh(s, &cancel) catch |err| {
                s.failure = try s.catalog.allocator().dupe(u8, @errorName(err));
            };
            s.transport.close();
            if (s.failure) |failure| try out.print(a, "{s}: failed: {s}\n", .{ s.config.id, failure }) else try index.append(a, &out, s.config.id, s.tools);
        }
        if (out.items.len == 0) return base;
        try out.appendSlice(a, "</mcp_tools>\n");
        return std.fmt.allocPrint(a, "{s}{s}", .{ base, out.items });
    }

    pub fn schema(c: *Client, a: A, target: []const u8, cancel: *const std.atomic.Value(bool)) !V {
        const parts = try split(target);
        const s = c.state(parts.server) orelse return error.UnknownServer;
        if (!s.config.enabled) return error.DisabledServer;
        try s.transport.ensure(a, cancel);
        const cached = s.listed and !s.transport.dirty;
        if (!cached) try c.refresh(s, cancel);
        for (s.tools) |tool| if (std.mem.eql(u8, string(field(tool, "name")).?, parts.tool)) return field(tool, "inputSchema");
        if (!cached) return error.UnknownTool;
        try c.refresh(s, cancel);
        for (s.tools) |tool| if (std.mem.eql(u8, string(field(tool, "name")).?, parts.tool)) return field(tool, "inputSchema");
        return error.UnknownTool;
    }

    pub fn call(c: *Client, a: A, target: []const u8, args: V, cancel: *const std.atomic.Value(bool)) !V {
        const schema_value = try c.schema(a, target, cancel);
        const parts = try split(target);
        const s = c.state(parts.server).?;
        s.transport.schema = schema_value;
        defer s.transport.schema = .null;
        const reply = try s.transport.rpc(a, "tools/call", try value(a, .{ .name = parts.tool, .arguments = args }), cancel);
        const result = try checked(reply);
        if (std.mem.eql(u8, string(field(result, "resultType")) orelse "complete", "input_required")) return error.UnsupportedServerInput;
        return result;
    }
};

pub fn split(target: []const u8) !struct { server: []const u8, tool: []const u8 } {
    const dot = std.mem.indexOfScalar(u8, target, '.') orelse return error.InvalidToolName;
    if (dot == 0 or dot + 1 == target.len) return error.InvalidToolName;
    return .{ .server = target[0..dot], .tool = target[dot + 1 ..] };
}

pub fn value(a: A, v: anytype) !V {
    return std.json.parseFromSliceLeaky(V, a, try std.json.Stringify.valueAlloc(a, v, .{}), .{});
}
pub fn checked(reply: V) !V {
    if (field(reply, "error") != .null) return error.ServerError;
    const result = field(reply, "result");
    if (result != .object) return error.InvalidResponse;
    return result;
}

test {
    _ = @import("mcp/index.zig");
    _ = @import("mcp/transport.zig");
    _ = @import("mcp/headers.zig");
}
