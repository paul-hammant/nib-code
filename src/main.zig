const std = @import("std");
const js = @import("js.zig");
const openai = @import("provider/openai.zig");
const tui = @import("tui.zig");

pub const Config = struct {
    llm: openai.Config,

    /// `DEEPSEEK_API_KEY` (or `NIB_API_KEY`), `NIB_BASE_URL`, `NIB_MODEL`.
    fn fromEnv(env: *const std.process.Environ.Map) Config {
        return .{ .llm = .{
            .api_key = env.get("NIB_API_KEY") orelse env.get("DEEPSEEK_API_KEY") orelse "",
            .base_url = env.get("NIB_BASE_URL") orelse "https://api.deepseek.com",
            .model = env.get("NIB_MODEL") orelse "deepseek-chat",
        } };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cfg: Config = .fromEnv(init.environ_map);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    const stdout = &out.interface;

    // `nib js '<code>'`: evaluate one script in the sandbox and print the result.
    if (args.len >= 3 and std.mem.eql(u8, args[1], "js")) {
        const r = try js.eval(gpa, args[2], .{});
        defer gpa.free(r.text);
        try stdout.print("{s}{s}\n", .{ if (r.ok) "" else "error: ", r.text });
        try stdout.flush();
        if (!r.ok) std.process.exit(1);
        return;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    // `nib ask '<prompt>'`: one headless streamed completion.
    if (args.len >= 3 and std.mem.eql(u8, args[1], "ask")) {
        if (cfg.llm.api_key.len == 0) fatal("set DEEPSEEK_API_KEY (or NIB_API_KEY)");
        const Print = struct {
            w: *std.Io.Writer,
            fn onDelta(ctx: *anyopaque, kind: openai.Kind, text: []const u8) !void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                if (kind == .reasoning) return; // `ask` prints the answer only
                try self.w.writeAll(text);
                try self.w.flush();
            }
        };
        var p: Print = .{ .w = stdout };
        var cancel: std.atomic.Value(bool) = .init(false);
        var detail: ?[]u8 = null;
        defer if (detail) |d| gpa.free(d);
        const msgs = [_]openai.Message{.{ .role = "user", .content = args[2] }};
        const usage = openai.stream(gpa, &client, cfg.llm, &msgs, .{ .ctx = &p, .onDelta = Print.onDelta }, &cancel, &detail) catch |err| {
            fatal(detail orelse @errorName(err));
        };
        try stdout.print("\n", .{});
        try stdout.flush();
        std.debug.print("[{s}] in={d} (cache hit {d}) out={d}\n", .{
            cfg.llm.model, usage.prompt_tokens, usage.prompt_cache_hit_tokens, usage.completion_tokens,
        });
        return;
    }

    try tui.run(init, &client, cfg.llm);
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("nib: {s}\n", .{msg});
    std.process.exit(1);
}

test {
    _ = js;
    _ = openai;
    _ = @import("sse.zig");
}
