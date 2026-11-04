const std = @import("std");
const provider = @import("../../provider.zig");

pub const Input = struct {
    prompt: []const u8,
    config: provider.Config,
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
