//! No frontend dependencies: frontends observe a Session only through `Sink`.

const std = @import("std");
const js = @import("js.zig");
const tools = @import("tools.zig");
const openai = @import("provider/openai.zig");

pub const Event = union(enum) {
    /// Slices are valid only during the callback.
    delta: struct { kind: openai.Kind, text: []const u8 },
    run_start: []const u8,
    run_end: struct { ok: bool, output: []const u8 },
    retry: struct { attempt: u32, delay_ms: u64, reason: []const u8 },
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
    tools: tools.Tools,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, cfg: openai.Config, home: []const u8) !Session {
        var s: Session = .{
            .gpa = gpa,
            .io = io,
            .client = client,
            .cfg = cfg,
            .arena = .init(gpa),
            .tools = .{ .io = io, .home = home },
        };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        const cwd = try std.process.currentPathAlloc(io, a);
        const system = try std.fmt.allocPrint(a, system_template, .{ cwd, tools.docs });
        try s.history.append(gpa, .{ .role = "system", .content = system });
        return s;
    }

    pub fn deinit(s: *Session) void {
        s.history.deinit(s.gpa);
        s.arena.deinit();
    }

    /// On failure, history is rolled back to the end of the last complete Step,
    /// or to before the user message if none completed.
    pub fn turn(s: *Session, user_text: []const u8, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        const a = s.arena.allocator();
        const before = s.history.items.len;
        try s.history.append(s.gpa, .{ .role = "user", .content = try a.dupe(u8, user_text) });
        var safe = before;
        s.usage = .{};
        s.steps = 0;
        errdefer s.history.shrinkRetainingCapacity(safe);

        for (0..max_steps) |_| {
            const reply = try s.complete(sink, cancel, detail);
            s.usage.add(reply.usage);
            s.steps += 1;
            try s.history.append(s.gpa, .{
                .role = "assistant",
                .content = reply.text,
                .tool_calls = if (reply.tool_calls.len > 0) reply.tool_calls else null,
            });
            if (reply.tool_calls.len == 0) return;

            for (reply.tool_calls) |call| {
                const result = try s.execute(call, sink, cancel);
                try s.history.append(s.gpa, .{ .role = "tool", .content = result, .tool_call_id = call.id });
            }
            safe = s.history.items.len;
            if (cancel.load(.acquire)) return error.Canceled;
        }
        detail.* = try std.fmt.allocPrint(s.gpa, "stopped after {d} steps", .{max_steps});
        return error.TooManySteps;
    }

    /// Retries transient failures, but only while nothing has been streamed:
    /// a retry after partial output would duplicate it in the frontend.
    fn complete(s: *Session, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !openai.Reply {
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
            return openai.stream(s.gpa, s.arena.allocator(), s.client, s.cfg, s.history.items, tools_json, provider_sink, cancel, detail) catch |err| {
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
