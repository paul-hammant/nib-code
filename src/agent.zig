//! The Session engine: the Turn loop, Runs and the history sent to the model.
//! It knows nothing about the TUI; frontends observe it through `Sink`.

const std = @import("std");
const js = @import("js.zig");
const tools = @import("tools.zig");
const openai = @import("provider/openai.zig");

pub const Event = union(enum) {
    /// Slices are borrowed: valid only during the callback.
    delta: struct { kind: openai.Kind, text: []const u8 },
    run_start: []const u8,
    run_end: struct { ok: bool, output: []const u8 },
};

pub const Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: Event) anyerror!void,
};

const max_steps = 50;

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
    \\```ts
    \\{s}```
    \\
    \\Writing scripts:
    \\- Write plain JavaScript, not TypeScript: no type annotations, interfaces or `as` casts.
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
    /// Owns every string in `history`. Append-only, like the history itself.
    arena: std.heap.ArenaAllocator,
    history: std.ArrayList(openai.Message) = .empty,
    usage: openai.Usage = .{},
    tools: tools.Tools,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, cfg: openai.Config) !Session {
        var s: Session = .{
            .gpa = gpa,
            .io = io,
            .client = client,
            .cfg = cfg,
            .arena = .init(gpa),
            .tools = .{ .io = io },
        };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        const cwd = try std.process.currentPathAlloc(io, a);
        const system = try std.fmt.allocPrint(a, system_template, .{ cwd, tools.declarations });
        try s.history.append(gpa, .{ .role = "system", .content = system });
        return s;
    }

    pub fn deinit(s: *Session) void {
        s.history.deinit(s.gpa);
        s.arena.deinit();
    }

    /// Run one Turn. On failure the history is rolled back to the last point
    /// the provider will accept: after the last complete Step, or to before
    /// the user message if no Step completed.
    pub fn turn(s: *Session, user_text: []const u8, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        const a = s.arena.allocator();
        const before = s.history.items.len;
        try s.history.append(s.gpa, .{ .role = "user", .content = try a.dupe(u8, user_text) });
        var safe = before;
        errdefer s.history.shrinkRetainingCapacity(safe);

        const Fwd = struct {
            fn onDelta(ctx: *anyopaque, kind: openai.Kind, text: []const u8) !void {
                const k: *const Sink = @ptrCast(@alignCast(ctx));
                try k.emit(k.ctx, .{ .delta = .{ .kind = kind, .text = text } });
            }
        };
        var fwd = sink;
        const provider_sink: openai.Sink = .{ .ctx = &fwd, .onDelta = Fwd.onDelta };

        for (0..max_steps) |_| {
            const reply = try openai.stream(s.gpa, a, s.client, s.cfg, s.history.items, tools_json, provider_sink, cancel, detail);
            s.usage = reply.usage;
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

    /// Execute one tool call; returns the text sent back to the model (arena-owned).
    fn execute(s: *Session, call: openai.ToolCall, sink: Sink, cancel: *const std.atomic.Value(bool)) ![]const u8 {
        const a = s.arena.allocator();
        if (!std.mem.eql(u8, call.function.name, "run"))
            return std.fmt.allocPrint(a, "error: unknown tool `{s}`; the only tool is `run`", .{call.function.name});

        const Args = struct { code: []const u8 };
        const args = std.json.parseFromSlice(Args, s.gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch
            return a.dupe(u8, "error: arguments must be a JSON object { \"code\": string }");
        defer args.deinit();

        try sink.emit(sink.ctx, .{ .run_start = args.value.code });
        const o = try js.eval(s.gpa, s.io, args.value.code, .{}, s.tools.host(), cancel);
        defer o.deinit(s.gpa);

        const formatted = try formatOutcome(s.gpa, o);
        defer s.gpa.free(formatted);
        const output = try tools.truncateMiddle(a, formatted);
        try sink.emit(sink.ctx, .{ .run_end = .{ .ok = o.ok, .output = output } });
        return output;
    }
};

fn formatOutcome(gpa: std.mem.Allocator, o: js.Outcome) ![]u8 {
    const logs = std.mem.trimEnd(u8, o.logs, "\n");
    const sep: []const u8 = if (logs.len > 0) "\n" else "";
    if (o.ok) return std.fmt.allocPrint(gpa, "{s}{s}result: {s}", .{ logs, sep, o.text });
    // QuickJS reports TypeScript syntax with unhelpful messages
    // ("missing initializer for variable"), so name the likely cause.
    const hint = if (std.mem.startsWith(u8, o.text, "SyntaxError"))
        "\nhint: scripts must be plain JavaScript; TypeScript syntax (type annotations, interfaces, `as`) is not supported."
    else
        "";
    return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ logs, sep, o.text, hint });
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
}
