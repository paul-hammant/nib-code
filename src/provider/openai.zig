//! OpenAI-compatible Chat Completions with streaming. Covers DeepSeek,
//! OpenRouter, vLLM, Ollama and friends.

const std = @import("std");
const sse = @import("../sse.zig");

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    /// DeepSeek reports prompt-cache hits under this name.
    prompt_cache_hit_tokens: u64 = 0,
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
        } = .{},
    } = &.{},
    usage: ?Usage = null,
};

/// Stream one completion. On a non-2xx status returns `error.HttpStatus` and
/// sets `detail` to the response body (caller frees).
pub fn stream(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    messages: []const Message,
    sink: Sink,
    cancel: *const std.atomic.Value(bool),
    detail: *?[]u8,
) !Usage {
    const url = try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{cfg.base_url});
    defer gpa.free(url);
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{cfg.api_key});
    defer gpa.free(auth);
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .model = cfg.model,
        .messages = messages,
        .stream = true,
        .stream_options = .{ .include_usage = true },
    }, .{});
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
        const status = @intFromEnum(response.head.status);
        const text = reader.allocRemaining(gpa, .limited(64 * 1024)) catch "";
        defer if (text.len > 0) gpa.free(text);
        detail.* = try std.fmt.allocPrint(gpa, "HTTP {d}: {s}", .{ status, text });
        return error.HttpStatus;
    }

    var parser: sse.Parser = .{};
    defer parser.deinit(gpa);
    // One arena for all chunk parses, reset after each: no per-delta heap churn.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var usage: Usage = .{};
    while (true) {
        if (cancel.load(.acquire)) return error.Canceled;
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => return err,
        } orelse break;
        const data = (try parser.feed(gpa, line)) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        defer _ = arena.reset(.retain_capacity);
        const chunk = std.json.parseFromSliceLeaky(Chunk, arena.allocator(), data, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (chunk.usage) |u| usage = u;
        for (chunk.choices) |choice| {
            if (choice.delta.reasoning_content) |t| if (t.len > 0) try sink.onDelta(sink.ctx, .reasoning, t);
            if (choice.delta.content) |t| if (t.len > 0) try sink.onDelta(sink.ctx, .text, t);
        }
    }
    return usage;
}

test "chunk decodes deepseek deltas and usage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try std.json.parseFromSliceLeaky(Chunk, arena.allocator(),
        \\{"id":"x","choices":[{"index":0,"delta":{"content":"hi","reasoning_content":null}}],
        \\ "usage":{"prompt_tokens":5,"completion_tokens":1,"prompt_cache_hit_tokens":4,"total_tokens":6}}
    , .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("hi", c.choices[0].delta.content.?);
    try std.testing.expectEqual(@as(u64, 4), c.usage.?.prompt_cache_hit_tokens);
}
