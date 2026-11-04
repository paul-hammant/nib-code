const std = @import("std");

pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { id: []const u8, session: ?[]const u8, busy: bool };

    pub fn deinit(r: *Registry, gpa: std.mem.Allocator) void {
        for (r.entries.items) |entry| {
            gpa.free(entry.id);
            if (entry.session) |session_id| gpa.free(session_id);
        }
        r.entries.deinit(gpa);
    }

    pub fn add(r: *Registry, gpa: std.mem.Allocator, io: std.Io, id: []const u8, child: ?[]const u8, busy: bool) !void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        const copy = try gpa.dupe(u8, id);
        errdefer gpa.free(copy);
        const session_copy = if (child) |value| try gpa.dupe(u8, value) else null;
        errdefer if (session_copy) |value| gpa.free(value);
        try r.entries.append(gpa, .{ .id = copy, .session = session_copy, .busy = busy });
    }

    pub fn reserve(r: *Registry, io: std.Io, id: []const u8) ![]const u8 {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        if (!std.mem.startsWith(u8, id, "a")) return error.NotSessionAgent;
        for (r.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.id, id)) continue;
            if (entry.busy) return error.AgentBusy;
            if (entry.session == null) return error.AgentSessionUnavailable;
            entry.busy = true;
            return entry.id;
        }
        return error.AgentNotFound;
    }

    pub fn release(r: *Registry, io: std.Io, id: []const u8) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.releaseLocked(id);
    }

    // The caller holds mutex through completion publication and reservation release.
    pub fn releaseLocked(r: *Registry, id: []const u8) void {
        for (r.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) {
                entry.busy = false;
                return;
            }
        }
    }

    pub fn session(r: *Registry, io: std.Io, id: []const u8) ?[]const u8 {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (r.entries.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry.session;
        }
        return null;
    }

    pub fn bind(r: *Registry, gpa: std.mem.Allocator, io: std.Io, id: []const u8, child: []const u8) !void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (r.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.id, id)) continue;
            if (entry.session) |known| {
                if (!std.mem.eql(u8, known, child)) return error.AgentSessionMismatch;
            } else entry.session = try gpa.dupe(u8, child);
            return;
        }
        return error.AgentNotFound;
    }
};

test "agent reservations survive failure and reject busy or foreign task IDs" {
    const t = std.testing;
    var r: Registry = .{};
    defer r.deinit(t.allocator);
    try r.add(t.allocator, t.io, "a1", null, true);
    try t.expectError(error.AgentBusy, r.reserve(t.io, "a1"));
    try r.bind(t.allocator, t.io, "a1", "child-session");
    r.release(t.io, "a1");
    const id = try r.reserve(t.io, "a1");
    try t.expectEqualStrings("a1", id);
    try t.expectEqualStrings("child-session", r.session(t.io, id).?);
    try t.expectError(error.AgentBusy, r.reserve(t.io, "a1"));
    try t.expectError(error.NotSessionAgent, r.reserve(t.io, "b1"));
    try t.expectError(error.AgentNotFound, r.reserve(t.io, "a2"));
    try t.expectError(error.AgentSessionMismatch, r.bind(t.allocator, t.io, "a1", "other"));
    r.release(t.io, "a1");
    try t.expectEqualStrings("a1", try r.reserve(t.io, "a1"));
    try r.add(t.allocator, t.io, "a2", null, false);
    try t.expectError(error.AgentSessionUnavailable, r.reserve(t.io, "a2"));
}
