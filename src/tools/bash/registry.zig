const std = @import("std");
const Tools = @import("../../tools.zig").Tools;

pub const Event = struct {
    id: []const u8,
    run: usize,
    state: enum { started, finished, superseded },
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    detached: ?bool = null,
    superseded_by: ?[]const u8 = null,
    elapsed_ms: ?u64 = null,
};

pub const Command = struct {
    next: ?*Command = null,
    id: []const u8,
    run: usize,
    command: []const u8,
    cwd: []const u8,
    detached: bool,
    revision: u64 = 0,
    started: std.Io.Clock.Timestamp,
    cancel: std.atomic.Value(bool) = .init(false),
    superseded_by: ?[]const u8 = null,
};

pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    revision: u64 = 0,
    head: ?*Command = null,

    pub fn changed(r: *Registry, io: std.Io) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.revision += 1;
    }

    pub fn start(r: *Registry, t: *Tools, gpa: std.mem.Allocator, command: *Command) !void {
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        try log(t, gpa, .{ .id = command.id, .run = command.run, .state = .started, .command = command.command, .cwd = command.cwd, .detached = command.detached });
        command.revision = r.revision;
        var cursor = r.head;
        while (cursor) |old| : (cursor = old.next) {
            if (!replaces(old, command)) continue;
            try log(t, gpa, .{ .id = old.id, .run = old.run, .state = .superseded, .superseded_by = command.id, .elapsed_ms = elapsed(old, t.io) });
            // Progress owns IDs until all Run and background workers have joined.
            old.superseded_by = command.id;
            old.cancel.store(true, .release);
        }
        command.next = r.head;
        r.head = command;
    }

    pub fn finish(r: *Registry, t: *Tools, gpa: std.mem.Allocator, command: *Command) ?[]const u8 {
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        var cursor = &r.head;
        while (cursor.*) |entry| {
            if (entry == command) {
                cursor.* = entry.next;
                break;
            }
            cursor = &entry.next;
        }
        log(t, gpa, .{ .id = command.id, .run = command.run, .state = .finished, .elapsed_ms = elapsed(command, t.io) }) catch {};
        return command.superseded_by;
    }
};

fn replaces(old: *const Command, new: *const Command) bool {
    return !old.detached and !new.detached and old.superseded_by == null and
        !old.cancel.load(.acquire) and old.run < new.run and old.revision < new.revision and
        std.mem.eql(u8, old.command, new.command) and std.mem.eql(u8, old.cwd, new.cwd);
}

fn elapsed(command: *const Command, io: std.Io) u64 {
    return @intCast(@max(command.started.untilNow(io).raw.toMilliseconds(), 0));
}

fn log(t: *Tools, gpa: std.mem.Allocator, event: Event) !void {
    if (t.background.log) |value| try value.bash(t.io, gpa, event);
}

test "replacement requires an earlier Run, changed revision, exact command and cwd, and neither detached" {
    const testing = std.testing;
    const base: Command = .{ .id = "b1", .run = 1, .command = "arbitrary check", .cwd = "/a", .detached = false, .started = .now(testing.io, .awake) };
    var old = base;
    var new = base;
    new.id = "b2";
    new.run = 2;
    new.revision = 1;
    try testing.expect(replaces(&old, &new));
    new.revision = 0;
    try testing.expect(!replaces(&old, &new));
    new.revision = 1;
    new.run = 1;
    try testing.expect(!replaces(&old, &new));
    new.run = 0;
    try testing.expect(!replaces(&old, &new));
    new.run = 2;
    new.cwd = "/b";
    try testing.expect(!replaces(&old, &new));
    new.cwd = "/a";
    new.command = "arbitrary check ";
    try testing.expect(!replaces(&old, &new));
    new.command = old.command;
    old.detached = true;
    try testing.expect(!replaces(&old, &new));
    old.detached = false;
    new.detached = true;
    try testing.expect(!replaces(&old, &new));
    new.detached = false;
    old.superseded_by = "b3";
    try testing.expect(!replaces(&old, &new));
    old.superseded_by = null;
    old.cancel.store(true, .release);
    try testing.expect(!replaces(&old, &new));
}

test "registry replaces every stale matching command once and removes joined commands" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/unused" };
    var commands: [4]Command = undefined;
    for (&commands, [_][]const u8{ "b1", "b2", "b3", "b4" }) |*command, id| {
        command.* = .{ .id = id, .run = 1, .command = "check", .cwd = "/a", .detached = false, .started = .now(testing.io, .awake) };
    }
    const r = &t.bash_commands;
    try r.start(&t, testing.allocator, &commands[0]);
    r.changed(testing.io);
    try r.start(&t, testing.allocator, &commands[1]);
    try testing.expect(!commands[0].cancel.load(.acquire));
    commands[2].run = 2;
    try r.start(&t, testing.allocator, &commands[2]);
    try testing.expect(commands[0].cancel.load(.acquire));
    try testing.expect(!commands[1].cancel.load(.acquire));
    r.changed(testing.io);
    commands[3].run = 3;
    try r.start(&t, testing.allocator, &commands[3]);
    try testing.expectEqualStrings("b3", r.finish(&t, testing.allocator, &commands[0]).?);
    try testing.expectEqualStrings("b4", r.finish(&t, testing.allocator, &commands[1]).?);
    try testing.expectEqualStrings("b4", r.finish(&t, testing.allocator, &commands[2]).?);
    try testing.expect(r.finish(&t, testing.allocator, &commands[3]) == null);
    try testing.expect(r.head == null);
}
