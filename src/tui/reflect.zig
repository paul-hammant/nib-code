const std = @import("std");

/// Edit the wording in reflect.md; `{{session_id}}`, `{{log_path}}` and `{{focus}}` are filled in here.
const template = @embedFile("reflect.md");

/// The reflection request sent to the model as the user message. Caller owns it.
pub fn prompt(gpa: std.mem.Allocator, session_id: []const u8, log_path: []const u8, focus: []const u8) ![]u8 {
    const focus_text = if (focus.len == 0) try gpa.dupe(u8, "") else try std.fmt.allocPrint(gpa, "\n用户特别想了解：{s}", .{focus});
    defer gpa.free(focus_text);
    const with_id = try std.mem.replaceOwned(u8, gpa, template, "{{session_id}}", session_id);
    defer gpa.free(with_id);
    const with_log = try std.mem.replaceOwned(u8, gpa, with_id, "{{log_path}}", log_path);
    defer gpa.free(with_log);
    return std.mem.replaceOwned(u8, gpa, with_log, "{{focus}}", focus_text);
}

pub const Entry = struct {
    unix_seconds: i64,
    session_id: []const u8,
    cwd: []const u8,
    model: []const u8,
    effort: []const u8,
    focus: []const u8 = "",
    answer: []const u8,
};

/// Appends one reflection to `path` (created if missing), under an exclusive lock
/// because several nib processes share one file.
pub fn append(io: std.Io, gpa: std.mem.Allocator, path: []const u8, e: Entry) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const day = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(e.unix_seconds, 0)) };
    const date = day.getEpochDay().calculateYearDay();
    const month_day = date.calculateMonthDay();
    const clock = day.getDaySeconds();
    try text.print(gpa, "## {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC · session {s} · {s} · {s} · effort {s}\n", .{
        date.year,                  month_day.month.numeric(), month_day.day_index + 1,
        clock.getHoursIntoDay(),    clock.getMinutesIntoHour(), e.session_id[0..@min(8, e.session_id.len)],
        e.cwd,                      e.model,                   e.effort,
    });
    if (e.focus.len > 0) try text.print(gpa, "focus: {s}\n", .{e.focus});
    try text.print(gpa, "\n{s}\n\n", .{std.mem.trim(u8, e.answer, "\n")});

    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive });
    defer file.close(io);
    try file.writePositionalAll(io, text.items, try file.length(io));
}

const testing = std.testing;

test "prompt fills the session, log path and optional focus" {
    const plain = try prompt(testing.allocator, "abc123", "/h/.nib/sessions/abc123.jsonl", "");
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "本会话日志是 /h/.nib/sessions/abc123.jsonl") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "parent_session_id 是 abc123") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "{{") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "用户特别想了解") == null);

    const focused = try prompt(testing.allocator, "abc123", "/l", "子 agent");
    defer testing.allocator.free(focused);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, focused, "\n"), "用户特别想了解：子 agent"));
}

test "append creates the file, then adds entries after earlier ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/nib/reflections.md", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const base: Entry = .{ .unix_seconds = 1_793_600_000, .session_id = "0123456789abcdef", .cwd = "/p", .model = "m", .effort = "high", .answer = "\n### 摘要\n一切正常\n" };
    try append(testing.io, testing.allocator, path, base);
    var second = base;
    second.focus = "超时";
    second.answer = "第二次";
    try append(testing.io, testing.allocator, path, second);
    const data = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(4096));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(
        \\## 2026-11-02 06:13 UTC · session 01234567 · /p · m · effort high
        \\
        \\### 摘要
        \\一切正常
        \\
        \\## 2026-11-02 06:13 UTC · session 01234567 · /p · m · effort high
        \\focus: 超时
        \\
        \\第二次
        \\
        \\
    , data);
}
