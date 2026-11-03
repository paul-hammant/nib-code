const std = @import("std");
const provider = @import("../provider.zig");
const tools = @import("../tools.zig");
const llm = @import("llm.zig");
const t = std.testing;

pub const Mock = struct {
    pub var calls: usize = 0;
    pub var invalid: usize = 0;
    pub var expected_input: ?[]const u8 = null;

    pub fn complete(_: std.mem.Allocator, out: std.mem.Allocator, _: *std.http.Client, cfg: provider.Config, key: []const u8, messages: []const provider.Message, tool_json: []const u8, _: ?u32, _: provider.Sink, _: *const std.atomic.Value(bool), _: *?[]u8, _: *u32, retry_sink: ?provider.RetrySink) !provider.Reply {
        calls += 1;
        try t.expectEqualStrings("[]", tool_json);
        try t.expectEqualStrings("session:llm", key);
        try t.expectEqualStrings(llm.system, messages[0].content.?);
        try t.expect(retry_sink == null);
        if (expected_input) |input| try t.expectEqualStrings(input, messages[messages.len - 1].content.?);
        if (calls > 1) {
            try t.expect(std.mem.indexOf(u8, messages[messages.len - 2].content.?, "SyntaxError") != null);
        }
        const text = if (calls <= invalid) "bad raw output {broken" else if (cfg.output_schema != null) "[1,true,null]" else "plain";
        return .{ .text = try out.dupe(u8, text), .tool_calls = &.{}, .usage = .{ .prompt_tokens = 11, .completion_tokens = 7, .prompt_cache_hit_tokens = 3 } };
    }

    pub fn reset() void {
        calls = 0;
        invalid = 0;
        expected_input = null;
    }
};

pub fn state() tools.Tools {
    return .{ .io = t.io, .home = "/unused", .session_id = "session", .cfg = .{ .base_url = "", .api_key = "", .model = "mock" } };
}
