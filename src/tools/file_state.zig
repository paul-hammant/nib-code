const std = @import("std");
const Tools = @import("../tools.zig").Tools;

pub const State = struct {
    mutex: std.Io.Mutex = .init,
    seen: std.StringHashMapUnmanaged(Version) = .empty,

    const Version = struct {
        inode: std.Io.File.INode,
        size: u64,
        mtime: i96,

        fn from(stat: std.Io.File.Stat) Version {
            return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds };
        }
    };

    pub fn remember(s: *State, io: std.Io, gpa: std.mem.Allocator, path: []const u8, stat: std.Io.File.Stat) !void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const entry = try s.seen.getOrPut(gpa, path);
        if (!entry.found_existing) {
            errdefer _ = s.seen.remove(path);
            entry.key_ptr.* = try gpa.dupe(u8, path);
        }
        entry.value_ptr.* = .from(stat);
    }

    pub fn changed(s: *State, io: std.Io, path: []const u8, stat: std.Io.File.Stat) bool {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const before = s.seen.get(path) orelse return false;
        return !std.meta.eql(before, Version.from(stat));
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        var keys = s.seen.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        s.seen.deinit(gpa);
        s.seen = .empty;
    }
};

pub fn lock(t: *Tools, gpa: std.mem.Allocator, path: []const u8) !std.Io.File {
    if (t.cancel.load(.acquire)) return error.Canceled;
    const home = if (t.data_home) |home| try gpa.dupe(u8, home) else if (t.environ) |env| try @import("../config.zig").home(gpa, env) else try std.fs.path.join(gpa, &.{ t.home, ".nib" });
    defer gpa.free(home);
    const directory = try std.fs.path.join(gpa, &.{ home, "locks" });
    defer gpa.free(directory);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(t.io, directory);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &hash, .{});
    const name = std.fmt.bytesToHex(hash, .lower);
    const lock_path = try std.fs.path.join(gpa, &.{ directory, &name });
    defer gpa.free(lock_path);
    const file = try cwd.createFile(t.io, lock_path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer file.close(t.io);
    while (true) {
        if (t.cancel.load(.acquire)) return error.Canceled;
        if (try file.tryLock(t.io, .exclusive)) break;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, t.io);
    }
    if (t.cancel.load(.acquire)) return error.Canceled;
    // Lock files must stay linked: unlinking lets waiters lock different inodes.
    return file;
}
