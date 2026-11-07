//! `nib login [service]` and `nib logout <service>`: terminal prompts, no TUI.

const std = @import("std");
const auth = @import("../auth.zig");
const config = @import("../config.zig");
const flow = @import("../tui/provider_flow.zig");

const Writer = std.Io.Writer;

pub const usage_login = "Usage: nib login [service] [--device]";

fn readLine(reader: *std.Io.Reader, a: std.mem.Allocator) !?[]const u8 {
    const line = reader.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidInput,
        else => return err,
    } orelse return null;
    return try a.dupe(u8, std.mem.trim(u8, line, " \t\r\n"));
}

/// Reads one line with echo off when stdin is a terminal.
fn readSecret(io: std.Io, reader: *std.Io.Reader, a: std.mem.Allocator, stdout: *Writer) !?[]const u8 {
    const stdin = std.Io.File.stdin();
    const interactive = try stdin.isTty(io);
    var saved: ?std.posix.termios = null;
    if (interactive) if (std.posix.tcgetattr(stdin.handle)) |t| {
        saved = t;
        var quiet = t;
        quiet.lflag.ECHO = false;
        std.posix.tcsetattr(stdin.handle, .NOW, quiet) catch {};
    } else |_| {};
    defer if (saved) |t| {
        std.posix.tcsetattr(stdin.handle, .NOW, t) catch {};
        stdout.writeAll("\n") catch {};
    };
    return readLine(reader, a);
}

const Device = struct {
    out: *Writer,
    fn show(ctx: *anyopaque, url: []const u8, code: []const u8) void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        self.out.print("Open {s}\nEnter code {s}\n", .{ url, code }) catch {};
        self.out.flush() catch {};
    }
};

var never: std.atomic.Value(bool) = .init(false);

pub fn login(init: std.process.Init, args: []const []const u8, stdout: *Writer) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const home = try config.home(a, init.environ_map);
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &input_buffer);
    var device_only = false;
    var wanted: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--device")) device_only = true else if (arg.len > 0 and arg[0] == '-') return error.InvalidArguments else if (wanted == null) wanted = arg else return error.InvalidArguments;
    }
    const list = try auth.services(a, io, init.environ_map, home);
    if (wanted == null) {
        for (list, 1..) |svc, i| try stdout.print("{d}  {s: <12} {s}\n", .{ i, svc.name, svc.status });
        try stdout.writeAll("Service (name or number): ");
        try stdout.flush();
        const answer = (try readLine(&input.interface, a)) orelse return error.InvalidArguments;
        wanted = answer;
        if (std.fmt.parseInt(usize, answer, 10)) |n| {
            if (n >= 1 and n <= list.len) wanted = list[n - 1].id;
        } else |_| {}
    }
    const svc = auth.find(list, wanted.?) orelse blk: {
        for (list) |item| if (std.ascii.eqlIgnoreCase(item.name, wanted.?)) break :blk item;
        return error.UnknownService;
    };
    if (std.mem.eql(u8, svc.id, "codex")) {
        var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
        defer client.deinit();
        try client.initDefaultProxies(a, init.environ_map);
        try stdout.writeAll("Waiting for ChatGPT sign-in · Ctrl+C cancels\n");
        try stdout.flush();
        var device: Device = .{ .out = stdout };
        const result = try auth.login.run(a, .{
            .io = io,
            .client = &client,
            .environ = init.environ_map,
            .nib_home = home,
            .cancel = &never,
            .prompt = .{ .ctx = &device, .device = Device.show },
            .device_only = device_only,
        });
        var buf: [64]u8 = undefined;
        try stdout.print("Codex · signed in · {s}\n", .{auth.oauth.planLabel(&buf, result.plan)});
        return stdout.flush();
    }
    try stdout.print("{s} API key: ", .{svc.name});
    try stdout.flush();
    const key = (try readSecret(io, &input.interface, a, stdout)) orelse return error.InvalidArguments;
    defer std.crypto.secureZero(u8, @constCast(key));
    if (key.len == 0) return error.EmptyKey;
    try auth.setKey(a, io, home, svc.id, key);
    try stdout.print("{s} · key stored\n", .{svc.name});
    try stdout.flush();
}

pub fn logout(init: std.process.Init, args: []const []const u8, stdout: *Writer) !void {
    const a = init.arena.allocator();
    if (args.len != 1) return error.InvalidArguments;
    const home = try config.home(a, init.environ_map);
    const list = try auth.services(a, init.io, init.environ_map, home);
    const svc = auth.find(list, args[0]) orelse return error.UnknownService;
    const out = try auth.signOut(a, init.io, init.environ_map, home, svc.id);
    try stdout.print("{s}\n", .{try auth.signOutText(a, svc.name, out)});
    try stdout.flush();
}

test "flow is linked" {
    _ = flow;
}
