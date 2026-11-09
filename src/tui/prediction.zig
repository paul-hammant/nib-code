//! Ghost-text prediction of the user's next message. Background, stateless
//! and silent: every failure shows nothing.

const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../provider.zig");
const web = @import("../tools/web.zig");
const tui = @import("../tui.zig");
const Editor = @import("editor.zig").Editor;

const timeout_ms = 15_000;
const max_reply_bytes = 3 * 1024;
const max_user_bytes = 1024;
const max_tokens = 256;

const instruction = "Predict the user's next message to this coding agent, as the user would type it, in the user's language. One line, at most 80 characters. If unsure, reply with nothing. Return only the text.";

const acknowledgements = [_][]const u8{ "ok", "okay", "thanks", "thank you", "thx", "好的", "谢谢", "嗯" };

fn headEnd(text: []const u8, max: usize) usize {
    var end = @min(text.len, max);
    while (end < text.len and end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

fn tailStart(text: []const u8, max: usize) usize {
    var start = text.len -| max;
    while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    return start;
}

/// The model input: the head of the user's message and the tail of the reply.
pub fn buildInput(a: std.mem.Allocator, user: []const u8, reply: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "User's last message:\n{s}\n\nAssistant's last reply:\n{s}", .{
        user[0..headEnd(user, max_user_bytes)],
        reply[tailStart(reply, max_reply_bytes)..],
    });
}

/// First line without surrounding quotes, owned; null when empty or a trivial acknowledgement.
pub fn filter(gpa: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const first = std.mem.sliceTo(std.mem.trim(u8, raw, " \t\r\n"), '\n');
    var line = std.mem.trim(u8, first, " \t\r");
    const pairs = [_][2][]const u8{ .{ "\"", "\"" }, .{ "'", "'" }, .{ "`", "`" }, .{ "“", "”" }, .{ "「", "」" } };
    for (pairs) |pair| {
        if (line.len >= pair[0].len + pair[1].len and std.mem.startsWith(u8, line, pair[0]) and std.mem.endsWith(u8, line, pair[1])) {
            line = std.mem.trim(u8, line[pair[0].len .. line.len - pair[1].len], " \t\r");
            break;
        }
    }
    const chars = std.unicode.utf8CountCodepoints(line) catch return null;
    if (chars < 2) return null;
    const bare = std.mem.trimEnd(u8, line, ".!。！");
    for (acknowledgements) |ack| if (std.ascii.eqlIgnoreCase(bare, ack)) return null;
    return try gpa.dupe(u8, line);
}

const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(tui.Event),
    cfg: provider.Config,
    cache_key: []u8,
    input: []u8,
    generation: u64,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn silent(_: *anyopaque, _: provider.Kind, _: []const u8) !void {}

    fn run(w: *Worker) void {
        defer w.done.store(true, .release);
        const text = w.request() orelse return;
        if (w.cancel.load(.acquire)) return w.gpa.free(text);
        const posted = w.loop.tryPostEvent(.{ .prediction = .{ .generation = w.generation, .text = text } }) catch false;
        if (!posted) w.gpa.free(text);
    }

    fn request(w: *Worker) ?[]u8 {
        const U = union(enum) { reply: ?[]u8, stop: web.Stop };
        var buffer: [2]U = undefined;
        var select = std.Io.Select(U).init(w.io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.reply, ask, .{w}) catch return null;
        select.concurrent(.stop, web.watch, .{ w.io, &w.cancel, @as(u64, timeout_ms) }) catch return null;
        const first = select.await() catch return null;
        return switch (first) {
            .reply => |text| text,
            .stop => blk: {
                w.cancel.store(true, .release);
                break :blk null;
            },
        };
    }

    fn ask(w: *Worker) ?[]u8 {
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var client: std.http.Client = .{ .allocator = w.gpa, .io = w.io };
        defer client.deinit();
        const messages = [_]provider.Message{
            .{ .role = "system", .content = instruction },
            .{ .role = "user", .content = w.input },
        };
        var detail: ?[]u8 = null;
        defer if (detail) |d| w.gpa.free(d);
        var attempts: u32 = 0;
        const reply = provider.complete(w.gpa, a, &client, w.cfg, w.cache_key, &messages, "[]", max_tokens, .{ .ctx = w, .onDelta = silent, .replay_safe = true }, &w.cancel, &detail, &attempts, null) catch return null;
        return (filter(w.gpa, reply.text) catch null) orelse null;
    }

    fn finish(w: *Worker) void {
        w.cancel.store(true, .release);
        w.thread.join();
        w.gpa.free(w.cache_key);
        w.gpa.free(w.input);
        w.gpa.destroy(w);
    }
};

pub const State = struct {
    /// Bumped by every invalidation; a result carrying an older value is dropped.
    generation: u64 = 0,
    text: ?[]u8 = null,
    current: ?*Worker = null,
    workers: std.ArrayList(*Worker) = .empty,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.text) |t| gpa.free(t);
        for (s.workers.items) |w| w.finish();
        s.workers.deinit(gpa);
    }

    pub fn invalidate(s: *State, gpa: std.mem.Allocator) void {
        s.generation +%= 1;
        if (s.text) |t| gpa.free(t);
        s.text = null;
        if (s.current) |w| w.cancel.store(true, .release);
        s.current = null;
    }

    /// Takes ownership of `text`.
    pub fn arrive(s: *State, gpa: std.mem.Allocator, generation: u64, text: []u8) void {
        if (generation != s.generation) return gpa.free(text);
        if (s.text) |old| gpa.free(old);
        s.text = text;
    }

    /// The ghost text, only while the editor holds nothing at all.
    pub fn visible(s: *const State, editor: *const Editor) []const u8 {
        if (editor.text().len != 0) return "";
        return s.text orelse "";
    }

    /// Tab: moves a visible prediction into the editor. False leaves Tab to its other uses.
    pub fn accept(s: *State, gpa: std.mem.Allocator, editor: *Editor) !bool {
        const text = s.visible(editor);
        if (text.len == 0) return false;
        try editor.insert(gpa, text);
        gpa.free(s.text.?);
        s.text = null;
        return true;
    }

    fn reap(s: *State) void {
        var i: usize = 0;
        while (i < s.workers.items.len) {
            if (s.workers.items[i].done.load(.acquire)) {
                s.workers.swapRemove(i).finish();
            } else i += 1;
        }
    }

    /// Starts a request for the next message; any failure to start is silent.
    pub fn start(s: *State, gpa: std.mem.Allocator, io: std.Io, loop: *vaxis.Loop(tui.Event), session_cfg: provider.Config, session_id: []const u8, user: []const u8, reply: []const u8) void {
        s.invalidate(gpa);
        s.reap();
        startWorker(s, gpa, io, loop, session_cfg, session_id, user, reply) catch {};
    }

    fn startWorker(s: *State, gpa: std.mem.Allocator, io: std.Io, loop: *vaxis.Loop(tui.Event), session_cfg: provider.Config, session_id: []const u8, user: []const u8, reply: []const u8) !void {
        var cfg = session_cfg;
        cfg.model = provider.smallModel(cfg.provider) orelse cfg.model;
        try cfg.setEffort("off");
        cfg.codex_transport = .sse;
        cfg.output_schema = null;
        try s.workers.ensureUnusedCapacity(gpa, 1);
        const w = try gpa.create(Worker);
        errdefer gpa.destroy(w);
        const key = try std.fmt.allocPrint(gpa, "{s}:predict", .{session_id});
        errdefer gpa.free(key);
        const input = try buildInput(gpa, user, reply);
        errdefer gpa.free(input);
        w.* = .{ .gpa = gpa, .io = io, .loop = loop, .cfg = cfg, .cache_key = key, .input = input, .generation = s.generation };
        w.thread = try std.Thread.spawn(.{}, Worker.run, .{w});
        s.workers.appendAssumeCapacity(w);
        s.current = w;
    }
};

const testing = std.testing;

test "input keeps the head of the user message and the tail of the reply on codepoint boundaries" {
    const a = testing.allocator;
    const user = try a.alloc(u8, 3000);
    defer a.free(user);
    @memset(user, '1');
    const reply = try a.alloc(u8, 9000);
    defer a.free(reply);
    @memset(reply, '2');
    @memcpy(reply[reply.len - 3 ..], "end");
    const text = try buildInput(a, user, reply);
    defer a.free(text);
    try testing.expectEqual(@as(usize, max_user_bytes), std.mem.count(u8, text, "1"));
    try testing.expectEqual(@as(usize, max_reply_bytes - 3), std.mem.count(u8, text, "2"));
    try testing.expect(std.mem.endsWith(u8, text, "2end"));

    const wide = try a.alloc(u8, 6000);
    defer a.free(wide);
    for (0..2000) |i| @memcpy(wide[i * 3 ..][0..3], "界");
    const cut = try buildInput(a, wide, wide);
    defer a.free(cut);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "filter keeps the first line without quotes and drops trivia" {
    const a = testing.allocator;
    const keep = [_][2][]const u8{
        .{ "  \"run the tests\"\nextra", "run the tests" },
        .{ "“修一下这个 bug”", "修一下这个 bug" },
        .{ "commit it", "commit it" },
    };
    for (keep) |pair| {
        const got = (try filter(a, pair[0])).?;
        defer a.free(got);
        try testing.expectEqualStrings(pair[1], got);
    }
    for ([_][]const u8{ "", "  \n ", "a", "\"\"", "ok", "Thanks!", "谢谢" }) |raw| {
        try testing.expect((try filter(a, raw)) == null);
    }
}

test "prediction shows only on an empty editor and survives typing and clearing" {
    const a = testing.allocator;
    var s: State = .{};
    defer s.deinit(a);
    var e: Editor = .{};
    defer e.deinit(a);
    try testing.expectEqualStrings("", s.visible(&e));
    s.arrive(a, s.generation, try a.dupe(u8, "run the tests"));
    try testing.expectEqualStrings("run the tests", s.visible(&e));
    try e.insert(a, "x");
    try testing.expectEqualStrings("", s.visible(&e));
    try e.replace(a, "");
    try testing.expectEqualStrings("run the tests", s.visible(&e));
}

test "late arrival while typing waits for an empty editor and old generations drop" {
    const a = testing.allocator;
    var s: State = .{};
    defer s.deinit(a);
    var e: Editor = .{};
    defer e.deinit(a);
    const generation = s.generation;
    try e.insert(a, "typing");
    s.arrive(a, generation, try a.dupe(u8, "late"));
    try testing.expectEqualStrings("", s.visible(&e));
    try e.replace(a, "");
    try testing.expectEqualStrings("late", s.visible(&e));
    s.invalidate(a);
    try testing.expectEqualStrings("", s.visible(&e));
    s.arrive(a, generation, try a.dupe(u8, "stale"));
    try testing.expectEqualStrings("", s.visible(&e));
    s.arrive(a, s.generation, try a.dupe(u8, "fresh"));
    try testing.expectEqualStrings("fresh", s.visible(&e));
}

test "Tab inserts a visible prediction and otherwise is left alone" {
    const a = testing.allocator;
    var s: State = .{};
    defer s.deinit(a);
    var e: Editor = .{};
    defer e.deinit(a);
    try testing.expect(!try s.accept(a, &e));
    s.arrive(a, s.generation, try a.dupe(u8, "commit it"));
    try e.insert(a, "x");
    try testing.expect(!try s.accept(a, &e));
    try testing.expectEqualStrings("x", e.text());
    try e.replace(a, "");
    try testing.expect(try s.accept(a, &e));
    try testing.expectEqualStrings("commit it", e.text());
    try e.replace(a, "");
    try testing.expectEqualStrings("", s.visible(&e));
}
