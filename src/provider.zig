const std = @import("std");
const chat = @import("provider/openai.zig");
const codex = @import("provider/codex.zig");
const cancelable = @import("provider/cancel.zig");
const model_timing = @import("provider/timing.zig");
const retry = @import("provider/retry.zig");
const idle = @import("provider/idle.zig");
pub const complete = retry.complete;
pub const RetryEvent = retry.Event;
pub const RetrySink = retry.Sink;
pub const max_attempts = retry.max_attempts;
pub const ModelTiming = model_timing.Model;

pub const CodexState = @import("provider/codex_ws.zig").State;
pub const Transport = enum { sse, websocket };

pub const Protocol = enum { responses, chat_completions, anthropic_messages };
pub const Id = enum { chat_completions, codex };

pub const Definition = struct {
    id: Id,
    name: []const u8,
    protocol: Protocol,
    base_url: []const u8,
    api_key_env: []const []const u8,
    default_model: []const u8,
};

pub const definitions = [_]Definition{
    .{ .id = .codex, .name = "Codex", .protocol = .responses, .base_url = "https://chatgpt.com/backend-api", .api_key_env = &.{}, .default_model = codex.default_model },
    .{ .id = .chat_completions, .name = "Chat Completions", .protocol = .chat_completions, .base_url = "https://api.deepseek.com", .api_key_env = &.{ "NIB_API_KEY", "DEEPSEEK_API_KEY" }, .default_model = chat.default_model },
};

pub fn definition(id: Id) Definition {
    for (definitions) |entry| if (entry.id == id) return entry;
    unreachable;
}

pub const Limits = struct {
    llm_concurrency: usize = 4,
    llm_calls_per_run: usize = 100,
    llm_input_kib: usize = 256,
    agent_concurrency: usize = 4,
    max_steps: ?usize = null,
    stream_idle_timeout_s: usize = 300,
    stream_content_timeout_s: usize = 120,
    request_timeout_s: usize = 300,
    run_background_after_ms: usize = 10000,
    run_output_bytes: usize = 16 * 1024,
};

pub const Config = struct {
    enabled_skills: []const []const u8 = &.{},
    limits: Limits = .{},
    provider: Id = .chat_completions,
    codex_transport: Transport = .websocket,
    codex_run_tool: enum { custom, function } = .custom,
    reasoning_summary: enum { off, auto } = .off,
    codex_home: ?[]const u8 = null,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    context_window: u64 = 1_000_000,
    thinking: ?bool = null,
    reasoning_effort: ?[]const u8 = null,
    /// Borrowed for the duration of the request.
    output_schema: ?std.json.Value = null,
    prompt_cache_key: ?[]const u8 = null,
    /// Values `setEffort` accepts; `default` and `off` first, then levels.
    pub const effort_values = [_][]const u8{ "default", "off", "none", "minimal", "low", "medium", "high", "xhigh", "max" };

    pub fn setEffort(cfg: *Config, value: []const u8) !void {
        const known = for (effort_values) |v| {
            if (std.mem.eql(u8, v, value)) break v;
        } else return error.InvalidReasoningEffort;
        if (std.mem.eql(u8, known, "default")) {
            cfg.thinking = null;
            cfg.reasoning_effort = null;
        } else if (std.mem.eql(u8, known, "off")) {
            cfg.thinking = false;
            cfg.reasoning_effort = null;
        } else {
            cfg.thinking = true;
            cfg.reasoning_effort = known;
        }
    }

    pub fn effectiveEffort(cfg: Config) []const u8 {
        if (cfg.provider == .codex) return codex.reasoningEffort(cfg) orelse "server default";
        if (cfg.thinking == false) return "off";
        return cfg.reasoning_effort orelse if (cfg.thinking == true) "on (server default effort)" else "server default";
    }

    pub fn missingKey(cfg: Config) bool {
        return cfg.provider == .chat_completions and cfg.api_key.len == 0;
    }

    pub fn checkSession(cfg: Config, id: Id, model: ?[]const u8) !void {
        if (cfg.provider != id) return error.SessionProviderMismatch;
        if (cfg.provider == .codex) if (model) |original| {
            if (!std.mem.eql(u8, original, cfg.model)) return error.SessionModelMismatch;
        };
    }
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

pub const Reasoning = struct {
    provider: Id,
    data: []const u8,
    includes_output: bool = false,
};

pub const EffortSource = enum { model, default, guard };

pub const StepEffort = struct {
    effort: []const u8,
    source: EffortSource,
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning: ?Reasoning = null,
    phase: ?[]const u8 = null,
    waiting: ?bool = null,
    step_effort: ?StepEffort = null,
    bash_replacements: ?[]const @import("tools/bash/registry.zig").Event = null,
    run_ok: ?bool = null,
    tool_summary: ?@import("session/tool_summary.zig").Summary = null,
    step_calls_omitted: ?u64 = null,
    source: ?enum { background, undo } = null,
    background_id: ?[]const u8 = null,
    background_ok: ?bool = null,
    background_run: ?@import("session/events.zig").RunCompletion = null,
    background_kind: ?@import("session/events.zig").Background.Kind = null,
};

pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    prompt_cache_hit_tokens: u64 = 0,

    pub fn add(u: *Usage, other: Usage) void {
        u.prompt_tokens += other.prompt_tokens;
        u.completion_tokens += other.completion_tokens;
        u.prompt_cache_hit_tokens += other.prompt_cache_hit_tokens;
    }
};

/// Allocated with the `out` allocator passed to `stream` or `complete`.
pub const Reply = struct {
    text: []const u8,
    reasoning: ?Reasoning = null,
    phase: ?[]const u8 = null,
    tool_calls: []const ToolCall,
    usage: Usage,
};

pub const Kind = enum { text, reasoning };

pub const Sink = struct {
    /// Only buffered callers may replay Chat deltas after a transient failure.
    replay_safe: bool = false,
    timing: ?*model_timing.Model = null,
    codex_state: ?*CodexState = null,
    ctx: *anyopaque,
    onDelta: *const fn (ctx: *anyopaque, kind: Kind, text: []const u8) anyerror!void,
    monitor: ?*idle.Monitor = null,
    onFallback: ?*const fn (ctx: *anyopaque, info: @import("provider/codex_ws.zig").Info) anyerror!void = null,
    onToolArguments: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    onData: ?*const fn (ctx: *anyopaque) anyerror!void = null,

    pub fn toolArguments(s: Sink) !void {
        if (s.onToolArguments) |notify| try notify(s.ctx);
    }

    pub fn fallback(s: Sink, info: @import("provider/codex_ws.zig").Info) !void {
        if (s.onFallback) |notify| try notify(s.ctx, info);
    }

    pub fn received(s: Sink) !void {
        if (s.onData) |notify| try notify(s.ctx);
    }
};

pub fn stream(
    gpa: std.mem.Allocator,
    out: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    cache_key: []const u8,
    messages: []const Message,
    tools_json: []const u8,
    max_tokens: ?u32,
    sink: Sink,
    cancel: *const std.atomic.Value(bool),
    detail: *?[]u8,
) !Reply {
    if (sink.timing) |timing| timing.resetAttempt();
    var monitor: idle.Monitor = .init(client.io, cfg.limits.stream_idle_timeout_s, sink.timing);
    monitor.content_duration.raw = .fromSeconds(@intCast(cfg.limits.stream_content_timeout_s));
    monitor.request_duration.raw = .fromSeconds(@intCast(cfg.limits.request_timeout_s));
    var observed_sink = sink;
    observed_sink.monitor = &monitor;
    return switch (cfg.provider) {
        .chat_completions => cancelable.run(client.io, cancel, monitor.started.addDuration(monitor.request_duration), chat.stream, .{ gpa, out, client, cfg, messages, tools_json, max_tokens, observed_sink, cancel, detail, &monitor }),
        .codex => cancelable.run(client.io, cancel, monitor.started.addDuration(monitor.request_duration), codex.stream, .{ gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, observed_sink, cancel, detail, &monitor }),
    } catch |err| {
        if (cfg.provider == .codex) if (sink.codex_state) |state| {
            state.reset(gpa);
            state.reset_reason = "reconnect";
        };
        if (cancel.load(.acquire)) return error.Canceled;
        if (err == error.ModelRequestTimeout) {
            monitor.read_failure = error.Timeout;
            monitor.timeout_kind = .request;
        }
        return monitor.failure(gpa, detail, err);
    };
}

test "explicit effort overrides thinking and stores stable names" {
    const t = std.testing;
    var cfg: Config = .{ .base_url = "", .api_key = "", .model = "gpt-6.1-sol", .provider = .codex, .thinking = false };
    var value = [_]u8{ 'h', 'i', 'g', 'h' };
    try cfg.setEffort(&value);
    value[0] = 'x';
    try t.expectEqualStrings("high", cfg.effectiveEffort());
    try t.expectEqual(@as(?bool, true), cfg.thinking);
    try cfg.setEffort("off");
    try t.expectEqualStrings("low", cfg.effectiveEffort());
    try cfg.setEffort("default");
    try t.expectEqualStrings("server default", cfg.effectiveEffort());
    try t.expectEqual(@as(?bool, null), cfg.thinking);
    try t.expectError(error.InvalidReasoningEffort, cfg.setEffort("hgh"));
    try t.expectEqualStrings("server default", cfg.effectiveEffort());
    cfg.provider = .chat_completions;
    try cfg.setEffort("max");
    try t.expectEqualStrings("max", cfg.effectiveEffort());
    try cfg.setEffort("off");
    try t.expectEqualStrings("off", cfg.effectiveEffort());
}

test "provider definitions cover every identity exactly once" {
    inline for (std.meta.tags(Id)) |id| {
        var count: usize = 0;
        for (definitions) |entry| {
            if (entry.id == id) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expect(definition(id).base_url.len > 0);
        try std.testing.expect(definition(id).default_model.len > 0);
    }
}
