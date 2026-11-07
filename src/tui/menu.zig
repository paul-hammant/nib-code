const std = @import("std");
const commands = @import("commands.zig");
const Session = @import("../session.zig").Session;
const session_log = @import("../session/log.zig");
const paths = @import("paths.zig");
const Editor = @import("editor.zig").Editor;

/// The `/` candidate list above the input: selection, dismissal and session choices.
pub const Menu = struct {
    /// `items` returns slices of this; a Menu must not move while they are used.
    buf: [128]commands.Candidate = undefined,
    sel: usize = 0,
    closed: bool = false,
    /// Owns `sessions` and resolved ids; reset when sessions are listed again.
    arena: std.heap.ArenaAllocator,
    sessions: []const commands.Choice = &.{},
    sessions_loaded: bool = false,
    tasks: []const commands.Choice = &.{},
    models: []const commands.Choice = &.{},
    gpa: std.mem.Allocator,
    /// `@` completions: set while the cursor ends an `@` mention.
    mentioning: bool = false,
    index: ?*paths.Index = null,
    wake: ?paths.Index.Wake = null,
    /// Owns the strings of `file_buf`; reset when the matches are recomputed.
    file_arena: std.heap.ArenaAllocator,
    file_buf: [paths.max_hits]commands.Candidate = undefined,
    file_len: usize = 0,
    file_query: [256]u8 = undefined,
    file_query_len: usize = 0,
    file_generation: u64 = 0,
    file_fresh: bool = false,

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .arena = .init(gpa), .gpa = gpa, .file_arena = .init(gpa) };
    }

    pub fn deinit(m: *Menu) void {
        if (m.index) |ix| {
            ix.deinit();
            m.gpa.destroy(ix);
        }
        m.file_arena.deinit();
        m.arena.deinit();
    }

    pub fn items(m: *Menu, input: []const u8) []commands.Candidate {
        if (m.closed) return m.buf[0..0];
        const slash = commands.candidates(input, m.sessions, m.tasks, m.models, &m.buf);
        if (slash.len > 0 or !m.mentioning) return slash;
        return m.file_buf[0..m.file_len];
    }

    /// Follows the editor's `@` mention: starts or refreshes the path listing and ranks it.
    pub fn sync(m: *Menu, io: std.Io, e: *const Editor, session: *const Session) void {
        const found = e.fileMention() orelse {
            m.mentioning = false;
            m.file_fresh = false;
            m.file_len = 0;
            return;
        };
        if (m.index == null) {
            const ix = m.gpa.create(paths.Index) catch return;
            ix.* = .{ .gpa = m.gpa, .io = io, .wake = m.wake };
            m.index = ix;
        }
        const ix = m.index.?;
        if (!m.mentioning) {
            m.mentioning = true;
            m.file_fresh = false;
            ix.refresh(@constCast(&session.tools));
        }
        const query = found.query[0..@min(found.query.len, m.file_query.len)];
        const same = m.file_fresh and std.mem.eql(u8, query, m.file_query[0..m.file_query_len]);
        ix.withEntries(Rank{ .m = m, .query = query, .same = same, .generation = &ix.generation }, Rank.run);
    }

    const Rank = struct {
        m: *Menu,
        query: []const u8,
        same: bool,
        generation: *const u64,

        fn run(r: Rank, entries: []const paths.Entry) void {
            const m = r.m;
            if (r.same and m.file_generation == r.generation.*) return;
            m.file_generation = r.generation.*;
            m.file_fresh = true;
            @memcpy(m.file_query[0..r.query.len], r.query);
            m.file_query_len = r.query.len;
            _ = m.file_arena.reset(.retain_capacity);
            const a = m.file_arena.allocator();
            var hits: [paths.max_hits]paths.Hit = undefined;
            m.file_len = 0;
            for (paths.top(entries, r.query, &hits)) |h| {
                const entry = entries[h.index];
                const value = paths.insertion(a, entry.path, entry.dir) catch break;
                const label = if (entry.dir) std.fmt.allocPrint(a, "{s}/", .{entry.path}) catch break else entry.path;
                m.file_buf[m.file_len] = .{ .command = .help, .value = value, .label = label, .detail = "", .is_path = true };
                m.file_len += 1;
            }
            if (m.sel >= m.file_len) m.sel = 0;
        }
    };

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
        if (std.mem.startsWith(u8, input, "/model ")) {
            _ = m.arena.reset(.retain_capacity);
            const a = m.arena.allocator();
            const env = session.options.environ orelse return;
            const entries = try @import("../config.zig").modelEntries(a, io, env, session.options.home);
            const choices = try a.alloc(commands.Choice, entries.len);
            for (entries, choices) |entry, *choice| {
                const active = std.mem.eql(u8, entry.provider, session.cfg.name()) and std.mem.eql(u8, entry.model, session.cfg.model);
                choice.* = .{ .value = try std.fmt.allocPrint(a, "{s}/{s}", .{ entry.provider, entry.model }), .label = try std.fmt.allocPrint(a, "{s} · {s}", .{ entry.provider, entry.model }), .detail = if (active) "current" else "" };
            }
            m.models = choices;
            return;
        }
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
        var ago_buf: [128]u8 = undefined;
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
