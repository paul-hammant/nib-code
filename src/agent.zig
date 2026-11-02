//! No frontend dependencies: frontends observe a Session only through `Sink`.

const std = @import("std");
const js = @import("js.zig");
const tools = @import("tools.zig");
const openai = @import("provider/openai.zig");
const session_log = @import("log.zig");
const instructions = @import("instructions.zig");

pub const Event = union(enum) {
    /// Slices are valid only during the callback.
    delta: struct { kind: openai.Kind, text: []const u8 },
    run_start: []const u8,
    run_end: struct { ok: bool, output: []const u8 },
    retry: struct { attempt: u32, delay_ms: u64, reason: []const u8 },
    notice: []const u8,
};

pub const Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: Event) anyerror!void,
};

const max_steps = 50;
const max_attempts = 5;

const tools_json =
    \\[{"type":"function","function":{"name":"run",
    \\"description":"Run JavaScript in a fresh sandbox. The `tools` API it can call is described in the system prompt.",
    \\"parameters":{"type":"object","properties":{"code":{"type":"string",
    \\"description":"JavaScript source. Top-level await is allowed; the last expression's value is returned."}},
    \\"required":["code"]}}}]
;

const system_template =
    \\You are nib, a coding agent working in {s}.
    \\
    \\You act by calling the `run` tool with JavaScript. Each call runs in a fresh sandbox: no variables survive between calls, so write anything you need later to a file. The script can affect the outside world only through these functions:
    \\
    \\```js
    \\{s}```
    \\
    \\Writing scripts:
    \\- Top-level `await` works. Combine related steps in one script (read several files, run a command, filter the output) and return only what you need.
    \\- The value of the last expression comes back to you, together with anything passed to console.log. Large output is truncated, so filter before returning it.
    \\
    \\When the task is done, answer the user directly without calling the tool.
;

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    cfg: openai.Config,
    /// Owns every string in `history`.
    arena: std.heap.ArenaAllocator,
    history: std.ArrayList(openai.Message) = .empty,
    /// Totals for the current or most recent Turn.
    usage: openai.Usage = .{},
    steps: u32 = 0,
    /// Next-request estimate: latest usage plus tool results, or the compacted history size.
    context_tokens: u64 = 0,
    tools: tools.Tools,
    log: session_log.Log = undefined,

    pub const Options = struct { home: []const u8, data_home: []const u8, config_home: []const u8, resume_id: ?[]const u8 = null, continue_latest: bool = false };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, cfg: openai.Config, options: Options) !Session {
        var s: Session = .{
            .gpa = gpa,
            .io = io,
            .client = client,
            .cfg = cfg,
            .arena = .init(gpa),
            .tools = .{ .io = io, .home = options.home },
        };
        errdefer s.arena.deinit();
        errdefer s.history.deinit(gpa);
        const a = s.arena.allocator();
        const cwd = try std.process.currentPathAlloc(io, a);
        const directory = try std.fs.path.join(a, &.{ options.data_home, "nib/sessions" });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        if (options.resume_id != null or options.continue_latest) {
            const path = if (options.resume_id) |id| blk: {
                if (id.len != 32 or std.mem.indexOfNone(u8, id, "0123456789abcdef") != null) return error.InvalidSessionId;
                break :blk try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, id });
            } else try session_log.latest(io, a, directory, cwd);
            s.log = try session_log.Log.restore(io, gpa, a, path, &s.history, &s.context_tokens);
        } else {
            var random: [16]u8 = undefined;
            io.random(&random);
            const path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, std.fmt.bytesToHex(random, .lower) });
            s.log = try session_log.Log.create(io, path);
            errdefer s.log.close(io);
            const base = try std.fmt.allocPrint(a, system_template, .{ cwd, tools.docs });
            const global = try std.fs.path.join(a, &.{ options.config_home, "nib/AGENTS.md" });
            const project = try std.fs.path.join(a, &.{ try instructions.projectRoot(io, a, cwd), "AGENTS.md" });
            const system = try instructions.append(io, a, base, global, project);
            try s.commit(0, &.{.{ .role = "system", .content = system }}, 0, cwd);
        }
        return s;
    }

    pub fn deinit(s: *Session) void {
        s.log.close(s.io);
        s.history.deinit(s.gpa);
        s.arena.deinit();
    }

    fn commit(s: *Session, from: usize, messages: []const openai.Message, tokens: u64, cwd: ?[]const u8) !void {
        try s.log.commit(s.io, s.gpa, &s.history, &s.context_tokens, .{ .from = from, .messages = messages, .context_tokens = tokens, .cwd = cwd });
    }

    pub fn compact(s: *Session, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        const cut = compactionCut(s.history.items, s.cfg.context_window);
        if (cut <= 1) {
            try sink.emit(sink.ctx, .{ .notice = "compaction skipped: fewer than three complete Steps" });
            return;
        }
        const a = s.arena.allocator();
        var request: std.ArrayList(openai.Message) = .empty;
        defer request.deinit(s.gpa);
        try request.appendSlice(s.gpa, s.history.items[0..cut]);
        try request.append(s.gpa, .{ .role = "user", .content = "Summarize the conversation above for another coding agent. Preserve goals, decisions, files, results, failures and unfinished work. Do not act on earlier requests. Return only a concise factual continuation summary." });
        const Silent = struct {
            fn delta(_: *anyopaque, _: openai.Kind, _: []const u8) !void {}
        };
        const reply = try openai.stream(s.gpa, a, s.client, s.cfg, request.items, "[]", @intCast(@min(2048, @max(32, s.cfg.context_window / 8))), .{ .ctx = s, .onDelta = Silent.delta }, cancel, detail);
        s.usage.add(reply.usage);
        if (cancel.load(.acquire)) return error.Canceled;
        if (reply.text.len == 0 or reply.tool_calls.len != 0) return error.InvalidSummary;
        var replacement: std.ArrayList(openai.Message) = .empty;
        defer replacement.deinit(s.gpa);
        try replacement.append(s.gpa, .{ .role = "user", .content = try std.fmt.allocPrint(a, "Earlier session summary:\n{s}", .{reply.text}) });
        try replacement.appendSlice(s.gpa, s.history.items[cut..]);
        const before = s.context_tokens;
        const after = estimateTokens(s.history.items[0..1]) + estimateTokens(replacement.items);
        if (after >= estimateTokens(s.history.items) or after > s.cfg.context_window / 2) {
            detail.* = try s.gpa.dupe(u8, "compaction could not reduce context below half the window; retained Steps or system prompt are too large");
            return error.CompactionIneffective;
        }
        const old_len = s.history.items.len;
        try s.commit(1, replacement.items, after, null);
        const message = try std.fmt.allocPrint(a, "compacted context: {d} → {d} messages, ~{d} → ~{d} tokens", .{ old_len, s.history.items.len, before, after });
        try sink.emit(sink.ctx, .{ .notice = message });
    }

    pub fn turn(s: *Session, user_text: []const u8, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        const a = s.arena.allocator();
        var pending: std.ArrayList(openai.Message) = .empty;
        defer pending.deinit(s.gpa);
        try pending.append(s.gpa, .{ .role = "user", .content = try a.dupe(u8, user_text) });
        s.usage = .{};
        s.steps = 0;

        for (0..max_steps) |_| {
            if (s.context_tokens + estimateTokens(pending.items) >= s.cfg.context_window - s.cfg.context_window / 4)
                try s.compact(sink, cancel, detail);
            var request: std.ArrayList(openai.Message) = .empty;
            defer request.deinit(s.gpa);
            try request.appendSlice(s.gpa, s.history.items);
            try request.appendSlice(s.gpa, pending.items);
            const reply = try s.complete(request.items, sink, cancel, detail);
            s.usage.add(reply.usage);
            s.steps += 1;
            try pending.append(s.gpa, .{
                .role = "assistant",
                .content = reply.text,
                .tool_calls = if (reply.tool_calls.len > 0) reply.tool_calls else null,
            });
            var output_tokens: u64 = 0;
            for (reply.tool_calls) |call| {
                const result = try s.execute(call, sink, cancel);
                try pending.append(s.gpa, .{ .role = "tool", .content = result, .tool_call_id = call.id });
                output_tokens += result.len / 3 + 1;
            }
            const tokens = reply.usage.prompt_tokens + reply.usage.completion_tokens + output_tokens;
            try s.commit(s.history.items.len, pending.items, tokens, null);
            pending.clearRetainingCapacity();
            if (reply.tool_calls.len == 0) return;
            if (cancel.load(.acquire)) return error.Canceled;
        }
        detail.* = try std.fmt.allocPrint(s.gpa, "stopped after {d} steps", .{max_steps});
        return error.TooManySteps;
    }

    /// Retries transient failures, but only while nothing has been streamed:
    /// a retry after partial output would duplicate it in the frontend.
    fn complete(s: *Session, messages: []const openai.Message, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !openai.Reply {
        const Forward = struct {
            sink: Sink,
            emitted: bool = false,
            fn onDelta(ctx: *anyopaque, kind: openai.Kind, text: []const u8) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                f.emitted = true;
                try f.sink.emit(f.sink.ctx, .{ .delta = .{ .kind = kind, .text = text } });
            }
        };
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            var fwd: Forward = .{ .sink = sink };
            const provider_sink: openai.Sink = .{ .ctx = &fwd, .onDelta = Forward.onDelta };
            return openai.stream(s.gpa, s.arena.allocator(), s.client, s.cfg, messages, tools_json, null, provider_sink, cancel, detail) catch |err| {
                if (fwd.emitted or attempt == max_attempts or !transient(err) or cancel.load(.acquire)) return err;
                const delay_ms = @as(u64, 1000) << @intCast(attempt - 1);
                try sink.emit(sink.ctx, .{ .retry = .{ .attempt = attempt, .delay_ms = delay_ms, .reason = detail.* orelse @errorName(err) } });
                if (detail.*) |d| s.gpa.free(d);
                detail.* = null;
                try sleep(s.io, delay_ms, cancel);
                continue;
            };
        }
    }

    /// Result is arena-owned.
    fn execute(s: *Session, call: openai.ToolCall, sink: Sink, cancel: *const std.atomic.Value(bool)) ![]const u8 {
        const a = s.arena.allocator();
        if (!std.mem.eql(u8, call.function.name, "run"))
            return std.fmt.allocPrint(a, "error: unknown tool `{s}`; the only tool is `run`", .{call.function.name});

        const Args = struct { code: []const u8 };
        const args = std.json.parseFromSlice(Args, s.gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch
            return a.dupe(u8, "error: arguments must be a JSON object { \"code\": string }");
        defer args.deinit();

        try sink.emit(sink.ctx, .{ .run_start = args.value.code });
        s.tools.cancel = cancel;
        const o = try js.eval(s.gpa, s.io, args.value.code, .{}, s.tools.host(), cancel);
        defer o.deinit(s.gpa);

        const formatted = try formatOutcome(s.gpa, o);
        defer s.gpa.free(formatted);
        const output = try tools.truncateMiddle(a, formatted);
        try sink.emit(sink.ctx, .{ .run_end = .{ .ok = o.ok, .output = output } });
        return output;
    }
};

fn estimateTokens(messages: []const openai.Message) u64 {
    var total: u64 = 0;
    for (messages) |m| {
        const content = m.content orelse "";
        total += 8 + content.len / 3;
        for (m.tool_calls orelse &.{}) |call| total += 8 + (call.id.len + call.function.name.len + call.function.arguments.len) / 3;
    }
    return total;
}

fn compactionCut(messages: []const openai.Message, window: u64) usize {
    var turns: usize = 0;
    var cut: usize = 1;
    var i = messages.len;
    while (i > 1) {
        i -= 1;
        if (std.mem.eql(u8, messages[i].role, "user")) {
            turns += 1;
            if (turns == 2) {
                cut = i;
                break;
            }
        }
    }
    if (cut > 1 and estimateTokens(messages[cut..]) <= window / 4) return cut;
    var steps: usize = 0;
    i = messages.len;
    while (i > 1) {
        i -= 1;
        const m = messages[i];
        if (!std.mem.eql(u8, m.role, "assistant")) continue;
        steps += 1;
        const calls = m.tool_calls orelse &.{};
        if (steps == 3) return i + 1 + calls.len;
    }
    return 1;
}

fn transient(err: anyerror) bool {
    return switch (err) {
        error.HttpStatus, error.Canceled, error.OutOfMemory, error.TooManyToolCalls => false,
        else => true,
    };
}

fn sleep(io: std.Io, ms: u64, cancel: *const std.atomic.Value(bool)) !void {
    var left = ms;
    while (left > 0) {
        if (cancel.load(.acquire)) return error.Canceled;
        const step = @min(left, 100);
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(@intCast(step)), .clock = .awake }, io);
        left -= step;
    }
}

fn formatOutcome(gpa: std.mem.Allocator, o: js.Outcome) ![]u8 {
    const logs = std.mem.trimEnd(u8, o.logs, "\n");
    const value: []const u8 = if (o.ok and std.mem.eql(u8, o.text, "undefined")) "" else o.text;
    if (logs.len == 0 and value.len == 0) return gpa.dupe(u8, "(no output)");
    const sep: []const u8 = if (logs.len > 0 and value.len > 0) "\n" else "";
    const label: []const u8 = if (o.ok and value.len > 0) "result: " else "";
    return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ logs, sep, label, value });
}

test "formatOutcome" {
    const gpa = std.testing.allocator;
    var logs = "a\nb\n".*;
    var text = "1".*;
    const ok = try formatOutcome(gpa, .{ .ok = true, .text = &text, .logs = &logs });
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("a\nb\nresult: 1", ok);
    var err = "Error: x".*;
    var none = "".*;
    const bad = try formatOutcome(gpa, .{ .ok = false, .text = &err, .logs = &none });
    defer gpa.free(bad);
    try std.testing.expectEqualStrings("Error: x", bad);
    var undef = "undefined".*;
    const logged = try formatOutcome(gpa, .{ .ok = true, .text = &undef, .logs = &logs });
    defer gpa.free(logged);
    try std.testing.expectEqualStrings("a\nb", logged);
    const silent = try formatOutcome(gpa, .{ .ok = true, .text = &undef, .logs = &none });
    defer gpa.free(silent);
    try std.testing.expectEqualStrings("(no output)", silent);
}

test "system prompt documents every tool in JavaScript" {
    const gpa = std.testing.allocator;
    const prompt = try std.fmt.allocPrint(gpa, system_template, .{ "/work", tools.docs });
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "```js\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TypeScript") == null);
    for (tools.names) |name| {
        const call = try std.fmt.allocPrint(gpa, "async {s}({{", .{name});
        defer gpa.free(call);
        try std.testing.expect(std.mem.indexOf(u8, prompt, call) != null);
    }
}

test "failed Turn leaves replay equal to in-memory safe history" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    const cfg: openai.Config = .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock" };
    var session = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .data_home = root, .config_home = root });
    defer session.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    var detail: ?[]u8 = null;
    defer if (detail) |d| t.allocator.free(d);
    const Quiet = struct {
        fn emit(_: *anyopaque, _: Event) !void {}
    };
    var ctx: u8 = 0;
    for (0..2) |completed| {
        if (completed == 1) try session.commit(session.history.items.len, &.{
            .{ .role = "user", .content = "saved" },
            .{ .role = "assistant", .tool_calls = &.{.{ .id = "safe", .function = .{ .name = "run", .arguments = "{}" } }} },
            .{ .role = "tool", .tool_call_id = "safe", .content = "saved result" },
        }, 100, null);
        const result = session.turn("not committed", .{ .ctx = &ctx, .emit = Quiet.emit }, &cancel, &detail);
        try t.expectError(error.UnsupportedUriScheme, result);
        const directory = try std.fs.path.join(a, &.{ root, "nib/sessions" });
        const cwd = try std.process.currentPathAlloc(t.io, a);
        const path = try session_log.latest(t.io, a, directory, cwd);
        const data = try std.Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
        var restored: std.ArrayList(openai.Message) = .empty;
        var tokens: u64 = 0;
        _ = try session_log.replay(a, a, data, &restored, &tokens);
        try t.expectEqualDeep(session.history.items, restored.items);
        try t.expectEqual(session.context_tokens, tokens);
    }
}

test "compaction cuts preserve recent turns and complete tool groups" {
    const t = std.testing;
    const call: openai.ToolCall = .{ .id = "c", .function = .{ .name = "run", .arguments = "{}" } };
    const messages = [_]openai.Message{
        .{ .role = "system", .content = "system" },
        .{ .role = "user", .content = "first" },
        .{ .role = "assistant", .content = "done" },
        .{ .role = "user", .content = "second" },
        .{ .role = "assistant", .tool_calls = &.{ call, call } },
        .{ .role = "tool", .tool_call_id = "c", .content = "one" },
        .{ .role = "tool", .tool_call_id = "c", .content = "two" },
        .{ .role = "assistant", .content = "done" },
        .{ .role = "user", .content = "third" },
        .{ .role = "assistant", .content = "done" },
    };
    try t.expectEqual(@as(usize, 3), compactionCut(&messages, 128_000));
    try t.expectEqual(@as(usize, 7), compactionCut(&messages, 64));
    try t.expectEqual(@as(usize, 1), compactionCut(messages[0..7], 64));
    const long_turn = [_]openai.Message{
        messages[0], messages[1], messages[4], messages[5], messages[6],
        messages[4], messages[5], messages[6], messages[4], messages[5],
        messages[6],
    };
    try t.expectEqual(@as(usize, 5), compactionCut(&long_turn, 128_000));
}
