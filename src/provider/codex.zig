const std = @import("std");
const p = @import("../provider.zig");
const sse = @import("sse.zig");
const idle = @import("idle.zig");
const body_reader = @import("body.zig");

const Model = struct { id: []const u8, context_window: u64, can_disable_reasoning: bool = true };
pub const models = [_]Model{
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

pub fn stream(gpa: std.mem.Allocator, out: std.mem.Allocator, client: *std.http.Client, cfg: p.Config, cache_key: []const u8, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, monitor: *idle.Monitor) !p.Reply {
    const body = try requestBody(gpa, cfg, cache_key, messages, tools_json, max_tokens);
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
                .{ .name = "session-id", .value = cache_key },
                .{ .name = "x-client-request-id", .value = cache_key },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        var writer = try req.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(body);
        try writer.end();
        try req.connection.?.flush();
        monitor.attach(req.connection.?);
        defer monitor.detach(req.connection.?);
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
        var observed = try body_reader.Reader.init(gpa, reader, monitor, sink);
        defer observed.deinit(gpa);
        return readStream(gpa, out, &observed.reader, sink, cancel, detail);
    }
    unreachable;
}

fn requestBody(gpa: std.mem.Allocator, cfg: p.Config, cache_key: []const u8, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32) ![]u8 {
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
    const reasoning = if (effort) |value| try std.fmt.allocPrint(a, ",\"reasoning\":{{\"effort\":{f},\"summary\":\"auto\"}}", .{std.json.fmt(value, .{})}) else "";
    const format = if (cfg.output_schema) |schema|
        try std.fmt.allocPrint(a, ",\"text\":{f}", .{std.json.fmt(.{ .format = .{ .type = "json_schema", .name = "result", .strict = true, .schema = schema } }, .{})})
    else
        "";
    return std.fmt.allocPrint(gpa,
        \\{{"model":{f},"prompt_cache_key":{f},"store":false,"stream":true,"instructions":{f},"input":{s},"include":["reasoning.encrypted_content"]{s}{s}{s}}}
    , .{ std.json.fmt(cfg.model, .{}), std.json.fmt(cache_key, .{}), std.json.fmt(instructions, .{}), input.written(), if (tools.len == 0) "" else try std.fmt.allocPrint(a, ",\"tools\":{s}", .{tool_writer.written()}), reasoning, format });
}

const Output = struct {
    type: []const u8,
    phase: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};
const StreamError = struct {
    code: ?std.json.Value = null,
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
    status: ?u16 = null,
    status_code: ?u16 = null,
};
const ResponseEvent = struct {
    type: []const u8,
    code: ?std.json.Value = null,
    message: ?[]const u8 = null,
    status: ?u16 = null,
    status_code: ?u16 = null,
    delta: ?[]const u8 = null,
    output_index: usize = 0,
    item: ?std.json.Value = null,
    response: ?struct {
        status: ?[]const u8 = null,
        @"error": ?StreamError = null,
        incomplete_details: ?struct { reason: ?[]const u8 = null } = null,
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
            error.EndOfStream => return incompleteResponse(gpa, detail),
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        reader.toss(1);
        const data = (try parser.feed(gpa, line.written())) orelse continue;
        const ev = std.json.parseFromSliceLeaky(ResponseEvent, a, data, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
        if (sink.timing) |timing| observeTiming(timing, ev);
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
            return streamFailure(gpa, ev, detail);
        } else if (std.mem.eql(u8, ev.type, "response.completed") or std.mem.eql(u8, ev.type, "response.done")) {
            const response = ev.response orelse return error.InvalidResponse;
            if (response.status) |status| if (!std.mem.eql(u8, status, "completed")) {
                return streamFailure(gpa, ev, detail);
            };
            if (pending != 0) return incompleteResponse(gpa, detail);
            if (response.usage) |u| usage = .{ .prompt_tokens = u.input_tokens, .completion_tokens = u.output_tokens, .prompt_cache_hit_tokens = if (u.input_tokens_details) |d| d.cached_tokens else 0 };
            break;
        }
    }
    var calls: std.ArrayList(p.ToolCall) = .empty;
    defer calls.deinit(gpa);
    var reasoning: std.ArrayList(std.json.Value) = .empty;
    defer reasoning.deinit(gpa);
    var phase: ?[]const u8 = null;
    for (items.items, 0..) |maybe, index| {
        const item = maybe orelse return error.InvalidResponse;
        const value = try std.json.parseFromValueLeaky(Output, a, item, .{ .ignore_unknown_fields = true });
        if (std.mem.eql(u8, value.type, "message")) {
            if (value.phase) |v| phase = try out.dupe(u8, v);
        } else if (std.mem.eql(u8, value.type, "reasoning")) {
            try reasoning.append(gpa, item);
        } else if (std.mem.eql(u8, value.type, "function_call")) {
            if (calls.items.len >= 64) return error.TooManyToolCalls;
            if (sink.timing) |timing| timing.bind(index, calls.items.len);
            try calls.append(gpa, .{ .id = try out.dupe(u8, value.call_id orelse return error.InvalidResponse), .function = .{ .name = try out.dupe(u8, value.name orelse return error.InvalidResponse), .arguments = try out.dupe(u8, value.arguments orelse return error.InvalidResponse) } });
        }
    }
    return .{ .text = try out.dupe(u8, text.items), .phase = phase, .reasoning = if (reasoning.items.len > 0) .{ .provider = .codex, .data = try std.json.Stringify.valueAlloc(out, reasoning.items, .{}) } else null, .tool_calls = try out.dupe(p.ToolCall, calls.items), .usage = usage };
}

fn observeTiming(timing: *p.ModelTiming, ev: ResponseEvent) void {
    if (std.mem.eql(u8, ev.type, "response.function_call_arguments.delta")) {
        if (ev.delta) |delta| timing.arguments(ev.output_index, delta.len);
    } else if (std.mem.eql(u8, ev.type, "response.output_item.added") or std.mem.eql(u8, ev.type, "response.output_item.done")) {
        const item = ev.item orelse return;
        if (item != .object) return;
        const kind = item.object.get("type") orelse return;
        if (kind != .string or !std.mem.eql(u8, kind.string, "function_call")) return;
        const args = item.object.get("arguments") orelse return;
        if (args != .string) return;
        if (std.mem.eql(u8, ev.type, "response.output_item.added")) {
            timing.arguments(ev.output_index, args.string.len);
        } else {
            timing.finalArguments(ev.output_index, args.string.len);
        }
    }
}

fn incompleteResponse(gpa: std.mem.Allocator, detail: *?[]u8) anyerror {
    detail.* = std.fmt.allocPrint(gpa, "Codex stream failed: IncompleteResponse: the stream ended before a complete response; the Step was not committed.", .{}) catch return error.OutOfMemory;
    return error.IncompleteResponse;
}

fn streamFailure(gpa: std.mem.Allocator, ev: ResponseEvent, detail: *?[]u8) anyerror {
    var failure: StreamError = .{ .code = ev.code, .message = ev.message, .status = ev.status, .status_code = ev.status_code };
    var reason: ?[]const u8 = null;
    if (ev.response) |response| {
        if (response.@"error") |err| failure = err;
        if (response.incomplete_details) |incomplete| reason = incomplete.reason;
    }
    var number: [32]u8 = undefined;
    const code = if (reason) |r| r else if (failure.code) |value| switch (value) {
        .string => value.string,
        .integer => std.fmt.bufPrint(&number, "{d}", .{value.integer}) catch "unknown",
        else => failure.type orelse "unknown",
    } else failure.type orelse "unknown";
    const message = failure.message orelse reason orelse "No error message was provided";
    const status = failure.status_code orelse failure.status orelse statusFromCode(code);
    const fatal = fatalStreamCode(code) or (status >= 400 and status < 500 and status != 429);
    const limited = !fatal and (std.mem.eql(u8, code, "rate_limit_exceeded") or status == 429);
    var hint: ?[]u8 = null;
    defer if (hint) |s| gpa.free(s);
    var shown = clipMessage(message, 300);
    if (limited and shown.len < message.len and retryDelayMs(shown) == null) {
        if (retryDelayMs(message)) |ms| {
            hint = std.fmt.allocPrint(gpa, "{s}… try again in {d}ms", .{ clipMessage(message, 260), ms }) catch return error.OutOfMemory;
            shown = hint.?;
        }
    }
    detail.* = std.fmt.allocPrint(gpa, "Codex stream failed: {s}: {s}; the Step was not committed.", .{ code, shown }) catch return error.OutOfMemory;
    return if (fatal) error.ProviderFailed else if (limited) error.RateLimited else error.ProviderTransient;
}

fn clipMessage(message: []const u8, limit: usize) []const u8 {
    var end = @min(message.len, limit);
    while (end > 0 and end < message.len and (message[end] & 0xc0) == 0x80) end -= 1;
    return message[0..end];
}

fn statusFromCode(code: []const u8) u16 {
    const digits = if (std.mem.startsWith(u8, code, "http_") or std.mem.startsWith(u8, code, "HTTP ")) code[5..] else code;
    if (digits.len != 3) return 0;
    return std.fmt.parseInt(u16, digits, 10) catch 0;
}

fn fatalStreamCode(code: []const u8) bool {
    for ([_][]const u8{
        "context_length_exceeded", "insufficient_quota", "usage_not_included", "invalid_prompt",
        "invalid_request_error",   "invalid_request",    "bad_request",        "unauthorized",
        "authentication_error",    "invalid_api_key",    "permission_denied",  "forbidden",
        "not_found",               "method_not_allowed", "request_too_large",  "unsupported_media_type",
        "unprocessable_entity",
    }) |known| if (std.mem.eql(u8, code, known)) return true;
    return false;
}

pub fn retryDelayMs(message: []const u8) ?u64 {
    const needle = "try again in ";
    if (message.len < needle.len) return null;
    for (0..message.len - needle.len + 1) |start| {
        if (!std.ascii.eqlIgnoreCase(message[start..][0..needle.len], needle)) continue;
        const rest = std.mem.trimStart(u8, message[start + needle.len ..], " \t");
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.')) end += 1;
        if (end == 0) continue;
        const duration = std.fmt.parseFloat(f64, rest[0..end]) catch continue;
        const unit = std.mem.trimStart(u8, rest[end..], " \t");
        const ms = duration * @as(f64, if (std.mem.startsWith(u8, unit, "ms")) 1 else if (std.mem.startsWith(u8, unit, "s")) 1000 else continue);
        if (!std.math.isFinite(ms) or ms < 0 or ms >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) continue;
        return @intFromFloat(@ceil(ms));
    }
    return null;
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
}

test "Codex request body requests summaries exactly when reasoning is sent" {
    const t = std.testing;
    const cases = [_]struct {
        model: []const u8 = default_model,
        thinking: ?bool = null,
        effort: ?[]const u8 = null,
        expected_effort: ?[]const u8 = null,
    }{
        .{},
        .{ .thinking = true, .expected_effort = "medium" },
        .{ .effort = "high", .expected_effort = "high" },
        .{ .thinking = false, .expected_effort = "low" },
        .{ .model = "gpt-6.1-terra", .thinking = false, .expected_effort = "none" },
        .{ .effort = "none", .expected_effort = "none" },
    };
    for (cases) |case| {
        const cfg: p.Config = .{
            .provider = .codex,
            .model = case.model,
            .api_key = "",
            .base_url = "",
            .thinking = case.thinking,
            .reasoning_effort = case.effort,
        };
        const body = try requestBody(t.allocator, cfg, "cache-key", &.{}, "[]", null);
        defer t.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try t.expect(!root.contains("summary"));
        if (case.expected_effort) |effort| {
            const reasoning = root.get("reasoning").?.object;
            try t.expectEqual(@as(usize, 2), reasoning.count());
            try t.expectEqualStrings(effort, reasoning.get("effort").?.string);
            try t.expectEqualStrings("auto", reasoning.get("summary").?.string);
        } else {
            try t.expect(!root.contains("reasoning"));
        }
    }
}

test "Codex request body carries the session cache key" {
    const t = std.testing;
    const cfg: p.Config = .{ .provider = .codex, .model = default_model, .api_key = "", .base_url = "" };
    const cache_key = "0123456789abcdef0123456789abcdef";
    const body = try requestBody(t.allocator, cfg, cache_key, &.{.{ .role = "user", .content = "hello" }}, "[]", null);
    defer t.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
    defer parsed.deinit();
    try t.expectEqualStrings(cache_key, parsed.value.object.get("prompt_cache_key").?.string);
}

fn expectStreamFailure(json: []const u8, expected: anyerror, code: []const u8, message: []const u8) !void {
    const t = std.testing;
    const Sink = struct {
        fn delta(_: *anyopaque, _: p.Kind, _: []const u8) !void {}
    };
    const bytes = try std.fmt.allocPrint(t.allocator, "data: {s}\n\n", .{json});
    defer t.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var cancel: std.atomic.Value(bool) = .init(false);
    var detail: ?[]u8 = null;
    defer if (detail) |text| t.allocator.free(text);
    try t.expectError(expected, readStream(t.allocator, t.allocator, &reader, .{ .ctx = &cancel, .onDelta = Sink.delta }, &cancel, &detail));
    try t.expect(std.mem.indexOf(u8, detail.?, code) != null);
    try t.expect(std.mem.indexOf(u8, detail.?, message) != null);
    try t.expect(std.mem.endsWith(u8, detail.?, "; the Step was not committed."));
}

test "Codex stream errors preserve reasons and distinguish retryable failures" {
    try expectStreamFailure("{\"type\":\"error\",\"code\":\"server_error\",\"message\":\"service broke\"}", error.ProviderTransient, "server_error", "service broke");
    try expectStreamFailure("{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too much context\"}}}", error.ProviderFailed, "context_length_exceeded", "too much context");
    try expectStreamFailure("{\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"usage_not_included\"}}}", error.ProviderFailed, "usage_not_included", "usage_not_included");
    try expectStreamFailure("{\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}", error.ProviderTransient, "max_output_tokens", "max_output_tokens");
    try expectStreamFailure("{\"type\":\"error\",\"code\":\"rate_limit_exceeded\",\"message\":\"try again in 30ms\"}", error.RateLimited, "rate_limit_exceeded", "try again in 30ms");
    try expectStreamFailure("{\"type\":\"response.completed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"invalid_prompt\",\"message\":\"bad prompt\"}}}", error.ProviderFailed, "invalid_prompt", "bad prompt");
    try expectStreamFailure("{\"type\":\"error\",\"code\":400,\"message\":\"bad request\"}", error.ProviderFailed, "400", "bad request");
    try expectStreamFailure("{\"type\":\"error\",\"status_code\":403,\"message\":\"denied\"}", error.ProviderFailed, "unknown", "denied");
    try expectStreamFailure("{\"type\":\"error\",\"code\":\"new_server_code\",\"message\":\"unknown issue\"}", error.ProviderTransient, "new_server_code", "unknown issue");
    try expectStreamFailure("{\"type\":\"response.created\"}", error.IncompleteResponse, "IncompleteResponse", "stream ended");
    const t = std.testing;
    for ([_][]const u8{ "context_length_exceeded", "insufficient_quota", "usage_not_included", "invalid_prompt", "invalid_request_error" }) |code| try t.expect(fatalStreamCode(code));
    for ([_][]const u8{ "server_error", "overloaded", "service_unavailable", "unknown" }) |code| try t.expect(!fatalStreamCode(code));
}

test "Codex errors bound UTF-8 messages and retain rate-limit hints beyond the cutoff" {
    const t = std.testing;
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(t.allocator);
    for (0..150) |_| try message.appendSlice(t.allocator, "中");
    var detail: ?[]u8 = null;
    defer if (detail) |d| t.allocator.free(d);
    try t.expectEqual(error.ProviderTransient, streamFailure(t.allocator, .{ .type = "error", .code = .{ .string = "server_error" }, .message = message.items }, &detail));
    try t.expect(std.unicode.utf8ValidateSlice(detail.?));
    try t.expect(detail.?.len < 400);
    t.allocator.free(detail.?);
    detail = null;
    try message.appendSlice(t.allocator, " try again in 0.25s");
    try t.expectEqual(error.RateLimited, streamFailure(t.allocator, .{ .type = "error", .code = .{ .string = "rate_limit_exceeded" }, .message = message.items }, &detail));
    try t.expectEqual(@as(?u64, 250), retryDelayMs(detail.?));
    try t.expect(detail.?.len < 420);
}

test "Codex retry hints accept seconds and milliseconds without overflow" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, 1200), retryDelayMs("Please try again in 1.2s."));
    try t.expectEqual(@as(?u64, 25), retryDelayMs("Try again in 25ms"));
    try t.expectEqual(@as(?u64, 1), retryDelayMs("try again in 0.1ms"));
    try t.expectEqual(@as(?u64, 0), retryDelayMs("try again in 0s"));
    for ([_][]const u8{ "try again later", "try again in -1s", "try again in 1minute", "try again in 1.2.3s", "try again in 999999999999999999999999999999s" }) |message| try t.expectEqual(@as(?u64, null), retryDelayMs(message));
}

test "Codex stream activity covers non-text events and SSE heartbeats" {
    const t = std.testing;
    const State = struct {
        received: usize = 0,
        fn data(ctx: *anyopaque) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.received += 1;
        }
        fn delta(_: *anyopaque, _: p.Kind, _: []const u8) !void {}
    };
    const prefixes = [_][]const u8{
        ": ping\n\n",
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"text\"}\n\n",
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"reasoning\"}\n\n",
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"args\"}\n\n",
        "data: {\"type\":\"response.output_item.added\"}\n\ndata: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"content\":[]}}\n\n",
    };
    for (prefixes) |prefix| {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const input = try std.fmt.allocPrint(arena.allocator(), "{s}data: {{\"type\":\"response.completed\",\"response\":{{\"status\":\"completed\"}}}}\n\n", .{prefix});
        var reader: std.Io.Reader = .fixed(input);
        var state: State = .{};
        var cancel: std.atomic.Value(bool) = .init(false);
        var detail: ?[]u8 = null;
        defer if (detail) |d| t.allocator.free(d);
        const sink: p.Sink = .{ .ctx = &state, .onDelta = State.delta, .onData = State.data };
        var monitor: idle.Monitor = .init(t.io, 1, null);
        var observed = try body_reader.Reader.init(t.allocator, &reader, &monitor, sink);
        defer observed.deinit(t.allocator);
        _ = try readStream(t.allocator, arena.allocator(), &observed.reader, sink, &cancel, &detail);
        try t.expectEqual(@as(usize, 1), state.received);
    }
}

test "Codex parser times argument deltas and final-only calls at sparse output indices" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const out = arena.allocator();
    var bytes: std.Io.Writer.Allocating = .init(t.allocator);
    defer bytes.deinit();
    for (0..70) |index| {
        try bytes.writer.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{{\"type\":\"reasoning\"}}}}\n\n", .{index});
    }
    try bytes.writer.writeAll(
        "data: {\"type\":\"response.output_item.added\",\"output_index\":70,\"item\":{\"type\":\"function_call\",\"call_id\":\"streamed\",\"name\":\"run\",\"arguments\":\"\"}}\n\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":70,\"delta\":\"{\"}\n\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":70,\"delta\":\"}\"}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":70,\"item\":{\"type\":\"function_call\",\"call_id\":\"streamed\",\"name\":\"run\",\"arguments\":\"{}\"}}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":71,\"item\":{\"type\":\"function_call\",\"call_id\":\"final\",\"name\":\"run\",\"arguments\":\"{ }\"}}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":72,\"item\":{\"type\":\"function_call\",\"call_id\":\"other\",\"name\":\"search\",\"arguments\":\"{}\"}}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
    );
    const Counter = struct {
        fn delta(ctx: *anyopaque, _: p.Kind, _: []const u8) !void {
            const count: *usize = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    };
    var count: usize = 0;
    var cancel: std.atomic.Value(bool) = .init(false);
    var detail: ?[]u8 = null;
    defer if (detail) |text| t.allocator.free(text);
    var timing: p.ModelTiming = .init(t.io, .now(t.io, .awake));
    var reader: std.Io.Reader = .fixed(bytes.written());
    const reply = try readStream(t.allocator, out, &reader, .{ .ctx = &count, .onDelta = Counter.delta, .timing = &timing }, &cancel, &detail);
    try t.expectEqual(@as(usize, 0), count);
    try t.expectEqual(@as(usize, 3), reply.tool_calls.len);
    const codes = try timing.finish(out, reply.tool_calls);
    try t.expectEqual(@as(usize, 2), codes.len);
    try t.expectEqualStrings("streamed", codes[0].tool_call_id);
    try t.expectEqual(@as(usize, 2), codes[0].progress.len);
    try t.expectEqual(@as(u64, 1), codes[0].progress[0][1]);
    try t.expectEqual(@as(u64, 2), codes[0].progress[1][1]);
    try t.expectEqualStrings("final", codes[1].tool_call_id);
    try t.expectEqual(@as(usize, 1), codes[1].progress.len);
    try t.expectEqual(codes[1].first_ms, codes[1].last_ms);
    try t.expectEqual(@as(u64, 3), codes[1].progress[0][1]);
    reader = .fixed(bytes.written());
    const untimed = try readStream(t.allocator, out, &reader, .{ .ctx = &count, .onDelta = Counter.delta }, &cancel, &detail);
    try t.expectEqualStrings(try std.json.Stringify.valueAlloc(out, untimed, .{}), try std.json.Stringify.valueAlloc(out, reply, .{}));
}

test "tool-free JSON requests move system to instructions and use strict named schema" {
    const t = std.testing;
    const schema = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}", .{});
    defer schema.deinit();
    const system = "Return JSON.\nUse the \"answer\" field.";
    const messages = [_]p.Message{
        .{ .role = "system", .content = system },
        .{ .role = "user", .content = "question" },
    };
    for ([_]?std.json.Value{ null, schema.value }) |output_schema| {
        const body = try requestBody(t.allocator, .{ .base_url = "", .api_key = "", .model = "m", .output_schema = output_schema }, "cache", &messages, "[]", null);
        defer t.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try t.expect(!object.contains("tools"));
        try t.expect(!object.contains("response_format"));
        try t.expectEqualStrings(system, object.get("instructions").?.string);
        const input = object.get("input").?.array.items;
        try t.expectEqual(@as(usize, 1), input.len);
        try t.expectEqualStrings("user", input[0].object.get("role").?.string);
        try t.expectEqualStrings("question", input[0].object.get("content").?.string);
        if (output_schema != null) {
            const text = object.get("text").?.object;
            try t.expectEqual(@as(usize, 1), text.count());
            const format = text.get("format").?.object;
            try t.expectEqual(@as(usize, 4), format.count());
            try t.expectEqualStrings("json_schema", format.get("type").?.string);
            try t.expectEqualStrings("result", format.get("name").?.string);
            try t.expect(format.get("strict").?.bool);
            const actual = try std.json.Stringify.valueAlloc(t.allocator, format.get("schema").?, .{});
            defer t.allocator.free(actual);
            try t.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}", actual);
        } else {
            try t.expect(!object.contains("text"));
        }
    }
}
