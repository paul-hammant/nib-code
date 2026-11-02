const std = @import("std");
const js = @import("js.zig");
const openai = @import("provider/openai.zig");
const tui = @import("tui.zig");
const agent = @import("agent.zig");

pub const Config = struct {
    llm: openai.Config,

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

    if (args.len >= 3 and std.mem.eql(u8, args[1], "js")) {
        const r = try js.eval(gpa, init.io, args[2], .{}, null, null);
        defer r.deinit(gpa);
        try stdout.print("{s}{s}{s}\n", .{ r.logs, if (r.ok) "" else "error: ", r.text });
        try stdout.flush();
        if (!r.ok) std.process.exit(1);
        return;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    if (args.len >= 3 and std.mem.eql(u8, args[1], "ask")) {
        if (cfg.llm.api_key.len == 0) fatal("set DEEPSEEK_API_KEY (or NIB_API_KEY)");
        var session = try agent.Session.init(gpa, init.io, &client, cfg.llm, init.environ_map.get("HOME") orelse "");
        defer session.deinit();

        const Print = struct {
            w: *std.Io.Writer,
            fn emit(ctx: *anyopaque, ev: agent.Event) !void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                switch (ev) {
                    .delta => |d| if (d.kind == .text) {
                        try self.w.writeAll(d.text);
                        try self.w.flush();
                    },
                    .run_start => |code| std.debug.print("\n\x1b[33mrun ▸\x1b[0m {s}\n", .{code}),
                    .run_end => |r| std.debug.print("\x1b[2m{s}\x1b[0m\n", .{r.output}),
                    .retry => |r| std.debug.print("\x1b[2mretry {d} in {d}s: {s}\x1b[0m\n", .{ r.attempt, r.delay_ms / 1000, r.reason }),
                }
            }
        };
        var p: Print = .{ .w = stdout };
        var cancel: std.atomic.Value(bool) = .init(false);
        var detail: ?[]u8 = null;
        defer if (detail) |d| gpa.free(d);
        session.turn(args[2], .{ .ctx = &p, .emit = Print.emit }, &cancel, &detail) catch |err| {
            fatal(detail orelse @errorName(err));
        };
        try stdout.print("\n", .{});
        try stdout.flush();
        const u = session.usage;
        std.debug.print("[{s}] turn: {d} steps, in={d} (cache hit {d}) out={d}\n", .{
            cfg.llm.model, session.steps, u.prompt_tokens, u.prompt_cache_hit_tokens, u.completion_tokens,
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
    _ = @import("tools.zig");
    _ = @import("policy.zig");
    _ = @import("editor.zig");
    _ = agent;
}
