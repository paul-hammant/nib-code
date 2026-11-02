const std = @import("std");
const js = @import("js.zig");
const openai = @import("provider/openai.zig");
const tui = @import("tui.zig");
const JsonEvent = @import("events.zig").JsonEvent;
const agent = @import("agent.zig");

pub const Config = struct {
    llm: openai.Config,

    fn fromEnv(env: *const std.process.Environ.Map) !Config {
        return .{ .llm = .{
            .api_key = env.get("NIB_API_KEY") orelse env.get("DEEPSEEK_API_KEY") orelse "",
            .base_url = env.get("NIB_BASE_URL") orelse "https://api.deepseek.com",
            .model = env.get("NIB_MODEL") orelse "deepseek-flash",
            .context_window = if (env.get("NIB_CONTEXT_WINDOW")) |v| std.fmt.parseInt(u64, v, 10) catch return error.InvalidContextWindow else 1_000_000,
            .thinking = if (env.get("NIB_THINKING")) |v| parseSwitch(v) orelse return error.InvalidThinking else null,
            .reasoning_effort = env.get("NIB_REASONING_EFFORT"),
        } };
    }
};

pub fn main(init: std.process.Init) void {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var detail: ?[]u8 = null;
    defer if (detail) |d| init.gpa.free(d);
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.process.exit(1);
    };
    const json = args.len > 1 and std.mem.eql(u8, args[1], "ask") and for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) break true;
    } else false;
    run(init, args, &out.interface, json, &detail) catch |err| {
        if (json) {
            JsonEvent.write(.{ .@"error" = .{ .message = detail orelse @errorName(err) } }, &out.interface) catch {};
        } else std.debug.print("nib: {s}\n", .{detail orelse @errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init, args: []const []const u8, stdout: *std.Io.Writer, json: bool, detail: *?[]u8) !void {
    const gpa = init.gpa;
    const cfg = try Config.fromEnv(init.environ_map);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "js")) {
        const r = try js.eval(gpa, init.io, args[2], .{}, null, null);
        defer r.deinit(gpa);
        try stdout.print("{s}{s}{s}\n", .{ r.logs, if (r.ok) "" else "error: ", r.text });
        try stdout.flush();
        if (!r.ok) return error.ScriptFailed;
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
        } else if (ask and std.mem.eql(u8, arg, "--json")) {} else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue")) {
            options.continue_latest = true;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            i += 1;
            if (i == args.len) return error.MissingSessionId;
            options.resume_id = args[i];
        } else if (ask and prompt == null) {
            prompt = arg;
        } else return error.InvalidArguments;
    }
    if (options.continue_latest and options.resume_id != null) return error.ConflictingResumeOptions;
    if (ask and prompt == null) return error.MissingPrompt;

    var client: std.http.Client = .{ .allocator = gpa, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    if (ask and cfg.llm.api_key.len == 0) return error.MissingApiKey;
    var session = try agent.Session.init(gpa, init.io, &client, cfg.llm, options);
    defer session.deinit();

    if (ask) {
        const Print = struct {
            w: *std.Io.Writer,
            json: bool,
            fn emit(ctx: *anyopaque, ev: agent.Event) !void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                if (self.json) return JsonEvent.write(.{ .event = ev }, self.w);
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
        if (std.mem.eql(u8, prompt.?, "-")) {
            var input = std.Io.File.stdin().reader(init.io, &.{});
            prompt = try input.interface.allocRemaining(init.arena.allocator(), .unlimited);
        }
        if (json) try JsonEvent.write(.{ .start = .{ .session_id = session.id } }, stdout);
        var p: Print = .{ .w = stdout, .json = json };
        var cancel: std.atomic.Value(bool) = .init(false);
        try session.turn(prompt.?, .{ .ctx = &p, .emit = Print.emit }, &cancel, detail);
        if (json) {
            try JsonEvent.write(.{ .end = .{
                .text = session.history.items[session.history.items.len - 1].content orelse "",
                .usage = session.usage,
                .steps = session.steps,
            } }, stdout);
            return;
        }
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

fn parseSwitch(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "on")) return true;
    if (std.mem.eql(u8, v, "off")) return false;
    return null;
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
