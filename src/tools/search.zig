const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const grep_engine = @import("grep.zig");
const walk = @import("walk.zig");

pub fn grep(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const a = std.json.parseFromSlice(grep_engine.Options, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ pattern: string, path?: string, glob?: string, ignore_case?: boolean, literal?: boolean, context?: number, limit?: number }}", .{});
    defer a.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var message: [128]u8 = undefined;
    var s = grep_engine.search(t.io, gpa, a.value, .{ .deny = try t.credentialPaths(arena.allocator()), .cancel = &t.cancel }, &message) catch |err| return switch (err) {
        error.InvalidPattern => fail(gpa, "invalid pattern: {s}", .{std.mem.sliceTo(&message, 0)}),
        error.Canceled => fail(gpa, "canceled", .{}),
        error.CredentialAccessDenied => err,
        else => fail(gpa, "{s}: {s}", .{ a.value.path, @errorName(err) }),
    };
    defer s.deinit();
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, s.result, .{ .emit_null_optional_fields = false }) };
}

pub fn glob(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const A = struct { pattern: []const u8, path: []const u8 = ".", limit: usize = 1000 };
    const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ pattern: string, path?: string, limit?: number }}", .{});
    defer a.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const pattern = if (std.mem.startsWith(u8, a.value.pattern, "./")) a.value.pattern[2..] else a.value.pattern;
    const found = walk.files(t.io, arena.allocator(), a.value.path, .{
        .deny = try t.credentialPaths(arena.allocator()),
        .cancel = &t.cancel,
        .filter = pattern,
        .max = a.value.limit,
    }) catch |err| return switch (err) {
        error.Canceled => fail(gpa, "canceled", .{}),
        error.CredentialAccessDenied => err,
        else => fail(gpa, "{s}: {s}", .{ a.value.path, @errorName(err) }),
    };
    const shown = found[0..@min(found.len, a.value.limit)];
    const paths = try arena.allocator().alloc([]const u8, shown.len);
    for (shown, paths) |f, *p| p.* = f.path;
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .paths = paths, .truncated = found.len > a.value.limit }, .{}) };
}

const testing = std.testing;
const callTool = tools.callTool;
const freeResult = tools.freeResult;

test "grep and glob never surface credential files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".codex");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".codex/auth.json", .data = "{\"token\":\"fake-secret\"}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.json", .data = "{\"token\":\"public\"}" });
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, root, testing.allocator);
    defer testing.allocator.free(home);
    var t: Tools = .{ .io = testing.io, .home = home };

    const grep_args = try std.fmt.allocPrint(testing.allocator, "{{\"pattern\":\"token\",\"path\":\"{s}\"}}", .{root});
    defer testing.allocator.free(grep_args);
    const found = Tools.call(&t, testing.allocator, "grep", grep_args);
    defer freeResult(found);
    try testing.expect(std.mem.indexOf(u8, found.ok, "public") != null);
    try testing.expect(std.mem.indexOf(u8, found.ok, "fake-secret") == null);

    const glob_args = try std.fmt.allocPrint(testing.allocator, "{{\"pattern\":\"*.json\",\"path\":\"{s}\"}}", .{root});
    defer testing.allocator.free(glob_args);
    const listed = Tools.call(&t, testing.allocator, "glob", glob_args);
    defer freeResult(listed);
    try testing.expect(std.mem.indexOf(u8, listed.ok, "notes.json") != null);
    try testing.expect(std.mem.indexOf(u8, listed.ok, "auth.json") == null);

    const direct_args = try std.fmt.allocPrint(testing.allocator, "{{\"pattern\":\"token\",\"path\":\"{s}/.codex/auth.json\"}}", .{root});
    defer testing.allocator.free(direct_args);
    const direct = Tools.call(&t, testing.allocator, "grep", direct_args);
    defer freeResult(direct);
    try testing.expectEqualStrings("CredentialAccessDenied", direct.err);
}
