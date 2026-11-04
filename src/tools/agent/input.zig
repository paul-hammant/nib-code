const std = @import("std");
const provider = @import("../../provider.zig");
const file_state = @import("../file_state.zig");

pub const Fork = struct {
    session: []const u8,
    message_count: usize,
    history: []const provider.Message,
    cache_key: []const u8,
    id: []const u8,
    provider: provider.Id,
    model: []const u8,
    thinking: ?bool = null,
    reasoning_effort: ?[]const u8 = null,
    file_versions: []const file_state.Observation = &.{},
};

pub const Input = struct {
    prompt: []const u8,
    config: provider.Config,
    fork: ?Fork = null,
};

test "agent stdin round trip preserves unset and explicit step limits" {
    const t = std.testing;
    for ([_]?usize{ null, 1, 50, 100000 }) |max_steps| {
        const input: Input = .{
            .prompt = "child prompt",
            .config = .{
                .base_url = "https://example.com",
                .api_key = "mock-key",
                .model = "mock-model",
                .limits = .{ .llm_concurrency = 8, .max_steps = max_steps },
            },
        };
        const data = try std.json.Stringify.valueAlloc(t.allocator, input, .{});
        defer t.allocator.free(data);
        const parsed = try std.json.parseFromSlice(Input, t.allocator, data, .{});
        defer parsed.deinit();
        try t.expectEqualDeep(input, parsed.value);
    }
}

test "agent stdin defaults omitted step limits to null" {
    const t = std.testing;
    for ([_][]const u8{ "", ",\"limits\":{}", ",\"limits\":{\"llm_concurrency\":8}" }) |limits| {
        const data = try std.fmt.allocPrint(t.allocator, "{{\"prompt\":\"child\",\"config\":{{\"base_url\":\"\",\"api_key\":\"\",\"model\":\"mock\"{s}}}}}", .{limits});
        defer t.allocator.free(data);
        const parsed = try std.json.parseFromSlice(Input, t.allocator, data, .{});
        defer parsed.deinit();
        try t.expectEqual(@as(?usize, null), parsed.value.config.limits.max_steps);
    }
}

test "agent stdin defaults omitted fork file versions to empty" {
    const t = std.testing;
    const data = "{\"prompt\":\"child\",\"config\":{\"base_url\":\"\",\"api_key\":\"mock\",\"model\":\"mock\"},\"fork\":{\"session\":\"parent\",\"message_count\":1,\"history\":[{\"role\":\"system\",\"content\":\"system\"}],\"cache_key\":\"parent-cache\",\"id\":\"a1\",\"provider\":\"chat_completions\",\"model\":\"mock\"}}";
    const parsed = try std.json.parseFromSlice(Input, t.allocator, data, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 0), parsed.value.fork.?.file_versions.len);
}

test "agent stdin round trip preserves fork history reasoning and file versions" {
    const t = std.testing;
    const input: Input = .{
        .prompt = "child prompt",
        .config = .{ .base_url = "", .api_key = "mock", .model = "mock", .provider = .codex },
        .fork = .{
            .session = "parent-session",
            .message_count = 2,
            .history = &.{
                .{ .role = "system", .content = "system\nbytes" },
                .{ .role = "assistant", .reasoning = .{ .provider = .codex, .data = "[{\"encrypted_content\":\"opaque\"}]" }, .tool_calls = &.{.{ .id = "run-id", .function = .{ .name = "run", .arguments = "{\"code\":\"console.log(1)\"}" } }} },
            },
            .cache_key = "root-session",
            .id = "a5",
            .provider = .codex,
            .model = "mock",
            .file_versions = &.{.{ .path = "/canonical/file", .version = .{ .inode = 9007199254740993, .size = 17, .mtime = -9007199254740993 } }},
        },
    };
    const data = try std.json.Stringify.valueAlloc(t.allocator, input, .{});
    defer t.allocator.free(data);
    const parsed = try std.json.parseFromSlice(Input, t.allocator, data, .{});
    defer parsed.deinit();
    try t.expectEqualDeep(input, parsed.value);
}
