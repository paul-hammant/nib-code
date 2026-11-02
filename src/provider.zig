const std = @import("std");
const chat = @import("provider/openai.zig");
const codex = @import("provider/codex.zig");

pub const Id = enum { chat_completions, codex };

pub const Config = struct {
    provider: Id = .chat_completions,
    codex_home: ?[]const u8 = null,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    context_window: u64 = 1_000_000,
    thinking: ?bool = null,
    reasoning_effort: ?[]const u8 = null,
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

    pub fn display(r: Reasoning, a: std.mem.Allocator) ![]const u8 {
        return switch (r.provider) {
            .chat_completions => a.dupe(u8, r.data),
            .codex => codex.reasoningText(a, r.data),
        };
    }
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning: ?Reasoning = null,
    phase: ?[]const u8 = null,
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

/// Allocated with the `out` allocator passed to `stream`.
pub const Reply = struct {
    text: []const u8,
    reasoning: ?Reasoning = null,
    phase: ?[]const u8 = null,
    tool_calls: []const ToolCall,
    usage: Usage,
};

pub const Kind = enum { text, reasoning };

pub const Sink = struct {
    ctx: *anyopaque,
    onDelta: *const fn (ctx: *anyopaque, kind: Kind, text: []const u8) anyerror!void,
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
    return switch (cfg.provider) {
        .chat_completions => chat.stream(gpa, out, client, cfg, messages, tools_json, max_tokens, sink, cancel, detail),
        .codex => codex.stream(gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, sink, cancel, detail),
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
