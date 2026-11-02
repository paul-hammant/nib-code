const std = @import("std");
const openai = @import("provider/openai.zig");

pub const Record = struct {
    cwd: ?[]const u8 = null,
    from: usize = 0,
    messages: []const openai.Message = &.{},
    context_tokens: u64 = 0,
    repair: bool = false,
};

pub const Log = struct {
    file: std.Io.File,
    offset: u64,
    poisoned: bool = false,

    pub fn create(io: std.Io, path: []const u8) !Log {
        return .{ .file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }), .offset = 0 };
    }

    pub fn restore(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, path: []const u8, history: *std.ArrayList(openai.Message), tokens: *u64) !Log {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true });
        errdefer file.close(io);
        var reader = file.reader(io, &.{});
        const data = try reader.interface.allocRemaining(a, .unlimited);
        const needs_repair = try replay(gpa, a, data, history, tokens);
        var log: Log = .{ .file = file, .offset = data.len };
        if (needs_repair) {
            try log.append(io, a, .{ .repair = true });
            try log.file.sync(io);
        }
        return log;
    }

    pub fn close(log: *Log, io: std.Io) void {
        log.file.close(io);
    }

    fn append(log: *Log, io: std.Io, a: std.mem.Allocator, record: Record) !void {
        if (log.poisoned) return error.SessionLogFailed;
        const bytes = try std.fmt.allocPrint(a, "{s}{f}\n", .{ if (record.repair) "\n" else "", std.json.fmt(record, .{ .emit_null_optional_fields = false }) });
        defer a.free(bytes);
        errdefer log.poisoned = true;
        try log.file.writePositionalAll(io, bytes, log.offset);
        log.offset += bytes.len;
    }

    pub fn commit(log: *Log, io: std.Io, a: std.mem.Allocator, history: *std.ArrayList(openai.Message), tokens: *u64, record: Record) !void {
        if (record.from > history.items.len) return error.InvalidSessionLog;
        try history.ensureTotalCapacity(a, record.from + record.messages.len);
        try log.append(io, a, record);
        apply(history, record);
        tokens.* = record.context_tokens;
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }
};

fn apply(history: *std.ArrayList(openai.Message), record: Record) void {
    history.shrinkRetainingCapacity(record.from);
    history.appendSliceAssumeCapacity(record.messages);
}

pub fn replay(gpa: std.mem.Allocator, a: std.mem.Allocator, data: []const u8, history: *std.ArrayList(openai.Message), tokens: *u64) !bool {
    var lines = std.mem.splitScalar(u8, data, '\n');
    var torn = false;
    while (lines.next()) |line| {
        if (lines.peek() == null) break;
        if (line.len == 0) continue;
        const r = std.json.parseFromSliceLeaky(Record, a, line, .{ .allocate = .alloc_always }) catch {
            torn = true;
            continue;
        };
        if (r.repair) {
            torn = false;
            continue;
        }
        if (torn or r.from > history.items.len) return error.InvalidSessionLog;
        try history.ensureTotalCapacity(gpa, r.from + r.messages.len);
        apply(history, r);
        try validate(history.items);
        tokens.* = r.context_tokens;
    }
    if (history.items.len == 0) return error.InvalidSessionLog;
    return torn or data[data.len - 1] != '\n';
}

fn validate(messages: []const openai.Message) !void {
    if (messages.len == 0 or !std.mem.eql(u8, messages[0].role, "system")) return error.InvalidSessionLog;
    var i: usize = 1;
    while (i < messages.len) : (i += 1) {
        const m = messages[i];
        if (std.mem.eql(u8, m.role, "user")) continue;
        if (!std.mem.eql(u8, m.role, "assistant")) return error.InvalidSessionLog;
        for (m.tool_calls orelse &.{}) |call| {
            i += 1;
            if (i >= messages.len or !std.mem.eql(u8, messages[i].role, "tool") or
                !std.mem.eql(u8, messages[i].tool_call_id orelse "", call.id)) return error.InvalidSessionLog;
        }
    }
}

pub fn latest(io: std.Io, a: std.mem.Allocator, directory: []const u8, cwd: []const u8) ![]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.NoSession,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    var best: ?[]const u8 = null;
    var newest: i96 = std.math.minInt(i96);
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const file = try dir.openFile(io, entry.name, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.mtime.nanoseconds < newest) continue;
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var header: std.Io.Writer.Allocating = .init(a);
        defer header.deinit();
        _ = reader.interface.streamDelimiter(&header.writer, '\n') catch |err| switch (err) {
            error.EndOfStream => continue,
            else => return err,
        };
        const r = std.json.parseFromSliceLeaky(Record, a, header.written(), .{ .allocate = .alloc_always }) catch continue;
        if (!std.mem.eql(u8, r.cwd orelse "", cwd)) continue;
        newest = stat.mtime.nanoseconds;
        best = try std.fs.path.join(a, &.{ directory, entry.name });
    }
    return best orelse error.NoSession;
}

test "commit and replay preserve safe history, compaction and torn tail" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/s.jsonl", .{tmp.sub_path});
    var log = try Log.create(t.io, path);
    var history: std.ArrayList(openai.Message) = .empty;
    const records = [_]Record{
        .{ .cwd = "/work", .messages = &.{.{ .role = "system", .content = "base" }} },
        .{ .from = 1, .messages = &.{ .{ .role = "user", .content = "hi" }, .{ .role = "assistant", .tool_calls = &.{.{ .id = "c", .function = .{ .name = "run", .arguments = "{}" } }} }, .{ .role = "tool", .content = "ok", .tool_call_id = "c" } }, .context_tokens = 100 },
        .{ .from = 1, .messages = &.{.{ .role = "user", .content = "summary" }}, .context_tokens = 10 },
    };
    var committed_tokens: u64 = 0;
    for (records) |r| {
        try log.commit(t.io, a, &history, &committed_tokens, r);
        const data = try tmp.dir.readFileAlloc(t.io, "s.jsonl", a, .unlimited);
        var restored: std.ArrayList(openai.Message) = .empty;
        var tokens: u64 = 0;
        _ = try replay(a, a, data, &restored, &tokens);
        try t.expectEqualDeep(history.items, restored.items);
        try t.expectEqual(r.context_tokens, tokens);
    }
    try log.file.writePositionalAll(t.io, "{\"from\":\n{\"repair\":", log.offset);
    log.close(t.io);
    var restored: std.ArrayList(openai.Message) = .empty;
    var tokens: u64 = 0;
    log = try Log.restore(t.io, a, a, path, &restored, &tokens);
    defer log.close(t.io);
    try t.expectEqualDeep(history.items, restored.items);
    try log.commit(t.io, a, &restored, &tokens, .{ .from = restored.items.len, .messages = &.{.{ .role = "assistant", .content = "next" }} });
    var again: std.ArrayList(openai.Message) = .empty;
    _ = try replay(a, a, try tmp.dir.readFileAlloc(t.io, "s.jsonl", a, .unlimited), &again, &tokens);
    try t.expectEqualDeep(restored.items, again.items);
}

test "replay rejects dangling tool calls and unrepaired interior corruption" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var history: std.ArrayList(openai.Message) = .empty;
    var tokens: u64 = 0;
    const header = "{\"messages\":[{\"role\":\"system\",\"content\":\"base\"}]}\n";
    const dangling = header ++ "{\"from\":1,\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"run\",\"arguments\":\"{}\"}}]}]}\n";
    try t.expectError(error.InvalidSessionLog, replay(a, a, dangling, &history, &tokens));
    history.clearRetainingCapacity();
    const corrupt = header ++ "broken\n{\"from\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}\n";
    try t.expectError(error.InvalidSessionLog, replay(a, a, corrupt, &history, &tokens));
}
