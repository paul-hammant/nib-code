//! No frontend dependencies: frontends observe a Session only through `Sink`.

const std = @import("std");
const sandbox = @import("sandbox.zig");
const tools = @import("tools.zig");
const Change = @import("tools/diff.zig").Change;
const provider = @import("provider.zig");
const session_log = @import("session/log.zig");
const instructions = @import("session/instructions.zig");
const output_format = @import("session/output.zig");

pub const Event = @import("session/events.zig").Event;
pub const ModelActivity = @import("session/events.zig").ModelActivity;

pub const Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: Event) anyerror!void,
    onModelActivity: ?*const fn (ctx: *anyopaque, activity: ModelActivity) anyerror!void = null,

    fn modelActivity(sink: Sink, activity: ModelActivity) !void {
        if (sink.onModelActivity) |notify| try notify(sink.ctx, activity);
    }
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
    \\- The value of the last expression comes back to you, together with anything passed to console.log. The entire Run shares a 16 KiB output budget, not 16 KiB per tool call. Large output is truncated by console entry (one call, including all its arguments) and final result; markers identify omitted entries and bytes. Filter in JS or split large output across Runs; tool results inside JS remain complete.
    \\- Search with tools.grep/tools.glob, not shell rg/find/grep.
    \\- For file/shell text with backticks, ${{ or backslashes, use JSON-escaped double-quoted strings, not template literals.
    \\
    \\When the task is done, answer the user directly without calling the tool.
;

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    cfg: provider.Config,
    /// Owns every string in `history`.
    arena: std.heap.ArenaAllocator,
    history: std.ArrayList(provider.Message) = .empty,
    /// Totals for the current or most recent Turn.
    usage: provider.Usage = .{},
    steps: u32 = 0,
    interrupt_signal: ?*const std.atomic.Value(std.posix.SIG) = null,
    /// Next-request estimate: latest usage plus tool results, or the compacted history size.
    context_tokens: u64 = 0,
    /// Automatic compaction is not retried until the context reaches this size.
    compact_backoff: u64 = 0,
    tools: tools.Tools,
    log: session_log.Log = undefined,
    id: []const u8 = undefined,
    parent_session_id: ?[]const u8 = null,
    options: Options = undefined,

    pub const Options = struct { environ: ?*const std.process.Environ.Map = null, depth: u32 = 0, parent_session_id: ?[]const u8 = null, home: []const u8, user_home: []const u8, resume_id: ?[]const u8 = null, continue_latest: bool = false };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, cfg: provider.Config, options: Options) !Session {
        var s: Session = .{
            .gpa = gpa,
            .io = io,
            .client = client,
            .cfg = cfg,
            .arena = .init(gpa),
            .tools = .{ .io = io, .home = options.user_home, .depth = options.depth, .environ = options.environ, .cfg = cfg, .track_changes = true },
            .parent_session_id = options.parent_session_id,
            .options = options,
        };
        errdefer s.arena.deinit();
        errdefer s.history.deinit(gpa);
        const a = s.arena.allocator();
        const cwd = try std.process.currentPathAlloc(io, a);
        const directory = try std.fs.path.join(a, &.{ options.home, "sessions" });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        if (options.resume_id != null or options.continue_latest) {
            const path = if (options.resume_id) |id| blk: {
                if (id.len != 32 or std.mem.indexOfNone(u8, id, "0123456789abcdef") != null) return error.InvalidSessionId;
                break :blk try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, id });
            } else try session_log.latest(io, a, directory, cwd);
            s.id = try a.dupe(u8, std.fs.path.stem(path));
            s.log = try session_log.Log.restore(io, gpa, a, path, &s.history, &s.context_tokens);
            errdefer s.log.close(io);
            try cfg.checkSession(s.log.provider, s.log.model);
            s.parent_session_id = s.log.parent_session_id;
            if (s.parent_session_id != null) s.tools.depth = @max(s.tools.depth, 1);
        } else {
            var random: [16]u8 = undefined;
            io.random(&random);
            const path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, std.fmt.bytesToHex(random, .lower) });
            s.id = try a.dupe(u8, std.fs.path.stem(path));
            s.log = try session_log.Log.create(io, path);
            errdefer s.log.close(io);
            const base = try std.fmt.allocPrint(a, system_template, .{ cwd, s.tools.api().docs });
            const global = try std.fs.path.join(a, &.{ options.home, "AGENTS.md" });
            const project = try std.fs.path.join(a, &.{ try instructions.projectRoot(io, a, cwd), "AGENTS.md" });
            const system = try instructions.append(io, a, base, global, project);
            try s.commit(0, &.{.{ .role = "system", .content = system }}, 0, cwd);
        }
        s.tools.session_id = s.id;
        return s;
    }

    /// Replaces this Session with a new one (`id == null`) or a logged one.
    /// On failure the current Session is left untouched.
    pub fn reopen(s: *Session, id: ?[]const u8) !void {
        var options = s.options;
        options.resume_id = id;
        options.continue_latest = false;
        const next = try Session.init(s.gpa, s.io, s.client, s.cfg, options);
        s.deinit();
        s.* = next;
    }

    pub fn deinit(s: *Session) void {
        s.tools.discardChanges(s.gpa);
        s.log.close(s.io);
        s.history.deinit(s.gpa);
        s.arena.deinit();
    }

    fn commit(s: *Session, from: usize, messages: []const provider.Message, tokens: u64, cwd: ?[]const u8) !void {
        try s.log.commit(s.io, s.gpa, &s.history, &s.context_tokens, .{ .from = from, .messages = messages, .context_tokens = tokens, .cwd = cwd, .provider = if (cwd != null) s.cfg.provider else null, .model = s.cfg.model, .parent_session_id = if (cwd != null) s.parent_session_id else null });
    }

    pub const Compaction = enum { compacted, too_few_steps, ineffective };

    pub fn compact(s: *Session, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !Compaction {
        const cut = compactionCut(s.history.items, s.cfg.context_window);
        if (cut <= 1) {
            try sink.emit(sink.ctx, .{ .notice = "compaction skipped: fewer than three complete Steps" });
            return .too_few_steps;
        }
        const a = s.arena.allocator();
        var request: std.ArrayList(provider.Message) = .empty;
        defer request.deinit(s.gpa);
        try request.appendSlice(s.gpa, s.history.items[0..cut]);
        try request.append(s.gpa, .{ .role = "user", .content = "Summarize the conversation above for another coding agent. Preserve goals, decisions, files, results, failures and unfinished work. Do not act on earlier requests. Return only a concise factual continuation summary." });
        const Silent = struct {
            fn delta(_: *anyopaque, _: provider.Kind, _: []const u8) !void {}
            fn data(ctx: *anyopaque) !void {
                const target: *Sink = @ptrCast(@alignCast(ctx));
                try target.modelActivity(.data);
            }
        };
        var observer = sink;
        // Thinking would spend the small summary budget on reasoning.
        var cfg = s.cfg;
        cfg.thinking = false;
        const reply = request_model: {
            try sink.modelActivity(.started);
            defer sink.modelActivity(.finished) catch {};
            break :request_model try provider.stream(s.gpa, a, s.client, cfg, s.id, request.items, "[]", @intCast(@min(2048, @max(32, s.cfg.context_window / 8))), .{ .ctx = &observer, .onDelta = Silent.delta, .onData = Silent.data }, cancel, detail);
        };
        s.usage.add(reply.usage);
        try sink.emit(sink.ctx, .{ .usage = s.usage });
        if (cancel.load(.acquire)) return error.Canceled;
        if (reply.text.len == 0 or reply.tool_calls.len != 0) return error.InvalidSummary;
        var replacement: std.ArrayList(provider.Message) = .empty;
        defer replacement.deinit(s.gpa);
        try replacement.append(s.gpa, .{ .role = "user", .content = try std.fmt.allocPrint(a, "Earlier session summary:\n{s}", .{reply.text}) });
        try replacement.appendSlice(s.gpa, s.history.items[cut..]);
        const before = s.context_tokens;
        const after = estimateTokens(s.history.items[0..1]) + estimateTokens(replacement.items);
        if (after >= estimateTokens(s.history.items) or after > s.cfg.context_window / 2) {
            try sink.emit(sink.ctx, .{ .notice = "compaction skipped: it would not bring context below half the window (retained Steps or system prompt are too large)" });
            return .ineffective;
        }
        const old_len = s.history.items.len;
        try s.commit(1, replacement.items, after, null);
        try sink.emit(sink.ctx, .{ .usage = s.usage });
        const message = try std.fmt.allocPrint(a, "compacted context: {d} → {d} messages, ~{d} → ~{d} tokens", .{ old_len, s.history.items.len, before, after });
        try sink.emit(sink.ctx, .{ .notice = message });
        return .compacted;
    }

    fn autoCompact(s: *Session, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        const result = s.compact(sink, cancel, detail) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => blk: {
                const msg = try std.fmt.allocPrint(s.arena.allocator(), "automatic compaction failed, continuing without it: {s}", .{detail.* orelse @errorName(err)});
                if (detail.*) |d| s.gpa.free(d);
                detail.* = null;
                try sink.emit(sink.ctx, .{ .notice = msg });
                break :blk .ineffective;
            },
        };
        // Only a spent summary request backs off; too_few_steps resolves itself a Step later.
        if (result == .ineffective) s.compact_backoff = s.context_tokens + s.cfg.context_window / 8;
    }

    pub fn turn(s: *Session, user_text: []const u8, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        var pending: std.ArrayList(provider.Message) = .empty;
        defer pending.deinit(s.gpa);
        var partial: Partial = .{};
        defer partial.deinit(s.gpa);
        try pending.append(s.gpa, .{ .role = "user", .content = try s.arena.allocator().dupe(u8, user_text) });
        s.usage = .{};
        s.steps = 0;
        try sink.emit(sink.ctx, .{ .usage = s.usage });
        s.runSteps(&pending, &partial, sink, cancel, detail) catch |err| {
            // A signal can surface as a read error instead of error.Canceled.
            if (err == error.Canceled or cancel.load(.acquire)) try s.commitInterrupted(pending.items, &partial);
            return err;
        };
    }

    const Partial = struct {
        text: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,

        fn clear(p: *Partial) void {
            p.text.clearRetainingCapacity();
            p.reasoning.clearRetainingCapacity();
        }

        fn deinit(p: *Partial, gpa: std.mem.Allocator) void {
            p.text.deinit(gpa);
            p.reasoning.deinit(gpa);
        }
    };

    /// An unfinished Step is dropped, since its tool calls would need results.
    fn commitInterrupted(s: *Session, pending: []const provider.Message, partial: *const Partial) !void {
        const a = s.arena.allocator();
        const terminated = if (s.interrupt_signal) |signal| signal.load(.acquire) == .TERM else false;
        const marker = if (terminated) "[interrupted: process terminated]" else "[interrupted by user]";
        const text = if (partial.text.items.len == 0) marker else try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ partial.text.items, marker });
        var reasoning: ?provider.Reasoning = null;
        if (s.cfg.provider == .chat_completions and s.cfg.thinking != false) {
            // DeepSeek thinking mode rejects any later request whose assistant messages lack reasoning_content.
            reasoning = .{ .provider = .chat_completions, .data = if (partial.reasoning.items.len == 0) marker else try a.dupe(u8, partial.reasoning.items) };
        }
        var messages: std.ArrayList(provider.Message) = .empty;
        defer messages.deinit(s.gpa);
        for (pending) |m| {
            if (!std.mem.eql(u8, m.role, "user")) break;
            try messages.append(s.gpa, m);
        }
        try messages.append(s.gpa, .{ .role = "assistant", .content = text, .reasoning = reasoning });
        try s.commit(s.history.items.len, messages.items, s.context_tokens + estimateTokens(messages.items), null);
    }

    fn runSteps(s: *Session, pending: *std.ArrayList(provider.Message), partial: *Partial, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        for (0..max_steps) |_| {
            const size = s.context_tokens + estimateTokens(pending.items);
            if (size >= s.cfg.context_window - s.cfg.context_window / 4 and size >= s.compact_backoff)
                try s.autoCompact(sink, cancel, detail);
            var request: std.ArrayList(provider.Message) = .empty;
            defer request.deinit(s.gpa);
            try request.appendSlice(s.gpa, s.history.items);
            try request.appendSlice(s.gpa, pending.items);
            const started: std.Io.Clock.Timestamp = .now(s.io, .awake);
            var model_timing: provider.ModelTiming = .init(s.io, started);
            var attempts: u32 = 0;
            var first_data_ms: ?u64 = null;
            const reply = try s.complete(request.items, sink, cancel, detail, partial, &model_timing, &attempts, &first_data_ms);
            const model_ms: u64 = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0));
            var run_timing: sandbox.RunTiming = .init(s.io, started);
            var run_ms: u64 = 0;
            partial.clear();
            s.usage.add(reply.usage);
            try sink.emit(sink.ctx, .{ .usage = s.usage });
            s.steps += 1;
            try pending.append(s.gpa, .{
                .role = "assistant",
                .content = reply.text,
                .tool_calls = if (reply.tool_calls.len > 0) reply.tool_calls else null,
                .reasoning = reply.reasoning,
                .phase = reply.phase,
            });
            var run_results: std.ArrayList(session_log.RunResult) = .empty;
            defer run_results.deinit(s.gpa);
            var output_tokens: u64 = 0;
            for (reply.tool_calls, 0..) |call, run_index| {
                run_timing.run_index = run_index;
                const result = try s.execute(call, sink, cancel, &run_timing);
                run_ms += result.run_ms orelse 0;
                try sink.emit(sink.ctx, .{ .usage = s.usage });
                try pending.append(s.gpa, .{ .role = "tool", .content = result.output, .tool_call_id = call.id });
                try run_results.append(s.gpa, .{ .tool_call_id = call.id, .ok = result.ok, .run_ms = result.run_ms });
                output_tokens += result.output.len / 3 + 1;
            }
            const tokens = reply.usage.prompt_tokens + reply.usage.completion_tokens + output_tokens;
            const ms: u64 = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0));
            try s.log.commit(s.io, s.gpa, &s.history, &s.context_tokens, .{
                .from = s.history.items.len,
                .messages = pending.items,
                .context_tokens = tokens,
                .model = s.cfg.model,
                .usage = reply.usage,
                .ms = ms,
                .model_ms = model_ms,
                .attempts = attempts,
                .first_data_ms = first_data_ms,
                .code = try model_timing.finish(s.arena.allocator(), reply.tool_calls),
                .run_ms = run_ms,
                .calls = run_timing.entries[0..run_timing.count],
                .calls_omitted = run_timing.omitted,
                .run_results = run_results.items,
            });
            pending.clearRetainingCapacity();
            try sink.emit(sink.ctx, .{ .usage = s.usage });
            if (reply.tool_calls.len == 0) return;
            if (cancel.load(.acquire)) return error.Canceled;
        }
        detail.* = try std.fmt.allocPrint(s.gpa, "stopped after {d} steps", .{max_steps});
        return error.TooManySteps;
    }

    fn complete(s: *Session, messages: []const provider.Message, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, partial: *Partial, timing: *provider.ModelTiming, attempts: *u32, first_data_ms: *?u64) !provider.Reply {
        const Forward = struct {
            sink: Sink,
            gpa: std.mem.Allocator,
            partial: *Partial,
            io: std.Io,
            started: std.Io.Clock.Timestamp,
            first_data_ms: *?u64,
            emitted: bool = false,
            fn onData(ctx: *anyopaque) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                if (f.first_data_ms.* == null) f.first_data_ms.* = @intCast(@max(f.started.untilNow(f.io).raw.toMilliseconds(), 0));
                try f.sink.modelActivity(.data);
            }
            fn onDelta(ctx: *anyopaque, kind: provider.Kind, text: []const u8) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                f.emitted = true;
                try (if (kind == .text) &f.partial.text else &f.partial.reasoning).appendSlice(f.gpa, text);
                try f.sink.emit(f.sink.ctx, .{ .delta = .{ .kind = kind, .text = text } });
            }
        };
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            var fwd: Forward = .{ .sink = sink, .gpa = s.gpa, .partial = partial, .io = s.io, .started = timing.started, .first_data_ms = first_data_ms };
            attempts.* = attempt;
            const provider_sink: provider.Sink = .{ .ctx = &fwd, .onDelta = Forward.onDelta, .onData = Forward.onData, .timing = timing };
            return request: {
                try sink.modelActivity(.started);
                defer sink.modelActivity(.finished) catch {};
                break :request provider.stream(s.gpa, s.arena.allocator(), s.client, s.cfg, s.id, messages, tools_json, null, provider_sink, cancel, detail);
            } catch |err| {
                if (err == error.Canceled or cancel.load(.acquire)) return err;
                const codex = s.cfg.provider == .codex;
                if ((!codex and fwd.emitted) or attempt == max_attempts or !transient(err)) {
                    if (codex) try s.log.diagnose(s.io, s.gpa, .{
                        .error_name = @errorName(err),
                        .message = detail.* orelse @errorName(err),
                        .attempts = attempt,
                        .step = s.steps + 1,
                    });
                    return err;
                }
                var delay_ms = @as(u64, 1000) << @intCast(attempt - 1);
                if (codex and err == error.RateLimited) if (detail.*) |message| {
                    delay_ms = @import("provider/codex.zig").retryDelayMs(message) orelse delay_ms;
                };
                try sink.emit(sink.ctx, .{ .retry = .{ .attempt = attempt, .delay_ms = delay_ms, .reason = detail.* orelse @errorName(err) } });
                if (detail.*) |d| s.gpa.free(d);
                detail.* = null;
                // Failed-attempt deltas stay visible, but must never be committed on later cancellation.
                partial.clear();
                try sleep(s.io, delay_ms, cancel);
                continue;
            };
        }
    }

    pub const Ran = struct {
        outcome: sandbox.Outcome,
        /// Session-arena-owned.
        changes: []const Change,
    };

    pub fn run(s: *Session, code: []const u8, cancel: ?*const std.atomic.Value(bool)) !Ran {
        return s.runTimed(code, cancel, null);
    }

    fn runTimed(s: *Session, code: []const u8, cancel: ?*const std.atomic.Value(bool), timing: ?*sandbox.RunTiming) !Ran {
        defer s.usage.add(s.tools.takeUsage());
        s.tools.progress.clear(s.gpa);
        defer s.tools.progress.clear(s.gpa);
        s.tools.discardChanges(s.gpa);
        var host = s.tools.host();
        host.timing = timing;
        if (timing) |t| t.started = .now(s.io, .awake);
        const outcome = try sandbox.eval(s.gpa, s.io, code, .{}, host, cancel);
        errdefer outcome.deinit(s.gpa);
        return .{ .outcome = outcome, .changes = try s.tools.takeChanges(s.gpa, s.arena.allocator()) };
    }

    const Executed = struct { output: []const u8, ok: bool, run_ms: ?u64 = null };

    /// Output is arena-owned.
    fn execute(s: *Session, call: provider.ToolCall, sink: Sink, cancel: *const std.atomic.Value(bool), timing: *sandbox.RunTiming) !Executed {
        const a = s.arena.allocator();
        if (!std.mem.eql(u8, call.function.name, "run"))
            return .{ .ok = false, .output = try std.fmt.allocPrint(a, "error: unknown tool `{s}`; the only tool is `run`", .{call.function.name}) };

        const Args = struct { code: []const u8 };
        const args = std.json.parseFromSlice(Args, s.gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch
            return .{ .ok = false, .output = try a.dupe(u8, "error: arguments must be a JSON object { \"code\": string }") };
        defer args.deinit();

        try sink.emit(sink.ctx, .{ .run_start = args.value.code });
        const Forward = struct {
            fn progress(ctx: *anyopaque, value: @import("session/events.zig").Progress) !void {
                const target: *const Sink = @ptrCast(@alignCast(ctx));
                try target.emit(target.ctx, .{ .progress = value });
            }
        };
        var progress_sink = sink;
        s.tools.progress.sink = .{ .ctx = &progress_sink, .emit = Forward.progress };
        defer s.tools.progress.sink = null;
        const ran = try s.runTimed(args.value.code, cancel, timing);
        const o = ran.outcome;
        defer o.deinit(s.gpa);

        const output = try output_format.format(a, o);
        const run_ms = timing.elapsed();
        try sink.emit(sink.ctx, .{ .run_end = .{ .ok = o.ok, .output = output, .changes = ran.changes } });
        return .{ .output = output, .ok = o.ok, .run_ms = run_ms };
    }
};

fn estimateTokens(messages: []const provider.Message) u64 {
    var total: u64 = 0;
    for (messages) |m| {
        const content = m.content orelse "";
        total += 8 + content.len / 3;
        if (m.reasoning) |r| total += r.data.len / 3;
        for (m.tool_calls orelse &.{}) |call| total += 8 + (call.id.len + call.function.name.len + call.function.arguments.len) / 3;
    }
    return total;
}

fn compactionCut(messages: []const provider.Message, window: u64) usize {
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
        error.HttpStatus, error.InvalidCredentials, error.ProviderFailed, error.Canceled, error.OutOfMemory, error.TooManyToolCalls => false,
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

test "formatOutcome" {
    const gpa = std.testing.allocator;
    var logs = "a\nb\n".*;
    var text = "1".*;
    const ok = try output_format.format(gpa, .{ .ok = true, .text = &text, .logs = &logs });
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("a\nb\nresult: 1", ok);
    var err = "Error: x".*;
    var none = "".*;
    const bad = try output_format.format(gpa, .{ .ok = false, .text = &err, .logs = &none });
    defer gpa.free(bad);
    try std.testing.expectEqualStrings("Error: x", bad);
    var undef = "undefined".*;
    const logged = try output_format.format(gpa, .{ .ok = true, .text = &undef, .logs = &logs });
    defer gpa.free(logged);
    try std.testing.expectEqualStrings("a\nb", logged);
    const silent = try output_format.format(gpa, .{ .ok = true, .text = &undef, .logs = &none });
    defer gpa.free(silent);
    try std.testing.expectEqualStrings("(no output)", silent);
}

test "system prompt documents every tool in JavaScript" {
    const gpa = std.testing.allocator;
    const prompt = try std.fmt.allocPrint(gpa, system_template, .{ "/work", tools.docs });
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "```js\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TypeScript") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "backticks, ${ or backslashes") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "entire Run shares a 16 KiB output budget, not 16 KiB per tool call") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "tool results inside JS remain complete") != null);
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
    const cfg: provider.Config = .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock" };
    var session = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root });
    defer session.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    var detail: ?[]u8 = null;
    defer if (detail) |d| t.allocator.free(d);
    const Quiet = struct {
        activities: std.ArrayList(ModelActivity) = .empty,
        fn emit(ctx: *anyopaque, event: Event) !void {
            const quiet: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .retry) try std.testing.expectEqual(ModelActivity.finished, quiet.activities.items[quiet.activities.items.len - 1]);
        }
        fn activity(ctx: *anyopaque, state: ModelActivity) !void {
            const quiet: *@This() = @ptrCast(@alignCast(ctx));
            try quiet.activities.append(std.testing.allocator, state);
        }
    };
    var ctx: Quiet = .{};
    defer ctx.activities.deinit(t.allocator);
    for (0..2) |completed| {
        if (completed == 1) try session.commit(session.history.items.len, &.{
            .{ .role = "user", .content = "saved" },
            .{ .role = "assistant", .tool_calls = &.{.{ .id = "safe", .function = .{ .name = "run", .arguments = "{}" } }} },
            .{ .role = "tool", .tool_call_id = "safe", .content = "saved result" },
        }, 100, null);
        for ([_]bool{ false, true }) |canceled| {
            cancel.store(canceled, .release);
            ctx.activities.clearRetainingCapacity();
            const result = session.turn("failed turn", .{ .ctx = &ctx, .emit = Quiet.emit, .onModelActivity = Quiet.activity }, &cancel, &detail);
            try t.expectEqual(@as(usize, if (canceled) 2 else max_attempts * 2), ctx.activities.items.len);
            var i: usize = 0;
            while (i < ctx.activities.items.len) : (i += 2) {
                try t.expectEqualSlices(ModelActivity, &.{ .started, .finished }, ctx.activities.items[i..][0..2]);
            }
            try t.expectError(if (canceled) error.Canceled else error.UnsupportedUriScheme, result);
            const directory = try std.fs.path.join(a, &.{ root, "sessions" });
            const path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, session.id });
            const data = try std.Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
            var restored: std.ArrayList(provider.Message) = .empty;
            var tokens: u64 = 0;
            _ = try session_log.replay(a, a, data, &restored, &tokens);
            try t.expectEqualDeep(session.history.items, restored.items);
            try t.expectEqual(session.context_tokens, tokens);
        }
    }
    for ([_]bool{ false, true }) |canceled| {
        cancel.store(canceled, .release);
        ctx.activities.clearRetainingCapacity();
        try t.expectError(if (canceled) error.Canceled else error.UnsupportedUriScheme, session.compact(.{ .ctx = &ctx, .emit = Quiet.emit, .onModelActivity = Quiet.activity }, &cancel, &detail));
        try t.expectEqualSlices(ModelActivity, &.{ .started, .finished }, ctx.activities.items);
    }
}

test "compaction cuts preserve recent turns and complete tool groups" {
    const t = std.testing;
    const call: provider.ToolCall = .{ .id = "c", .function = .{ .name = "run", .arguments = "{}" } };
    const messages = [_]provider.Message{
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
    const long_turn = [_]provider.Message{
        messages[0], messages[1], messages[4], messages[5], messages[6],
        messages[4], messages[5], messages[6], messages[4], messages[5],
        messages[6],
    };
    try t.expectEqual(@as(usize, 5), compactionCut(&long_turn, 128_000));
}
