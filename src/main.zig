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
            .context_window = if (env.get("NIB_CONTEXT_WINDOW")) |v| std.fmt.parseInt(u64, v, 10) catch fatal("NIB_CONTEXT_WINDOW must be an integer") else 128_000,
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

    var options: agent.Session.Options = .{
        .home = init.environ_map.get("HOME") orelse "",
        .data_home = init.environ_map.get("XDG_DATA_HOME") orelse try std.fs.path.join(init.arena.allocator(), &.{ init.environ_map.get("HOME") orelse "", ".local/share" }),
        .config_home = init.environ_map.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(init.arena.allocator(), &.{ init.environ_map.get("HOME") orelse "", ".config" }),
    };
    var ask = false;
    var prompt: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!ask and std.mem.eql(u8, arg, "ask")) {
            ask = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue")) {
            options.continue_latest = true;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            i += 1;
            if (i == args.len) fatal("--resume requires a session id");
            options.resume_id = args[i];
        } else if (ask and prompt == null) {
            prompt = arg;
        } else fatal("usage: nib [ask '<prompt>'] [-c | --continue | --resume <id>]");
    }
    if (options.continue_latest and options.resume_id != null) fatal("choose --continue or --resume");
    if (ask and prompt == null) fatal("ask requires a prompt");

    var client: std.http.Client = .{ .allocator = gpa, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    if (ask and cfg.llm.api_key.len == 0) fatal("set DEEPSEEK_API_KEY (or NIB_API_KEY)");
    var session = agent.Session.init(gpa, init.io, &client, cfg.llm, options) catch |err| fatal(@errorName(err));
    defer session.deinit();

    if (ask) {
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
                    .notice => |m| std.debug.print("\x1b[2m{s}\x1b[0m\n", .{m}),
                }
            }
        };
        var p: Print = .{ .w = stdout };
        var cancel: std.atomic.Value(bool) = .init(false);
        var detail: ?[]u8 = null;
        defer if (detail) |d| gpa.free(d);
        session.turn(prompt.?, .{ .ctx = &p, .emit = Print.emit }, &cancel, &detail) catch |err| {
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

    try tui.run(init, &session);
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
