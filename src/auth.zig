//! Credentials: where each service's key or login comes from, and what the UI says about it.
//! Precedence: environment key, then nib's `auth.json`, then (Codex only) the Codex CLI login.
//! Keys never leave this module in text meant for people.

const std = @import("std");
const provider = @import("provider.zig");
const config = @import("config.zig");
pub const store = @import("auth/store.zig");
pub const oauth = @import("auth/oauth.zig");
pub const codex = @import("auth/codex.zig");
pub const login = @import("auth/login.zig");
pub const models = @import("auth/models.zig");

const Env = std.process.Environ.Map;

pub const Service = struct {
    id: []const u8,
    name: []const u8,
    custom: bool,
    /// Requests can be sent now.
    signed_in: bool,
    /// nib itself holds a key or login that sign-out would remove.
    stored: bool,
    status: []const u8,
};

pub fn codexLocations(env: *const Env, nib_home: []const u8, a: std.mem.Allocator) !codex.Locations {
    const codex_home = env.get("CODEX_HOME") orelse try std.fs.path.join(a, &.{ env.get("HOME") orelse "", ".codex" });
    return .{ .nib_home = nib_home, .codex_home = codex_home, .issuer = env.get("NIB_AUTH_ISSUER") };
}

fn envKey(env: *const Env, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (env.get(name)) |value| if (value.len > 0) return name;
    return null;
}

fn storedKey(a: std.mem.Allocator, io: std.Io, home: []const u8, id: []const u8) bool {
    const file = store.path(a, home) catch return false;
    defer a.free(file);
    var doc = store.Doc.load(a, io, file) catch return false;
    defer doc.deinit();
    return doc.key(id) != null;
}

fn host(base_url: []const u8) []const u8 {
    const rest = if (std.mem.indexOf(u8, base_url, "://")) |i| base_url[i + 3 ..] else base_url;
    return rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
}

/// Built-in services in menu order, then custom ones. Everything is allocated with `a`.
pub fn services(a: std.mem.Allocator, io: std.Io, env: *const Env, home: []const u8) ![]const Service {
    var out: std.ArrayList(Service) = .empty;
    for (config.startup_order) |id| {
        const entry = for (provider.definitions) |d| {
            if (std.mem.eql(u8, d.id, id)) break d;
        } else unreachable;
        if (std.mem.eql(u8, id, "codex")) {
            var status: []const u8 = "—";
            var signed_in = false;
            var stored = false;
            if (codex.load(a, io, try codexLocations(env, home, a))) |loaded| {
                var l = loaded;
                defer l.deinit();
                var buf: [64]u8 = undefined;
                status = try std.fmt.allocPrint(a, "signed in · {s}", .{oauth.planLabel(&buf, l.plan)});
                signed_in = true;
                stored = l.source == .nib;
            } else |_| {}
            try out.append(a, .{ .id = id, .name = entry.name, .custom = false, .signed_in = signed_in, .stored = stored, .status = status });
            continue;
        }
        const from_env = envKey(env, entry.api_key_env);
        const stored = storedKey(a, io, home, id);
        try out.append(a, .{
            .id = id,
            .name = entry.name,
            .custom = false,
            .signed_in = from_env != null or stored,
            .stored = stored,
            .status = if (from_env) |name| name else if (stored) "key stored" else "—",
        });
    }
    for (try config.customProviders(a, io, home)) |item| {
        const from_env = if (item.api_key_env) |name| envKey(env, &.{name}) != null else false;
        const stored = storedKey(a, io, home, item.id);
        const signed_in = item.api_key_env == null or from_env or stored;
        try out.append(a, .{
            .id = item.id,
            .name = item.id,
            .custom = true,
            .signed_in = signed_in,
            .stored = stored,
            .status = if (signed_in) host(item.base_url) else try std.fmt.allocPrint(a, "{s} · no key", .{host(item.base_url)}),
        });
    }
    return out.toOwnedSlice(a);
}

pub fn find(list: []const Service, id: []const u8) ?Service {
    for (list) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

/// One line for /status; never contains a key.
pub fn describe(a: std.mem.Allocator, io: std.Io, cfg: provider.Config) []const u8 {
    if (cfg.provider == .codex) {
        var l = codex.load(a, io, .{ .nib_home = cfg.nib_home, .codex_home = cfg.codex_home, .issuer = cfg.auth_issuer }) catch return "not signed in";
        defer l.deinit();
        return if (l.source == .nib) "ChatGPT login stored by nib" else "ChatGPT login from the Codex CLI";
    }
    return switch (cfg.key_source) {
        .env => std.fmt.allocPrint(a, "key from {s}", .{cfg.api_key_env orelse "environment"}) catch "key from environment",
        .store => "key stored by nib",
        .none => if (cfg.missingKey()) "no key" else "no key needed",
    };
}

pub fn setKey(a: std.mem.Allocator, io: std.Io, home: []const u8, id: []const u8, key: []const u8) !void {
    const file = try store.path(a, home);
    defer a.free(file);
    var doc: store.Doc = try .load(a, io, file);
    defer doc.deinit();
    try doc.setKey(id, key);
    try doc.save(io, a, file);
}

pub const Signout = struct {
    /// nib's own credential was removed.
    removed: bool,
    /// A key still comes from this environment variable.
    env_name: ?[]const u8 = null,
    /// A Codex CLI login still exists.
    cli_login: bool = false,
};

pub fn signOut(a: std.mem.Allocator, io: std.Io, env: *const Env, home: []const u8, id: []const u8) !Signout {
    if (std.mem.eql(u8, id, "codex")) {
        const removed = try codex.remove(a, io, home);
        var remaining = codex.load(a, io, try codexLocations(env, home, a)) catch return .{ .removed = removed };
        remaining.deinit();
        return .{ .removed = removed, .cli_login = true };
    }
    const file = try store.path(a, home);
    defer a.free(file);
    var doc: store.Doc = try .load(a, io, file);
    defer doc.deinit();
    const removed = doc.removeKey(id);
    if (removed) try doc.save(io, a, file);
    var names: []const []const u8 = &.{};
    for (provider.definitions) |d| if (std.mem.eql(u8, d.id, id)) {
        names = d.api_key_env;
    };
    var env_name = envKey(env, names);
    if (env_name == null) for (config.customProviders(a, io, home) catch &.{}) |item| {
        if (std.mem.eql(u8, item.id, id)) if (item.api_key_env) |name| {
            env_name = envKey(env, &.{name});
        };
    };
    return .{ .removed = removed, .env_name = env_name };
}

pub fn knownService(list: []const Service, id: []const u8) bool {
    return find(list, id) != null;
}

const testing = std.testing;

test "service status names sources and never keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env: Env = .init(a);
    try env.put("HOME", root);
    try env.put("CODEX_HOME", try std.fs.path.join(a, &.{ root, "codex" }));
    try env.put("ANTHROPIC_API_KEY", "secret-env-value");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auth.json", .data = "{\"keys\":{\"deepseek\":\"secret-stored-value\",\"site\":\"secret-site\"}}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.toml", .data = "[providers.site]\nprotocol = \"responses\"\nbase_url = \"https://models.example.com/v1\"\nmodel = \"m\"\ncontext_window = 9\napi_key_env = \"SITE_KEY\"\n[providers.local]\nprotocol = \"responses\"\nbase_url = \"http://localhost:8080\"\nmodel = \"m\"\ncontext_window = 9\n[providers.gated]\nprotocol = \"responses\"\nbase_url = \"http://gated.test\"\nmodel = \"m\"\ncontext_window = 9\napi_key_env = \"GATED_KEY\"\n" });
    const list = try services(a, testing.io, &env, root);
    const expected = [_][2][]const u8{
        .{ "codex", "—" },
        .{ "anthropic", "ANTHROPIC_API_KEY" },
        .{ "openai", "—" },
        .{ "deepseek", "key stored" },
        .{ "xai", "—" },
        .{ "site", "models.example.com" },
        .{ "local", "localhost:8080" },
        .{ "gated", "gated.test · no key" },
    };
    try testing.expectEqual(expected.len, list.len);
    for (expected, list) |want, got| {
        try testing.expectEqualStrings(want[0], got.id);
        try testing.expectEqualStrings(want[1], got.status);
        try testing.expect(std.mem.indexOf(u8, got.status, "secret") == null);
    }
    try testing.expect(!list[0].signed_in and list[1].signed_in and !list[2].signed_in and list[3].stored and list[5].stored);
    try testing.expect(list[6].signed_in and !list[7].signed_in);
    try tmp.dir.createDirPath(testing.io, "codex");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "codex/auth.json", .data = "{\"tokens\":{\"access_token\":\"a\",\"account_id\":\"b\"}}" });
    const with_codex = try services(a, testing.io, &env, root);
    try testing.expectEqualStrings("signed in · ChatGPT", with_codex[0].status);
    try testing.expect(with_codex[0].signed_in and !with_codex[0].stored);
}

test "sign out removes only nib's credential and reports the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env: Env = .init(a);
    try env.put("HOME", root);
    try env.put("CODEX_HOME", try std.fs.path.join(a, &.{ root, "codex" }));
    try env.put("OPENAI_API_KEY", "env-fake");
    try setKey(a, testing.io, root, "openai", "stored-fake");
    try setKey(a, testing.io, root, "xai", "stored-fake");
    var out = try signOut(a, testing.io, &env, root, "openai");
    try testing.expect(out.removed);
    try testing.expectEqualStrings("OPENAI_API_KEY", out.env_name.?);
    out = try signOut(a, testing.io, &env, root, "openai");
    try testing.expect(!out.removed);
    out = try signOut(a, testing.io, &env, root, "xai");
    try testing.expect(out.removed and out.env_name == null);
    try tmp.dir.createDirPath(testing.io, "codex");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "codex/auth.json", .data = "{\"tokens\":{\"access_token\":\"a\",\"account_id\":\"b\"}}" });
    out = try signOut(a, testing.io, &env, root, "codex");
    try testing.expect(!out.removed and out.cli_login);
    const cli_file = try tmp.dir.readFileAlloc(testing.io, "codex/auth.json", a, .unlimited);
    try testing.expect(cli_file.len > 0);
}

test "describe names the credential source" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: provider.Config = .{ .provider = .anthropic, .base_url = "", .api_key = "k", .model = "m", .key_source = .env, .api_key_env = "ANTHROPIC_API_KEY" };
    try testing.expectEqualStrings("key from ANTHROPIC_API_KEY", describe(a, testing.io, cfg));
    cfg.key_source = .store;
    try testing.expectEqualStrings("key stored by nib", describe(a, testing.io, cfg));
    cfg.key_source = .none;
    cfg.api_key = "";
    try testing.expectEqualStrings("no key", describe(a, testing.io, cfg));
}
