const std = @import("std");
const sse = @import("../sse.zig");

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    context_window: u64 = 128_000,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    /// DeepSeek reports prompt-cache hits under this name.
    prompt_cache_hit_tokens: u64 = 0,

    pub fn add(u: *Usage, other: Usage) void {
        u.prompt_tokens += other.prompt_tokens;
        u.completion_tokens += other.completion_tokens;
        u.prompt_cache_hit_tokens += other.prompt_cache_hit_tokens;
    }
};

/// Allocated with the `out` allocator passed to `stream`.
pub const Reply = struct {
    text: []const u8,
    tool_calls: []const ToolCall,
    usage: Usage,
};

pub const Kind = enum { text, reasoning };

pub const Sink = struct {
    ctx: *anyopaque,
    onDelta: *const fn (ctx: *anyopaque, kind: Kind, text: []const u8) anyerror!void,
};

const Chunk = struct {
    choices: []const struct {
        delta: struct {
            content: ?[]const u8 = null,
            reasoning_content: ?[]const u8 = null,
            tool_calls: []const struct {
                index: usize = 0,
                id: ?[]const u8 = null,
                function: struct {
                    name: ?[]const u8 = null,
                    arguments: ?[]const u8 = null,
                } = .{},
            } = &.{},
        } = .{},
    } = &.{},
    usage: ?Usage = null,
};

const PartialCall = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,

    fn deinit(p: *PartialCall, gpa: std.mem.Allocator) void {
        p.id.deinit(gpa);
        p.name.deinit(gpa);
        p.args.deinit(gpa);
    }
};

/// On `error.HttpStatus` or `error.HttpTransient` (429, 5xx), `detail` holds
/// the response body (caller frees).
pub fn stream(
    gpa: std.mem.Allocator,
    out: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    messages: []const Message,
    tools_json: []const u8,
    max_tokens: ?u32,
    sink: Sink,
    cancel: *const std.atomic.Value(bool),
    detail: *?[]u8,
) !Reply {
    const url = try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{cfg.base_url});
    defer gpa.free(url);
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{cfg.api_key});
    defer gpa.free(auth);
    const body = try requestBody(gpa, cfg.model, messages, tools_json, max_tokens);
    defer gpa.free(body);

    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .redirect_behavior = .not_allowed,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    const buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buf);
    const reader = response.reader(buf);

    if (response.head.status.class() != .success) {
        const status = @backingInt(response.head.status);
        const text = reader.allocRemaining(gpa, .limited(64 * 1024)) catch "";
        defer if (text.len > 0) gpa.free(text);
        detail.* = try std.fmt.allocPrint(gpa, "HTTP {d}: {s}", .{ status, text });
        return if (status == 429 or status >= 500) error.HttpTransient else error.HttpStatus;
    }

    var parser: sse.Parser = .{};
    defer parser.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var calls: std.ArrayList(PartialCall) = .empty;
    defer {
        for (calls.items) |*p| p.deinit(gpa);
        calls.deinit(gpa);
    }

    var usage: Usage = .{};
    var done = false;
    while (true) {
        if (cancel.load(.acquire)) return error.Canceled;
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => return err,
        } orelse break;
        const data = (try parser.feed(gpa, line)) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) {
            done = true;
            break;
        }

        defer _ = arena.reset(.retain_capacity);
        const chunk = std.json.parseFromSliceLeaky(Chunk, arena.allocator(), data, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidResponse;
        if (chunk.usage) |u| usage = u;
        for (chunk.choices) |choice| {
            const d = choice.delta;
            if (d.reasoning_content) |t| if (t.len > 0) try sink.onDelta(sink.ctx, .reasoning, t);
            if (d.content) |t| if (t.len > 0) {
                try text.appendSlice(gpa, t);
                try sink.onDelta(sink.ctx, .text, t);
            };
            for (d.tool_calls) |tc| {
                if (tc.index > 64) return error.TooManyToolCalls;
                while (calls.items.len <= tc.index) try calls.append(gpa, .{});
                const p = &calls.items[tc.index];
                if (tc.id) |s| try p.id.appendSlice(gpa, s);
                if (tc.function.name) |s| try p.name.appendSlice(gpa, s);
                if (tc.function.arguments) |s| try p.args.appendSlice(gpa, s);
            }
        }
    }

    if (!done) return error.IncompleteResponse;
    for (calls.items) |p| {
        if (p.id.items.len == 0 or p.name.items.len == 0) return error.InvalidResponse;
    }
    const tool_calls = try out.alloc(ToolCall, calls.items.len);
    for (calls.items, tool_calls) |p, *tc| tc.* = .{
        .id = try out.dupe(u8, p.id.items),
        .function = .{ .name = try out.dupe(u8, p.name.items), .arguments = try out.dupe(u8, p.args.items) },
    };
    return .{ .text = try out.dupe(u8, text.items), .tool_calls = tool_calls, .usage = usage };
}

fn requestBody(gpa: std.mem.Allocator, model: []const u8, messages: []const Message, tools_json: []const u8, max_tokens: ?u32) ![]u8 {
    const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const limit = if (max_tokens) |n| try std.fmt.allocPrint(gpa, ",\"max_tokens\":{d}", .{n}) else try gpa.dupe(u8, "");
    defer gpa.free(limit);
    const tool_field = if (std.mem.eql(u8, tools_json, "[]")) try gpa.dupe(u8, "") else try std.fmt.allocPrint(gpa, ",\"tools\":{s}", .{tools_json});
    defer gpa.free(tool_field);
    return std.fmt.allocPrint(gpa,
        \\{{"model":{f},"messages":{f}{s}{s},"stream":true,"stream_options":{{"include_usage":true}}}}
    , .{ std.json.fmt(model, opts), std.json.fmt(messages, opts), tool_field, limit });
}

test "chunk decodes deepseek deltas, tool call fragments and usage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try std.json.parseFromSliceLeaky(Chunk, arena.allocator(),
        \\{"id":"x","choices":[{"index":0,"delta":{"content":"hi","reasoning_content":null,
        \\  "tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"run","arguments":"{\"co"}}]}}],
        \\ "usage":{"prompt_tokens":5,"completion_tokens":1,"prompt_cache_hit_tokens":4,"total_tokens":6}}
    , .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("hi", c.choices[0].delta.content.?);
    try std.testing.expectEqualStrings("{\"co", c.choices[0].delta.tool_calls[0].function.arguments.?);
    try std.testing.expectEqual(@as(u64, 4), c.usage.?.prompt_cache_hit_tokens);
}

test "request body omits null fields and absent tools" {
    const gpa = std.testing.allocator;
    const msgs = [_]Message{
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .content = "", .tool_calls = &.{.{ .id = "c1", .function = .{ .name = "run", .arguments = "{}" } }} },
        .{ .role = "tool", .content = "ok", .tool_call_id = "c1" },
    };
    const body = try requestBody(gpa, "m", &msgs, "[]", null);
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        \\{"model":"m","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"run","arguments":"{}"}}]},{"role":"tool","content":"ok","tool_call_id":"c1"}],"stream":true,"stream_options":{"include_usage":true}}
    , body);
}

test "summary request limits output and omits tools" {
    const t = std.testing;
    const body = try requestBody(t.allocator, "m", &.{.{ .role = "user", .content = "summary" }}, "[]", 512);
    defer t.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
    defer parsed.deinit();
    try t.expect(!parsed.value.object.contains("tools"));
    try t.expectEqual(@as(i64, 512), parsed.value.object.get("max_tokens").?.integer);
}
