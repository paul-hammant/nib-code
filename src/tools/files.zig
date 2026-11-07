const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const atomic_file = @import("atomic_file.zig");
const file_state = @import("file_state.zig");
const undo = @import("undo.zig");

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
    const data = reader.interface.allocRemaining(gpa, .limited(undo.file_limit + 1)) catch |err|
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

fn writeBlocked(t: *Tools, gpa: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const why = (try t.checkWritable(arena.allocator(), path)) orelse return null;
    return why;
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
    if (try writeBlocked(t, gpa, path)) |why| return fail(gpa, "{s}: {s}", .{ v.path, why });
    const lock = try file_state.lock(t, gpa, path);
    defer lock.close(t.io);
    if (t.cancelFlag().load(.acquire)) return error.Canceled;
    if (v.old_text.len == 0) return fail(gpa, "old_text is empty; use write to create a file", .{});

    const dir = std.Io.Dir.cwd();
    const data = dir.readFileAlloc(t.io, path, gpa, .limited(undo.file_limit + 1)) catch |err|
        return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
    defer gpa.free(data);

    const count = std.mem.count(u8, data, v.old_text);
    if (count == 0) return fail(gpa, "old_text not found in {s}", .{v.path});
    if (count > 1 and !v.all)
        return fail(gpa, "old_text matches {d} times in {s}; include more surrounding text or pass all: true", .{ count, v.path });

    const out = try std.mem.replaceOwned(u8, gpa, data, v.old_text, v.new_text);
    defer gpa.free(out);
    var snapshot = undo.prepare(t, gpa, path, data, out);
    defer if (snapshot) |*s| s.deinit(t, gpa);
    const written = atomic_file.replace(t.io, gpa, path, out, .{}) catch |err|
        return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
    if (snapshot) |*s| s.commit(t, gpa, out);
    if (!std.mem.eql(u8, data, out)) try t.recovery.record(gpa, t.io, path);
    try t.file_state.remember(t.io, gpa, path, written);
    try t.noteChange(gpa, path, data, out);
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
    if (try writeBlocked(t, gpa, path)) |why| return fail(gpa, "{s}: {s}", .{ v.path, why });
    const lock = try file_state.lock(t, gpa, path);
    defer lock.close(t.io);
    if (t.cancelFlag().load(.acquire)) return error.Canceled;

    const dir = std.Io.Dir.cwd();
    const current = dir.statFile(t.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) }),
    };
    if (current) |stat| {
        if (t.file_state.changed(t.io, path, stat))
            return fail(gpa, "{s} changed since this session last read or wrote it (by bash, a background agent, or the user); read it again before overwriting", .{v.path});
    }
    var can_track = true;
    const before = dir.readFileAlloc(t.io, path, gpa, .limited(undo.file_limit + 1)) catch |err| before: {
        if (err != error.FileNotFound) can_track = false;
        break :before null;
    };
    defer if (before) |data| gpa.free(data);
    if (!can_track) undo.markIncomplete(t, gpa, .snapshot_unavailable);
    var snapshot = if (can_track) undo.prepare(t, gpa, path, before, v.content) else null;
    defer if (snapshot) |*s| s.deinit(t, gpa);
    if (std.fs.path.dirname(path)) |parent| dir.createDirPath(t.io, parent) catch |err|
        return fail(gpa, "{s}: {s}", .{ parent, @errorName(err) });
    const written = atomic_file.replace(t.io, gpa, path, v.content, .{}) catch |err|
        return fail(gpa, "{s}: {s}", .{ v.path, @errorName(err) });
    if (snapshot) |*s| s.commit(t, gpa, v.content);
    if (before == null or !std.mem.eql(u8, before.?, v.content)) try t.recovery.record(gpa, t.io, path);
    try t.file_state.remember(t.io, gpa, path, written);
    if (can_track) try t.noteChange(gpa, path, before, v.content) else t.bash_commands.changed(t.io);
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

test "edit and write refuse paths outside the writable roots as data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "inside.txt", .data = "old" });
    try tmp.dir.symLink(testing.io, "/usr/share", "escape", .{});
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    var t: Tools = .{ .io = testing.io, .home = root, .cfg = .{ .base_url = "", .api_key = "", .model = "m" } };
    defer t.file_state.deinit(testing.allocator);
    const outside = [_][]const u8{ "/usr/share/nib-sandbox-test", "escape/nib-sandbox-test", "../../../../../../../usr/share/nib-sandbox-test" };
    for (outside) |relative| {
        const path = if (std.mem.startsWith(u8, relative, "escape")) try std.fs.path.join(testing.allocator, &.{ root, relative }) else try testing.allocator.dupe(u8, relative);
        defer testing.allocator.free(path);
        const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = path, .old_text = "a", .new_text = "b", .content = "x" }, .{});
        defer testing.allocator.free(args);
        for ([_][]const u8{ "edit", "write" }) |name| {
            const result = Tools.call(&t, testing.allocator, name, args);
            defer freeResult(result);
            try testing.expect(std.mem.indexOf(u8, result.err, "sandbox only allows writes inside the project") != null);
        }
    }
    const inside = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}/inside.txt\",\"old_text\":\"old\",\"new_text\":\"new\"}}", .{root});
    defer testing.allocator.free(inside);
    const ok = Tools.call(&t, testing.allocator, "edit", inside);
    defer freeResult(ok);
    try testing.expectEqualStrings("{\"replaced\":1}", ok.ok);
    t.cfg.?.sandbox.mode = .off;
    const off = Tools.call(&t, testing.allocator, "write", "{\"path\":\"/nonexistent-nib-dir/x\",\"content\":\"x\"}");
    defer freeResult(off);
    try testing.expect(std.mem.indexOf(u8, off.err, "sandbox") == null);
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

fn trackedCall(t: *Tools, name: []const u8, args: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, args, .{});
    defer testing.allocator.free(json);
    const result = Tools.call(t, testing.allocator, name, json);
    defer freeResult(result);
    try testing.expect(result == .ok);
}

test "change tracking excludes other writers between and after calls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/f", .{tmp.sub_path});
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "base\nother\nlast\n" });
    const home = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(home);
    var root: Tools = .{ .io = testing.io, .home = home, .track_changes = true };
    defer root.discardChanges(testing.allocator);
    defer root.file_state.deinit(testing.allocator);
    var child: Tools = .{ .io = testing.io, .home = home, .track_changes = true };
    defer child.discardChanges(testing.allocator);
    defer child.file_state.deinit(testing.allocator);
    try trackedCall(&root, "edit", .{ .path = path, .old_text = "base", .new_text = "root" });
    try trackedCall(&child, "edit", .{ .path = path, .old_text = "other", .new_text = "child" });
    try trackedCall(&root, "read", .{ .path = path });
    try trackedCall(&root, "write", .{ .path = path, .content = "root2\nchild\nlast\n" });
    try trackedCall(&child, "read", .{ .path = path });
    try trackedCall(&child, "write", .{ .path = path, .content = "root2\nchild\ntail\n" });
    try tmp.dir.deleteFile(testing.io, "f");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const changes = try root.takeChanges(testing.allocator, arena.allocator());
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings(path, changes[0].path);
    try testing.expectEqual(@as(usize, 2), changes[0].added);
    try testing.expectEqual(@as(usize, 2), changes[0].removed);
    try testing.expect(!changes[0].created);
    try testing.expectEqualStrings("-base\n+root\n other\n…\n-root\n+root2\n child\n", changes[0].diff);
    const child_changes = try child.takeChanges(testing.allocator, arena.allocator());
    try testing.expectEqual(@as(usize, 1), child_changes.len);
    try testing.expectEqual(@as(usize, 2), child_changes[0].added);
    try testing.expectEqual(@as(usize, 2), child_changes[0].removed);
    try testing.expect(std.mem.indexOf(u8, child_changes[0].diff, "+root") == null);
    try testing.expect(std.mem.indexOf(u8, child_changes[0].diff, "-base") == null);
    try testing.expectEqual(@as(usize, 0), (try root.takeChanges(testing.allocator, arena.allocator())).len);
}

test "change tracking omits no-ops and failed calls but reports empty creation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/f", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const home = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(home);
    var t: Tools = .{ .io = testing.io, .home = home, .track_changes = true };
    defer t.discardChanges(testing.allocator);
    defer t.file_state.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try trackedCall(&t, "write", .{ .path = path, .content = "" });
    try testing.expectEqual(@as(u64, 1), t.bash_commands.revision);
    const created = try t.takeChanges(testing.allocator, arena.allocator());
    try testing.expectEqual(@as(usize, 1), created.len);
    try testing.expect(created[0].created);
    try testing.expectEqual(@as(usize, 0), created[0].added);
    try testing.expectEqualStrings("", created[0].diff);
    try trackedCall(&t, "write", .{ .path = path, .content = "" });
    try testing.expectEqual(@as(u64, 1), t.bash_commands.revision);
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = path, .old_text = "missing", .new_text = "new" }, .{});
    defer testing.allocator.free(args);
    const result = Tools.call(&t, testing.allocator, "edit", args);
    defer freeResult(result);
    try testing.expect(result == .err);
    try testing.expectEqual(@as(u64, 1), t.bash_commands.revision);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "external\n" });
    try testing.expectEqual(@as(usize, 0), (try t.takeChanges(testing.allocator, arena.allocator())).len);
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
