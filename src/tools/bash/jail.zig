const std = @import("std");
const builtin = @import("builtin");
const provider = @import("../../provider.zig");
const instructions = @import("../../session/instructions.zig");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

pub const helper_command = "__jail";

const home_caches = switch (builtin.os.tag) {
    .macos => [_][]const u8{ ".cache", "Library/Caches", "Library/Developer", ".npm", ".cargo", ".rustup", "go/pkg", ".gradle", ".m2", ".bun", ".yarn", ".pnpm-store", ".local/share/pnpm", ".local/share/uv" },
    else => [_][]const u8{ ".cache", ".npm", ".cargo", ".rustup", "go/pkg", ".gradle", ".m2", ".bun", ".yarn", ".pnpm-store", ".local/share/pnpm", ".local/share/uv" },
};

const cache_env = [_][]const u8{ "XDG_CACHE_HOME", "ZIG_GLOBAL_CACHE_DIR", "CARGO_HOME", "RUSTUP_HOME", "GOCACHE", "GOMODCACHE", "GRADLE_USER_HOME", "npm_config_cache", "PIP_CACHE_DIR", "UV_CACHE_DIR" };

const system_paths = switch (builtin.os.tag) {
    .macos => [_][]const u8{ "/tmp", "/var/tmp", "/private/tmp", "/private/var/tmp", "/private/var/folders", "/dev/null", "/dev/zero", "/dev/tty", "/dev/ptmx", "/dev/dtracehelper", "/dev/fd" },
    else => [_][]const u8{ "/tmp", "/var/tmp", "/dev/null", "/dev/zero", "/dev/full", "/dev/tty", "/dev/ptmx", "/dev/pts", "/dev/shm" },
};

pub const Inputs = struct {
    cwd: []const u8,
    home: []const u8,
    environ: ?*const Env = null,
    extra: []const []const u8 = &.{},
};

/// Canonical writable roots; candidates that do not exist are dropped. All memory comes from `a`.
pub fn roots(io: std.Io, a: Allocator, in: Inputs) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const project = instructions.projectRoot(io, a, in.cwd) catch in.cwd;
    try add(io, a, &out, project);
    try addGitDirs(io, a, &out, project);
    for (system_paths) |path| try add(io, a, &out, path);
    if (in.environ) |env| if (env.get("TMPDIR")) |tmp| try add(io, a, &out, tmp);
    if (in.home.len > 0) for (home_caches) |rel| try add(io, a, &out, try std.fs.path.join(a, &.{ in.home, rel }));
    if (in.environ) |env| {
        for (cache_env) |name| if (env.get(name)) |path| try add(io, a, &out, path);
        if (env.get("GOPATH")) |path| try add(io, a, &out, try std.fs.path.join(a, &.{ path, "pkg" }));
    }
    for (in.extra) |path| try add(io, a, &out, path);
    return out.items;
}

fn add(io: std.Io, a: Allocator, out: *std.ArrayList([]const u8), path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return;
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch return;
    for (out.items) |existing| if (std.mem.eql(u8, existing, real)) return;
    try out.append(a, real);
}

// A linked worktree keeps its git state outside the project directory.
fn addGitDirs(io: std.Io, a: Allocator, out: *std.ArrayList([]const u8), project: []const u8) !void {
    const marker = try std.fs.path.join(a, &.{ project, ".git" });
    const text = std.Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(4096)) catch return;
    const prefix = "gitdir:";
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return;
    const raw = std.mem.trim(u8, line[prefix.len..], " \t");
    const git_dir = if (std.fs.path.isAbsolute(raw)) raw else try std.fs.path.join(a, &.{ project, raw });
    try add(io, a, out, git_dir);
    const common = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ git_dir, "commondir" }), a, .limited(4096)) catch return;
    const rel = std.mem.trim(u8, common, " \t\r\n");
    try add(io, a, out, if (std.fs.path.isAbsolute(rel)) rel else try std.fs.path.join(a, &.{ git_dir, rel }));
}

pub fn allows(writable: []const []const u8, canonical: []const u8) bool {
    for (writable) |root| {
        if (!std.mem.startsWith(u8, canonical, root)) continue;
        if (canonical.len == root.len or root[root.len - 1] == '/' or canonical[root.len] == '/') return true;
    }
    return false;
}

pub fn expandHome(a: Allocator, home: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) return a.dupe(u8, home);
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(a, &.{ home, path[2..] });
    return a.dupe(u8, path);
}

pub const Unavailable = enum {
    no_landlock,
    landlock_disabled,
    landlock_old,
    no_sandbox_exec,
    sandbox_exec_failed,
    unsupported_os,

    pub fn text(u: Unavailable) []const u8 {
        return switch (u) {
            .no_landlock => "kernel has no Landlock",
            .landlock_disabled => "Landlock is disabled",
            .landlock_old => "Landlock ABI below 2",
            .no_sandbox_exec => "sandbox-exec not found",
            .sandbox_exec_failed => "sandbox-exec cannot apply a profile here",
            .unsupported_os => "unsupported OS",
        };
    }
};

var probed: std.atomic.Value(u8) = .init(0);

/// Result of the first probe is cached for the process.
pub fn unavailable(io: std.Io) ?Unavailable {
    const state = probed.load(.acquire);
    if (state != 0) return if (state == 1) null else @fromBackingInt(@intCast(state - 2));
    const found = probe(io);
    probed.store(if (found) |u| @as(u8, @backingInt(u)) + 2 else 1, .release);
    return found;
}

fn probe(io: std.Io) ?Unavailable {
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.syscall3(.landlock_create_ruleset, 0, 0, landlock.create_version);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return if (rc >= 2) null else .landlock_old,
                .OPNOTSUPP => return .landlock_disabled,
                else => return .no_landlock,
            }
        },
        .macos => {
            std.Io.Dir.cwd().access(io, sandbox_exec, .{}) catch return .no_sandbox_exec;
            const result = std.process.run(std.heap.page_allocator, io, .{
                .argv = &.{ sandbox_exec, "-p", "(version 1)(allow default)", "/usr/bin/true" },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
            }) catch return .sandbox_exec_failed;
            defer std.heap.page_allocator.free(result.stdout);
            defer std.heap.page_allocator.free(result.stderr);
            return if (result.term == .exited and result.term.exited == 0) null else .sandbox_exec_failed;
        },
        else => return .unsupported_os,
    }
}

const sandbox_exec = "/usr/bin/sandbox-exec";

/// Wraps `inner` so that writes outside `writable` fail. Caller checked `unavailable() == null`.
pub fn wrap(a: Allocator, io: std.Io, writable: []const []const u8, inner: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    switch (builtin.os.tag) {
        .macos => {
            try argv.appendSlice(a, &.{ sandbox_exec, "-p", try profile(a, writable) });
        },
        else => {
            try argv.appendSlice(a, &.{ try std.process.executablePathAlloc(io, a), helper_command });
            try argv.appendSlice(a, writable);
            try argv.append(a, "--");
        },
    }
    try argv.appendSlice(a, inner);
    return argv.items;
}

pub fn profile(a: Allocator, writable: []const []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "(version 1)(allow default)(deny file-write*)(allow file-write*");
    try text.appendSlice(a, "(regex #\"^/dev/ttys[0-9]+$\")");
    for (writable) |path| {
        try text.appendSlice(a, "(subpath \"");
        for (path) |c| {
            if (c == '"' or c == '\\') try text.append(a, '\\');
            if (c >= 0x20) try text.append(a, c);
        }
        try text.appendSlice(a, "\")");
    }
    try text.append(a, ')');
    return text.items;
}

const landlock = struct {
    const create_version: usize = 1;
    const rule_path_beneath: usize = 1;
    const write_file: u64 = 1 << 1;
    const base_write: u64 = 0x1ff << 4 | write_file;
    const refer: u64 = 1 << 13;
    const truncate: u64 = 1 << 14;
};

/// Entry of `nib __jail <root>... -- <command>...`: restricts this process, then becomes the command.
pub fn helper(io: std.Io, args: []const []const u8) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedOs;
    const split = for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) break i;
    } else return error.InvalidArguments;
    const command = args[split + 1 ..];
    if (command.len == 0) return error.InvalidArguments;
    try restrict(args[0..split]);
    return std.process.replace(io, .{ .argv = command });
}

fn restrict(writable: []const []const u8) !void {
    const linux = std.os.linux;
    const abi = linux.syscall3(.landlock_create_ruleset, 0, 0, landlock.create_version);
    if (linux.errno(abi) != .SUCCESS) return error.LandlockUnavailable;
    var handled: u64 = landlock.base_write;
    if (abi >= 2) handled |= landlock.refer;
    if (abi >= 3) handled |= landlock.truncate;
    var attr: [8]u8 = undefined;
    std.mem.writeInt(u64, &attr, handled, .little);
    const ruleset = linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), attr.len, 0);
    if (linux.errno(ruleset) != .SUCCESS) return error.LandlockUnavailable;
    const fd: i32 = @intCast(ruleset);
    for (writable) |path| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= buffer.len) continue;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        const opened = linux.open(@ptrCast(&buffer), .{ .PATH = true, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) continue;
        const parent: i32 = @intCast(opened);
        defer _ = linux.close(parent);
        var rule: [12]u8 = undefined;
        std.mem.writeInt(u32, rule[8..12], @bitCast(parent), .little);
        for ([_]u64{ handled, handled & (landlock.write_file | landlock.truncate) }) |allowed| {
            std.mem.writeInt(u64, rule[0..8], allowed, .little);
            if (linux.errno(linux.syscall4(.landlock_add_rule, @intCast(fd), landlock.rule_path_beneath, @intFromPtr(&rule), 0)) == .SUCCESS) break;
        }
    }
    if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS) return error.LandlockUnavailable;
    if (linux.errno(linux.syscall2(.landlock_restrict_self, @intCast(fd), 0)) != .SUCCESS) return error.LandlockUnavailable;
    _ = linux.close(fd);
}

const testing = std.testing;

fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

test "roots hold the project, temp dirs, existing caches and extras only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "proj/.git");
    try tmp.dir.createDirPath(testing.io, "proj/src/deep");
    try tmp.dir.createDirPath(testing.io, "home/.cache");
    try tmp.dir.createDirPath(testing.io, "extra");
    try tmp.dir.createDirPath(testing.io, "elsewhere");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const list = try roots(testing.io, a, .{
        .cwd = try std.fs.path.join(a, &.{ base, "proj/src/deep" }),
        .home = try std.fs.path.join(a, &.{ base, "home" }),
        .extra = &.{ try std.fs.path.join(a, &.{ base, "extra" }), try std.fs.path.join(a, &.{ base, "missing" }), "relative" },
    });
    try testing.expect(contains(list, try std.fs.path.join(a, &.{ base, "proj" })));
    try testing.expect(contains(list, try std.fs.path.join(a, &.{ base, "home/.cache" })));
    try testing.expect(contains(list, try std.fs.path.join(a, &.{ base, "extra" })));
    try testing.expect(!contains(list, try std.fs.path.join(a, &.{ base, "home/.npm" })));
    try testing.expect(!contains(list, try std.fs.path.join(a, &.{ base, "missing" })));
    try testing.expect(!contains(list, try std.fs.path.join(a, &.{ base, "elsewhere" })));
    try testing.expect(!contains(list, try std.fs.path.join(a, &.{ base, "proj/src/deep" })));
    for (list, 0..) |root, i| for (list[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, root, other));
}

test "a linked worktree adds its git directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "main/.git/worktrees/w");
    try tmp.dir.createDirPath(testing.io, "linked");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main/.git/worktrees/w/commondir", .data = "../..\n" });
    const pointer = try std.fmt.allocPrint(a, "gitdir: {s}/main/.git/worktrees/w\n", .{base});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "linked/.git", .data = pointer });
    const linked = try roots(testing.io, a, .{ .cwd = try std.fs.path.join(a, &.{ base, "linked" }), .home = "" });
    try testing.expect(contains(linked, try std.fs.path.join(a, &.{ base, "main/.git/worktrees/w" })));
    try testing.expect(contains(linked, try std.fs.path.join(a, &.{ base, "main/.git" })));
}

test "allows matches whole path components only" {
    const list = [_][]const u8{ "/work/proj", "/dev/null", "/" };
    try testing.expect(allows(list[0..2], "/work/proj"));
    try testing.expect(allows(list[0..2], "/work/proj/a/b"));
    try testing.expect(allows(list[0..2], "/dev/null"));
    try testing.expect(!allows(list[0..2], "/work/project"));
    try testing.expect(!allows(list[0..2], "/work"));
    try testing.expect(!allows(list[0..2], "/dev/nullx"));
    try testing.expect(allows(list[2..], "/anything"));
}

test "profile denies writes by default and escapes paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try profile(arena.allocator(), &.{ "/p", "/with\"quote\\" });
    try testing.expectEqualStrings("(version 1)(allow default)(deny file-write*)(allow file-write*(regex #\"^/dev/ttys[0-9]+$\")(subpath \"/p\")(subpath \"/with\\\"quote\\\\\"))", text);
}

test "expandHome expands only a leading tilde" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/h/x", try expandHome(a, "/h", "~/x"));
    try testing.expectEqualStrings("/h", try expandHome(a, "/h", "~"));
    try testing.expectEqualStrings("/a/~/x", try expandHome(a, "/h", "/a/~/x"));
}
