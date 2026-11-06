const std = @import("std");
const commands = @import("commands.zig");
const Session = @import("../session.zig").Session;
const session_log = @import("../session/log.zig");

/// The `/` candidate list above the input: selection, dismissal and session choices.
pub const Menu = struct {
    /// `items` returns slices of this; a Menu must not move while they are used.
    buf: [16]commands.Candidate = undefined,
    sel: usize = 0,
    closed: bool = false,
    /// Owns `sessions` and resolved ids; reset when sessions are listed again.
    arena: std.heap.ArenaAllocator,
    sessions: []const commands.Choice = &.{},
    sessions_loaded: bool = false,
    tasks: []const commands.Choice = &.{},

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(m: *Menu) void {
        m.arena.deinit();
    }

    pub fn items(m: *Menu, input: []const u8) []commands.Candidate {
        if (m.closed) return m.buf[0..0];
        return commands.candidates(input, m.sessions, m.tasks, &m.buf);
    }

    pub fn selected(m: *Menu, input: []const u8) ?commands.Candidate {
        const list = m.items(input);
        return if (list.len > 0) list[@min(m.sel, list.len - 1)] else null;
    }

    pub fn move(m: *Menu, input: []const u8, down: bool) void {
        const len = m.items(input).len;
        if (len == 0) return;
        const current = @min(m.sel, len - 1);
        m.sel = if (down) (current + 1) % len else (current + len - 1) % len;
    }

    pub fn inputChanged(m: *Menu, input: []const u8) void {
        m.sel = 0;
        m.closed = false;
        if (!std.mem.startsWith(u8, input, "/resume ")) m.sessions_loaded = false;
    }

    pub fn forgetSessions(m: *Menu) void {
        m.sessions_loaded = false;
    }

    /// Lists this directory's sessions once the input starts asking for one.
    pub fn load(m: *Menu, io: std.Io, input: []const u8, session: *const Session) !void {
        if (std.mem.startsWith(u8, input, "/stop ")) {
            _ = m.arena.reset(.retain_capacity);
            const a = m.arena.allocator();
            const tasks = try @constCast(&session.tools.background).snapshot(a, io);
            var choices: std.ArrayList(commands.Choice) = .empty;
            for (tasks) |task| {
                if (!std.mem.eql(u8, task.state, "queued") and !std.mem.eql(u8, task.state, "working")) continue;
                try choices.append(a, .{ .value = task.id, .label = task.id, .detail = task.description });
            }
            m.tasks = try choices.toOwnedSlice(a);
            return;
        }
        if (m.sessions_loaded or !std.mem.startsWith(u8, input, "/resume ")) return;
        _ = m.arena.reset(.retain_capacity);
        m.sessions = try sessionChoices(io, m.arena.allocator(), session);
        m.sessions_loaded = true;
    }

    /// A full id, or the one session here whose id starts with `arg`.
    pub fn resolveSession(m: *Menu, io: std.Io, session: *const Session, arg: []const u8) ![]const u8 {
        if (arg.len == 0) return error.MissingSessionId;
        if (arg.len == 32) return arg;
        var match: ?[]const u8 = null;
        for (try sessionChoices(io, m.arena.allocator(), session)) |c| {
            if (!std.mem.startsWith(u8, c.value, arg)) continue;
            if (match != null) return error.AmbiguousSession;
            match = c.value;
        }
        return match orelse error.UnknownSession;
    }
};

fn sessionChoices(io: std.Io, a: std.mem.Allocator, session: *const Session) ![]const commands.Choice {
    const directory = try std.fs.path.join(a, &.{ session.options.home, "sessions" });
    const cwd = try std.process.currentPathAlloc(io, a);
    const found = try session_log.list(io, a, directory, cwd);
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const choices = try a.alloc(commands.Choice, found.len);
    for (found, choices) |f, *c| {
        const seconds: u64 = @intCast(@max(@divTrunc(now - f.modified_ns, std.time.ns_per_s), 0));
        var ago_buf: [16]u8 = undefined;
        const ago = if (seconds < 60)
            "now"
        else if (seconds < 3600)
            try std.fmt.bufPrint(&ago_buf, "{d}m ago", .{seconds / 60})
        else if (seconds < 86400)
            try std.fmt.bufPrint(&ago_buf, "{d}h ago", .{seconds / 3600})
        else
            try std.fmt.bufPrint(&ago_buf, "{d}d ago", .{seconds / 86400});
        const current = std.mem.eql(u8, f.id, session.id);
        c.* = .{
            .value = f.id,
            .label = f.id[0..@min(8, f.id.len)],
            .detail = try std.fmt.allocPrint(a, "{s}{s} · {s}", .{ ago, if (current) " (current)" else "", if (f.preview.len > 0) f.preview else "(no messages)" }),
        };
    }
    return choices;
}

const testing = std.testing;

test "selection wraps, closing hides the list and editing reopens it" {
    var m: Menu = .init(testing.allocator);
    defer m.deinit();
    try testing.expectEqualStrings("/copy", m.selected("/co").?.label);
    m.move("/co", true);
    try testing.expectEqualStrings("/compact", m.selected("/co").?.label);
    m.move("/co", true);
    try testing.expectEqualStrings("/copy", m.selected("/co").?.label);
    m.move("/co", false);
    try testing.expectEqualStrings("/compact", m.selected("/co").?.label);
    m.closed = true;
    try testing.expect(m.selected("/co") == null);
    m.inputChanged("/c");
    try testing.expectEqualStrings("/copy", m.selected("/c").?.label);
}
