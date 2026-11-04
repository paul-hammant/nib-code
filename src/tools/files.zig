const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const atomic_file = @import("atomic_file.zig");
const file_state = @import("file_state.zig");

pub fn read(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const A = struct { path: []const u8, offset: usize = 1, limit: usize = 2000 };
    const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ path: string, offset?: number, limit?: number }}", .{});
    defer a.deinit();

    const path = try tools.normalizedPath(t.io, gpa, a.value.path);
    defer gpa.free(path);
    try t.checkCredentialPath(gpa, path);
    const lock = try file_state.lock(t, gpa, path);
    defer lock.close(t.io);
    const file = std.Io.Dir.cwd().openFile(t.io, path, .{}) catch |err|
        return fail(gpa, "{s}: {s}", .{ a.value.path, @errorName(err) });
    defer file.close(t.io);
    const stat = try file.stat(t.io);
    var reader = file.reader(t.io, &.{});
    const data = reader.interface.allocRemaining(gpa, .limited(16 * 1024 * 1024)) catch |err|
        return fail(gpa, "{s}: {s}", .{ a.value.path, @errorName(err) });
    defer gpa.free(data);

    var start: usize = 0;
    var line: usize = 1;
    while (line < a.value.offset and start < data.len) : (line += 1) {
        start = if (std.mem.indexOfScalarPos(u8, data, start, '\n')) |nl| nl + 1 else data.len;
    }
    var end = start;
    var n: usize = 0;
    while (n < a.value.limit and end < data.len) : (n += 1) {
        end = if (std.mem.indexOfScalarPos(u8, data, end, '\n')) |nl| nl + 1 else data.len;
    }
    const next_offset: ?usize = if (end < data.len) line + n else null;
    const result = try std.json.Stringify.valueAlloc(gpa, .{ .text = data[start..end], .next_offset = next_offset }, .{});
    errdefer gpa.free(result);
    try t.file_state.remember(t.io, gpa, path, stat);
    return .{ .ok = result };
}

pub fn edit(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const A = struct { path: []const u8, old_text: []const u8, new_text: []const u8, all: bool = false };
    const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ path: string, old_text: string, new_text: string, all?: boolean }}", .{});
    defer a.deinit();
    const v = a.value;
    const path = try tools.normalizedPath(t.io, gpa, v.path);
    defer gpa.free(path);
    try t.checkCredentialPath(gpa, path);
    const lock = try file_state.lock(t, gpa, path);
    defer lock.close(t.io);
    if (t.cancel.load(.acquire)) return error.Canceled;
    if (v.old_text.len == 0) return fail(gpa, "old_text is empty; use write to create a file", .{});

    const dir = std.Io.Dir.cwd();
    const data = dir.readFileAlloc(t.io, path, gpa, .limited(16 * 1024 * 1024)) catch |err|
        return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
    defer gpa.free(data);

    const count = std.mem.count(u8, data, v.old_text);
    if (count == 0) return fail(gpa, "old_text not found in {s}", .{v.path});
    if (count > 1 and !v.all)
        return fail(gpa, "old_text matches {d} times in {s}; include more surrounding text or pass all: true", .{ count, v.path });

    const out = try std.mem.replaceOwned(u8, gpa, data, v.old_text, v.new_text);
    defer gpa.free(out);
    try t.noteBefore(gpa, path, data);
    const written = atomic_file.replace(t.io, gpa, path, out, .{}) catch |err|
        return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
    try t.file_state.remember(t.io, gpa, path, written);
    return .{ .ok = try std.fmt.allocPrint(gpa, "{{\"replaced\":{d}}}", .{count}) };
}

pub fn write(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const A = struct { path: []const u8, content: []const u8 };
    const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ path: string, content: string }}", .{});
    defer a.deinit();
    const v = a.value;
    const path = try tools.normalizedPath(t.io, gpa, v.path);
    defer gpa.free(path);
    try t.checkCredentialPath(gpa, path);
    const lock = try file_state.lock(t, gpa, path);
    defer lock.close(t.io);
    if (t.cancel.load(.acquire)) return error.Canceled;

    const dir = std.Io.Dir.cwd();
    const current = dir.statFile(t.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) }),
    };
    if (current) |stat| {
        if (t.file_state.changed(t.io, path, stat))
            return fail(gpa, "{s} changed since this session last read or wrote it (by bash, a background agent, or the user); read it again before overwriting", .{v.path});
    }
    if (t.track_changes) track: {
        const before = dir.readFileAlloc(t.io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) try t.noteBefore(gpa, path, null);
            break :track;
        };
        defer gpa.free(before);
        try t.noteBefore(gpa, path, before);
    }
    if (std.fs.path.dirname(path)) |parent| dir.createDirPath(t.io, parent) catch |err|
        return fail(gpa, "{s}: {s}", .{ parent, @errorName(err) });
    const written = atomic_file.replace(t.io, gpa, path, v.content, .{}) catch |err|
        return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
    try t.file_state.remember(t.io, gpa, path, written);
    return .{ .ok = try std.fmt.allocPrint(gpa, "{{\"bytes\":{d}}}", .{v.content.len}) };
}

const testing = std.testing;
const callTool = tools.callTool;
const freeResult = tools.freeResult;

test "write then edit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/a/b.txt", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const args = struct {
        fn f(comptime fmt: []const u8, a: anytype) ![]u8 {
            return std.fmt.allocPrint(testing.allocator, fmt, a);
        }
    }.f;

    const w = try args("{{\"path\":\"{s}\",\"content\":\"one two two\\n\"}}", .{path});
    defer testing.allocator.free(w);
    const wr = try callTool("write", w);
    defer freeResult(wr);
    try testing.expectEqualStrings("{\"bytes\":12}", wr.ok);

    const ambiguous = try args("{{\"path\":\"{s}\",\"old_text\":\"two\",\"new_text\":\"2\"}}", .{path});
    defer testing.allocator.free(ambiguous);
    const amb = try callTool("edit", ambiguous);
    defer freeResult(amb);
    try testing.expect(std.mem.startsWith(u8, amb.err, "old_text matches 2 times"));

    const all_args = try args("{{\"path\":\"{s}\",\"old_text\":\"two\",\"new_text\":\"2\",\"all\":true}}", .{path});
    defer testing.allocator.free(all_args);
    const ar = try callTool("edit", all_args);
    defer freeResult(ar);
    try testing.expectEqualStrings("{\"replaced\":2}", ar.ok);

    const missing = try args("{{\"path\":\"{s}\",\"old_text\":\"zzz\",\"new_text\":\"\"}}", .{path});
    defer testing.allocator.free(missing);
    const mr = try callTool("edit", missing);
    defer freeResult(mr);
    try testing.expect(std.mem.startsWith(u8, mr.err, "old_text not found"));

    const content = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("one 2 2\n", content);
}

test "read slices lines and reports errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "a\nb\nc\nd\n" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/f.txt", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const args = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}\",\"offset\":2,\"limit\":2}}", .{path});
    defer testing.allocator.free(args);

    const r = try callTool("read", args);
    defer freeResult(r);
    try testing.expectEqualStrings("{\"text\":\"b\\nc\\n\",\"next_offset\":4}", r.ok);

    const missing = try callTool("read", "{\"path\":\"/nonexistent/x\"}");
    defer freeResult(missing);
    try testing.expect(std.mem.endsWith(u8, missing.err, "FileNotFound"));

    const bad = try callTool("read", "{}");
    defer freeResult(bad);
    try testing.expect(std.mem.startsWith(u8, bad.err, "expected"));
}

test "parallel edits lock the normalized path through read and write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "abcdefghijklmnop" });
    const code = try std.fmt.allocPrint(testing.allocator,
        \\await Promise.all(Array.from('abcdefghijklmnop', (letter, i) => tools.edit({{
        \\ path: '.zig-cache/tmp/{s}/' + (i % 2 ? './f' : 'f'), old_text: letter, new_text: letter.toUpperCase()
        \\}})))
    , .{tmp.sub_path});
    defer testing.allocator.free(code);
    const home = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(home);
    var t: Tools = .{ .io = testing.io, .home = home };
    defer t.file_state.deinit(testing.allocator);
    const result = try sandbox.eval(testing.allocator, testing.io, code, .{}, t.host(), null);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    const data = try tmp.dir.readFileAlloc(testing.io, "f", testing.allocator, .limited(100));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", data);
}

test "credential file tools deny default custom and symlink paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".codex");
    try tmp.dir.createDirPath(testing.io, "custom");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".codex/auth.json", .data = "fictional-default" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "custom/auth.json", .data = "fictional-custom" });
    try tmp.dir.symLink(testing.io, "custom/auth.json", "alias", .{});
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const custom = try std.fs.path.join(testing.allocator, &.{ root, "custom" });
    defer testing.allocator.free(custom);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("CODEX_HOME", custom);
    var t: Tools = .{ .io = testing.io, .home = root, .environ = &env };
    for ([_][]const u8{ ".codex/auth.json", "custom/auth.json", "alias" }) |relative| {
        const path = try std.fs.path.join(testing.allocator, &.{ root, relative });
        defer testing.allocator.free(path);
        const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = path, .old_text = "fictional", .new_text = "changed", .content = "changed" }, .{});
        defer testing.allocator.free(args);
        for ([_][]const u8{ "read", "edit", "write" }) |name| {
            const result = Tools.call(&t, testing.allocator, name, args);
            defer freeResult(result);
            try testing.expectEqualStrings("CredentialAccessDenied", result.err);
        }
    }
    const data = try tmp.dir.readFileAlloc(testing.io, "custom/auth.json", testing.allocator, .limited(100));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("fictional-custom", data);
}

test "read and write round trip more than 16 KiB inside JS" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    for (0..3000) |_| try bytes.appendSlice(testing.allocator, "中文\t\"\\0123456789");
    try bytes.appendSlice(testing.allocator, "\r\nlast line without newline");
    const content = bytes.items;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = content });
    const code = try std.fmt.allocPrint(testing.allocator,
        \\const path = '.zig-cache/tmp/{s}/f';
        \\const page = await tools.read({{path}});
        \\if (page.next_offset !== null) throw new Error('unexpected page');
        \\await tools.write({{path, content: page.text}});
    , .{tmp.sub_path});
    defer testing.allocator.free(code);
    const home = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(home);
    var t: Tools = .{ .io = testing.io, .home = home };
    defer t.file_state.deinit(testing.allocator);
    const result = try sandbox.eval(testing.allocator, testing.io, code, .{}, t.host(), null);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    const actual = try tmp.dir.readFileAlloc(testing.io, "f", testing.allocator, .limited(content.len + 1));
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(content, actual);
}

test "read default pagination reconstructs every byte in JS" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    for (0..1100) |_| try bytes.appendSlice(testing.allocator, "中文\r\n\nthird\nfourth\n");
    try bytes.appendSlice(testing.allocator, "last without newline");
    const content = bytes.items;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = content });
    const code = try std.fmt.allocPrint(testing.allocator,
        \\const path = '.zig-cache/tmp/{s}/f';
        \\let offset = 1, text = '', pages = 0;
        \\do {{
        \\  const page = await tools.read({{path, offset}});
        \\  text += page.text;
        \\  offset = page.next_offset;
        \\  if (++pages > 3) throw new Error('pagination did not finish');
        \\  if (pages < 3 && offset !== 1 + pages * 2000) throw new Error('wrong offset');
        \\}} while (offset !== null);
        \\if (pages !== 3) throw new Error('wrong default limit');
        \\await tools.write({{path, content: text}});
    , .{tmp.sub_path});
    defer testing.allocator.free(code);
    const home = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(home);
    var t: Tools = .{ .io = testing.io, .home = home };
    defer t.file_state.deinit(testing.allocator);
    const result = try sandbox.eval(testing.allocator, testing.io, code, .{}, t.host(), null);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    const actual = try tmp.dir.readFileAlloc(testing.io, "f", testing.allocator, .limited(content.len + 1));
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(content, actual);
}

test "read pagination boundaries do not add text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/f", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const Case = struct { data: []const u8, offset: usize = 1, limit: usize = 2000, text: []const u8, next_offset: ?usize = null };
    for ([_]Case{
        .{ .data = "", .text = "" },
        .{ .data = "a\n", .limit = 1, .text = "a\n" },
        .{ .data = "a\nb", .limit = 1, .text = "a\n", .next_offset = 2 },
        .{ .data = "a\nb", .offset = 2, .limit = 1, .text = "b" },
        .{ .data = "a\n", .offset = 2, .text = "" },
        .{ .data = "a\n", .offset = 100, .text = "" },
        .{ .data = "a", .limit = 0, .text = "", .next_offset = 1 },
    }) |c| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = c.data });
        const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = path, .offset = c.offset, .limit = c.limit }, .{});
        defer testing.allocator.free(args);
        const result = try callTool("read", args);
        defer freeResult(result);
        const expected = try std.json.Stringify.valueAlloc(testing.allocator, .{ .text = c.text, .next_offset = c.next_offset }, .{});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, result.ok);
    }
}

const FileTest = struct {
    tmp: testing.TmpDir,
    home: []u8,
    path: []u8,
    host: Tools,

    fn init() !FileTest {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer testing.allocator.free(home);
        const path = try std.fs.path.join(testing.allocator, &.{ home, "f" });
        return .{ .tmp = tmp, .home = home, .path = path, .host = .{ .io = testing.io, .home = home } };
    }

    fn deinit(f: *FileTest) void {
        f.host.file_state.deinit(testing.allocator);
        testing.allocator.free(f.path);
        testing.allocator.free(f.home);
        f.tmp.cleanup();
    }

    fn call(f: *FileTest, name: []const u8, value: anytype) !sandbox.ToolResult {
        const args = try std.json.Stringify.valueAlloc(testing.allocator, value, .{});
        defer testing.allocator.free(args);
        return Tools.call(&f.host, testing.allocator, name, args);
    }

    fn ok(f: *FileTest, name: []const u8, value: anytype) !void {
        const result = try f.call(name, value);
        defer freeResult(result);
        if (result == .err) std.debug.print("tool failed: {s}\n", .{result.err});
        try testing.expect(result == .ok);
    }

    fn content(f: *FileTest, expected: []const u8) !void {
        const actual = try f.tmp.dir.readFileAlloc(testing.io, "f", testing.allocator, .limited(1024));
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }
};

test "write rejects external changes after paginated read and reread permits overwrite" {
    var f = try FileTest.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "one\ntwo\n" });
    try f.ok("read", .{ .path = f.path, .offset = 2, .limit = 1 });
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "external change" });
    const rejected = try f.call("write", .{ .path = f.path, .content = "stale" });
    defer freeResult(rejected);
    try testing.expect(rejected == .err);
    try testing.expect(std.mem.indexOf(u8, rejected.err, f.path) != null);
    try testing.expect(std.mem.indexOf(u8, rejected.err, "read it again before overwriting") != null);
    try f.content("external change");
    try f.ok("read", .{ .path = f.path });
    try f.ok("write", .{ .path = f.path, .content = "fresh" });
    try f.content("fresh");
}

test "write allows unseen existing files and remembers successful writes" {
    var f = try FileTest.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "unseen" });
    try f.ok("write", .{ .path = f.path, .content = "first" });
    try f.ok("write", .{ .path = f.path, .content = "second" });
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "external longer" });
    const rejected = try f.call("write", .{ .path = f.path, .content = "third" });
    defer freeResult(rejected);
    try testing.expect(rejected == .err);
    try f.content("external longer");
}

test "edit ignores stale state and updates the session observation" {
    var f = try FileTest.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "old" });
    try f.ok("read", .{ .path = f.path });
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "external" });
    try f.ok("edit", .{ .path = f.path, .old_text = "external", .new_text = "edited" });
    try f.ok("write", .{ .path = f.path, .content = "after edit" });
    try f.content("after edit");
}

test "file observations are independent per session and follow aliases" {
    var f = try FileTest.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "old" });
    try f.tmp.dir.symLink(testing.io, "f", "alias", .{});
    const alias = try std.fs.path.join(testing.allocator, &.{ f.home, "alias" });
    defer testing.allocator.free(alias);
    try f.ok("read", .{ .path = alias });
    var other: Tools = .{ .io = testing.io, .home = f.home };
    defer other.file_state.deinit(testing.allocator);
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = f.path, .content = "other session" }, .{});
    defer testing.allocator.free(args);
    const changed = Tools.call(&other, testing.allocator, "write", args);
    defer freeResult(changed);
    try testing.expect(changed == .ok);
    const rejected = try f.call("write", .{ .path = f.path, .content = "stale" });
    defer freeResult(rejected);
    try testing.expect(rejected == .err);
    try f.content("other session");
}
