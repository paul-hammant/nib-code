const std = @import("std");
const p = @import("../provider.zig");
const sse = @import("../sse.zig");

const Model = struct { id: []const u8, context_window: u64, can_disable_reasoning: bool = true };
const models = [_]Model{
    .{ .id = "gpt-6.1-terra", .context_window = 500_000 },
    .{ .id = "gpt-6.1-sol", .context_window = 500_000, .can_disable_reasoning = false },
    .{ .id = "gpt-6-astra", .context_window = 272_000, .can_disable_reasoning = false },
    .{ .id = "gpt-6-sol", .context_window = 272_000 },
    .{ .id = "gpt-6-luna", .context_window = 272_000 },
    .{ .id = "gpt-5.6-luna", .context_window = 272_000 },
    .{ .id = "gpt-5.6-sol", .context_window = 272_000 },
    .{ .id = "gpt-5.6-terra", .context_window = 272_000 },
};
pub const default_model = models[1].id;

fn modelInfo(id: []const u8) ?Model {
    for (models) |model| if (std.mem.eql(u8, id, model.id)) return model;
    return null;
}

pub fn contextWindow(model: []const u8) !u64 {
    return (modelInfo(model) orelse return error.UnknownCodexModelContextWindow).context_window;
}

pub fn reasoningEffort(cfg: p.Config) ?[]const u8 {
    if (cfg.thinking == false) {
        if (modelInfo(cfg.model)) |model| if (!model.can_disable_reasoning) return "low";
        return "none";
    }
    return cfg.reasoning_effort orelse if (cfg.thinking == true) @as(?[]const u8, "medium") else null;
}

pub fn reasoningText(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    const items = try std.json.parseFromSlice([]const struct { summary: []const struct { text: []const u8 } = &.{} }, a, data, .{ .ignore_unknown_fields = true });
    defer items.deinit();
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (items.value) |item| for (item.summary) |part| {
        if (text.items.len > 0) try text.appendSlice(a, "\n\n");
        try text.appendSlice(a, part.text);
    };
    return text.toOwnedSlice(a);
}

const Credentials = struct {
    tokens: struct { access_token: []const u8, account_id: []const u8 },
};

fn credentials(gpa: std.mem.Allocator, io: std.Io, cfg: p.Config, detail: *?[]u8) !std.json.Parsed(Credentials) {
    const path = try std.fs.path.join(gpa, &.{ cfg.codex_home orelse return authError(gpa, detail, "Codex credentials unavailable; run codex to log in."), "auth.json" });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch
        return authError(gpa, detail, "Cannot read Codex auth.json; run codex to log in (or check CODEX_HOME).");
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(Credentials, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return authError(gpa, detail, "Invalid Codex auth.json; run codex to log in again.");
    if (parsed.value.tokens.access_token.len == 0 or parsed.value.tokens.account_id.len == 0 or
        std.mem.indexOfAny(u8, parsed.value.tokens.access_token, "\r\n") != null or
        std.mem.indexOfAny(u8, parsed.value.tokens.account_id, "\r\n") != null)
    {
        parsed.deinit();
        return authError(gpa, detail, "Incomplete Codex credentials; run codex to log in again.");
    }
    return parsed;
}

fn authError(gpa: std.mem.Allocator, detail: *?[]u8, message: []const u8) !std.json.Parsed(Credentials) {
    detail.* = try gpa.dupe(u8, message);
    return error.InvalidCredentials;
}

pub fn stream(gpa: std.mem.Allocator, out: std.mem.Allocator, client: *std.http.Client, cfg: p.Config, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !p.Reply {
    const body = try requestBody(gpa, cfg, messages, tools_json, max_tokens);
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(gpa, "{s}/codex/responses", .{std.mem.trimEnd(u8, cfg.base_url, "/")});
    defer gpa.free(url);
    for (0..2) |attempt| {
        const auth = try credentials(gpa, client.io, cfg, detail);
        defer auth.deinit();
        const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{auth.value.tokens.access_token});
        defer gpa.free(bearer);
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .redirect_behavior = .not_allowed,
            .headers = .{ .authorization = .{ .override = bearer }, .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
            .extra_headers = &.{
                .{ .name = "accept", .value = "text/event-stream" },
                .{ .name = "chatgpt-account-id", .value = auth.value.tokens.account_id },
                .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
                .{ .name = "originator", .value = "nib" },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        var writer = try req.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(body);
        try writer.end();
        try req.connection.?.flush();
        var response = try req.receiveHead(&.{});
        const buffer = try gpa.alloc(u8, 64 * 1024);
        defer gpa.free(buffer);
        const reader = response.reader(buffer);
        const status = @backingInt(response.head.status);
        if (status == 401) {
            if (attempt == 0) continue;
            detail.* = try gpa.dupe(u8, "Codex authentication expired or was revoked (HTTP 401); run codex to log in again.");
            return error.HttpStatus;
        }
        if (response.head.status.class() != .success) {
            detail.* = try std.fmt.allocPrint(gpa, "Codex request failed (HTTP {d})", .{status});
            return if (status == 429 or status >= 500) error.HttpTransient else error.HttpStatus;
        }
        return readStream(gpa, out, reader, sink, cancel, detail);
    }
    unreachable;
}

fn requestBody(gpa: std.mem.Allocator, cfg: p.Config, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var input: std.Io.Writer.Allocating = .init(a);
    const w = &input.writer;
    try w.writeByte('[');
    var separator: []const u8 = "";
    var instructions: []const u8 = "You are a helpful assistant.";
    for (messages, 0..) |m, index| {
        if (std.mem.eql(u8, m.role, "system")) {
            instructions = m.content orelse instructions;
            continue;
        }
        if (m.reasoning) |r| if (r.provider == .codex) {
            const items = try std.json.parseFromSliceLeaky([]const std.json.Value, a, r.data, .{});
            for (items) |item| {
                try w.print("{s}{f}", .{ separator, std.json.fmt(item, .{}) });
                separator = ",";
            }
        };
        if (std.mem.eql(u8, m.role, "tool")) {
            try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .type = "function_call_output", .call_id = m.tool_call_id, .output = m.content orelse "" }, .{}) });
            separator = ",";
            continue;
        }
        if (m.content) |text| if (text.len > 0) {
            const content = if (max_tokens != null and std.mem.eql(u8, m.role, "user") and index == messages.len - 1)
                try std.fmt.allocPrint(a, "{s}\nKeep the summary within {d} tokens.", .{ text, max_tokens.? })
            else
                text;
            try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .role = m.role, .content = content, .phase = m.phase }, .{ .emit_null_optional_fields = false }) });
            separator = ",";
        };
        for (m.tool_calls orelse &.{}) |call| {
            try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .type = "function_call", .call_id = call.id, .name = call.function.name, .arguments = call.function.arguments }, .{}) });
            separator = ",";
        }
    }
    try w.writeByte(']');
    const tools = try std.json.parseFromSliceLeaky([]const struct { function: struct { name: []const u8, description: []const u8, parameters: std.json.Value } }, a, tools_json, .{ .ignore_unknown_fields = true });
    var tool_writer: std.Io.Writer.Allocating = .init(a);
    try tool_writer.writer.writeByte('[');
    for (tools, 0..) |tool, i| try tool_writer.writer.print("{s}{f}", .{ if (i == 0) @as([]const u8, "") else ",", std.json.fmt(.{ .type = "function", .name = tool.function.name, .description = tool.function.description, .parameters = tool.function.parameters, .strict = false }, .{}) });
    try tool_writer.writer.writeByte(']');
    const effort = reasoningEffort(cfg);
    const reasoning = if (effort) |value| try std.fmt.allocPrint(a, ",\"reasoning\":{{\"effort\":{f}}}", .{std.json.fmt(value, .{})}) else "";
    return std.fmt.allocPrint(gpa,
        \\{{"model":{f},"store":false,"stream":true,"instructions":{f},"input":{s},"include":["reasoning.encrypted_content"]{s}{s}}}
    , .{ std.json.fmt(cfg.model, .{}), std.json.fmt(instructions, .{}), input.written(), if (tools.len == 0) "" else try std.fmt.allocPrint(a, ",\"tools\":{s}", .{tool_writer.written()}), reasoning });
}

const Output = struct {
    type: []const u8,
    phase: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};
const ResponseEvent = struct {
    type: []const u8,
    delta: ?[]const u8 = null,
    output_index: usize = 0,
    item: ?std.json.Value = null,
    response: ?struct {
        status: ?[]const u8 = null,
        usage: ?struct {
            input_tokens: u64 = 0,
            output_tokens: u64 = 0,
            input_tokens_details: ?struct { cached_tokens: u64 = 0 } = null,
        } = null,
    } = null,
};

fn readStream(gpa: std.mem.Allocator, out: std.mem.Allocator, reader: *std.Io.Reader, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !p.Reply {
    var parser: sse.Parser = .{};
    defer parser.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var items: std.ArrayList(?std.json.Value) = .empty;
    defer items.deinit(gpa);
    var pending: usize = 0;
    var usage: p.Usage = .{};
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    while (true) {
        if (cancel.load(.acquire)) return error.Canceled;
        line.clearRetainingCapacity();
        _ = reader.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
            error.EndOfStream => return error.IncompleteResponse,
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        reader.toss(1);
        const data = (try parser.feed(gpa, line.written())) orelse continue;
        const ev = std.json.parseFromSliceLeaky(ResponseEvent, a, data, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
        if (std.mem.eql(u8, ev.type, "response.output_text.delta") or std.mem.eql(u8, ev.type, "response.refusal.delta")) {
            const delta = ev.delta orelse return error.InvalidResponse;
            try text.appendSlice(gpa, delta);
            try sink.onDelta(sink.ctx, .text, delta);
        } else if (std.mem.eql(u8, ev.type, "response.reasoning_summary_text.delta") or std.mem.eql(u8, ev.type, "response.reasoning_text.delta")) {
            try sink.onDelta(sink.ctx, .reasoning, ev.delta orelse return error.InvalidResponse);
        } else if (std.mem.eql(u8, ev.type, "response.output_item.added")) {
            pending += 1;
        } else if (std.mem.eql(u8, ev.type, "response.output_item.done")) {
            if (ev.output_index > 256) return error.InvalidResponse;
            while (items.items.len <= ev.output_index) try items.append(gpa, null);
            if (items.items[ev.output_index] != null) return error.InvalidResponse;
            items.items[ev.output_index] = ev.item orelse return error.InvalidResponse;
            pending -|= 1;
        } else if (std.mem.eql(u8, ev.type, "response.failed") or std.mem.eql(u8, ev.type, "error") or std.mem.eql(u8, ev.type, "response.incomplete")) {
            detail.* = try std.fmt.allocPrint(gpa, "Codex stream ended with {s}; the Step was not committed.", .{ev.type});
            return error.ProviderFailed;
        } else if (std.mem.eql(u8, ev.type, "response.completed") or std.mem.eql(u8, ev.type, "response.done")) {
            const response = ev.response orelse return error.InvalidResponse;
            if (response.status) |status| if (!std.mem.eql(u8, status, "completed")) {
                detail.* = try gpa.dupe(u8, "Codex response did not complete; the Step was not committed.");
                return error.ProviderFailed;
            };
            if (pending != 0) return error.IncompleteResponse;
            if (response.usage) |u| usage = .{ .prompt_tokens = u.input_tokens, .completion_tokens = u.output_tokens, .prompt_cache_hit_tokens = if (u.input_tokens_details) |d| d.cached_tokens else 0 };
            break;
        }
    }
    var calls: std.ArrayList(p.ToolCall) = .empty;
    defer calls.deinit(gpa);
    var reasoning: std.ArrayList(std.json.Value) = .empty;
    defer reasoning.deinit(gpa);
    var phase: ?[]const u8 = null;
    for (items.items) |maybe| {
        const item = maybe orelse return error.InvalidResponse;
        const value = try std.json.parseFromValueLeaky(Output, a, item, .{ .ignore_unknown_fields = true });
        if (std.mem.eql(u8, value.type, "message")) {
            if (value.phase) |v| phase = try out.dupe(u8, v);
        } else if (std.mem.eql(u8, value.type, "reasoning")) {
            try reasoning.append(gpa, item);
        } else if (std.mem.eql(u8, value.type, "function_call")) {
            if (calls.items.len >= 64) return error.TooManyToolCalls;
            try calls.append(gpa, .{ .id = try out.dupe(u8, value.call_id orelse return error.InvalidResponse), .function = .{ .name = try out.dupe(u8, value.name orelse return error.InvalidResponse), .arguments = try out.dupe(u8, value.arguments orelse return error.InvalidResponse) } });
        }
    }
    return .{ .text = try out.dupe(u8, text.items), .phase = phase, .reasoning = if (reasoning.items.len > 0) .{ .provider = .codex, .data = try std.json.Stringify.valueAlloc(out, reasoning.items, .{}) } else null, .tool_calls = try out.dupe(p.ToolCall, calls.items), .usage = usage };
}

test "Codex catalog context windows" {
    try std.testing.expectEqual(@as(u64, 500_000), try contextWindow("gpt-6.1-sol"));
    try std.testing.expectEqual(@as(u64, 272_000), try contextWindow("gpt-6-sol"));
    try std.testing.expectError(error.UnknownCodexModelContextWindow, contextWindow("unknown"));
}

test "Codex reasoning mapping and readable summaries" {
    const t = std.testing;
    var cfg: p.Config = .{ .provider = .codex, .model = default_model, .api_key = "", .base_url = "" };
    try t.expectEqual(@as(?[]const u8, null), reasoningEffort(cfg));
    cfg.thinking = true;
    try t.expectEqualStrings("medium", reasoningEffort(cfg).?);
    cfg.reasoning_effort = "high";
    try t.expectEqualStrings("high", reasoningEffort(cfg).?);
    cfg.thinking = false;
    try t.expectEqualStrings("low", reasoningEffort(cfg).?);
    cfg.model = "gpt-6.1-terra";
    try t.expectEqualStrings("none", reasoningEffort(cfg).?);
    try t.expect(!modelInfo("gpt-6.1-sol").?.can_disable_reasoning);
    const text = try reasoningText(t.allocator, "[{\"encrypted_content\":\"fake-ciphertext\",\"summary\":[{\"text\":\"readable\"}]}]");
    defer t.allocator.free(text);
    try t.expectEqualStrings("readable", text);
}
