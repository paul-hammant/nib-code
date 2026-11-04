const std = @import("std");
const provider = @import("../provider.zig");
const Change = @import("../tools/diff.zig").Change;

pub const Progress = struct {
    agent: usize,
    run: usize = 0,
    kind: Background.Kind = .agent,
    elapsed_ms: u64 = 0,
    background_id: ?[]const u8 = null,
    prompt: []const u8,
    state: enum { queued, working, done, failed, canceled, timed_out } = .working,
    step: u32 = 0,
    tools: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    usage: provider.Usage = .{},

    pub fn clone(p: Progress, gpa: std.mem.Allocator) !Progress {
        const prompt = try gpa.dupe(u8, p.prompt);
        errdefer gpa.free(prompt);
        const used = try cloneStrings(gpa, p.tools);
        errdefer freeStrings(gpa, used);
        const files = try cloneStrings(gpa, p.files);
        errdefer freeStrings(gpa, files);
        const background_id = if (p.background_id) |id| try gpa.dupe(u8, id) else null;
        return .{ .kind = p.kind, .elapsed_ms = p.elapsed_ms, .run = p.run, .background_id = background_id, .agent = p.agent, .prompt = prompt, .state = p.state, .step = p.step, .tools = used, .files = files, .usage = p.usage };
    }

    pub fn deinit(p: *Progress, gpa: std.mem.Allocator) void {
        gpa.free(p.prompt);
        if (p.background_id) |id| gpa.free(id);
        freeStrings(gpa, p.tools);
        freeStrings(gpa, p.files);
        p.* = undefined;
    }

    fn cloneStrings(gpa: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| gpa.free(s);
            out.deinit(gpa);
        }
        for (items) |s| {
            const copy = try gpa.dupe(u8, s);
            errdefer gpa.free(copy);
            try out.append(gpa, copy);
        }
        return out.toOwnedSlice(gpa);
    }

    fn freeStrings(gpa: std.mem.Allocator, items: []const []const u8) void {
        for (items) |s| gpa.free(s);
        gpa.free(items);
    }
};

pub const Timing = struct {
    wall_ms: u64 = 0,
    model_ms: u64 = 0,
    run_ms: u64 = 0,
    llm_calls: u64 = 0,
    agent_calls: u64 = 0,
};

pub const TurnSummary = struct {
    status: enum { completed, canceled, failed } = .completed,
    steps: u32 = 0,
    usage: provider.Usage = .{},
    timing: Timing = .{},
};

pub const ModelActivity = enum { started, data, finished };

pub const Background = struct {
    id: []const u8,
    kind: Kind,
    state: enum { started, finished, lost },
    ok: ?bool = null,
    result: ?[]const u8 = null,

    pub const Kind = enum { agent, bash };
};

pub const Event = union(enum) {
    step: struct { n: u32, effort: []const u8, source: provider.EffortSource },
    /// Slices are valid only during the callback.
    delta: struct { kind: provider.Kind, text: []const u8 },
    run_start: []const u8,
    run_end: struct { ok: bool, output: []const u8, changes: []const Change = &.{} },
    retry: struct { attempt: u32, delay_ms: u64, reason: []const u8 },
    notice: []const u8,
    usage: provider.Usage,
    progress: Progress,
    background: Background,
    turn_end: TurnSummary,
};

pub const JsonEvent = union(enum) {
    start: struct { session_id: []const u8 },
    event: Event,
    end: End,
    @"error": Failure,

    pub const Failure = struct { message: []const u8 = "", usage: provider.Usage = .{}, steps: u32 = 0, timing: ?Timing = null };

    pub const End = struct { text: []const u8, usage: provider.Usage, steps: u32, timing: ?Timing = null };

    pub fn jsonStringify(value: JsonEvent, writer: *std.json.Stringify) !void {
        switch (value) {
            .event => |event| if (event == .background) {
                const b = event.background;
                try writer.write(.{ .background = .{ .id = b.id, .kind = b.kind, .state = b.state, .ok = b.ok } });
            } else try writer.write(event),
            inline else => |payload, tag| {
                try writer.beginObject();
                try writer.objectField(@tagName(tag));
                try writer.write(payload);
                try writer.endObject();
            },
        }
    }

    pub fn write(value: JsonEvent, writer: *std.Io.Writer) !void {
        try writer.print("{f}\n", .{std.json.fmt(value, .{ .emit_null_optional_fields = false })});
        try writer.flush();
    }
};
