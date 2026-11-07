//! Codex login tokens: nib's own store first, then the Codex CLI's `auth.json`.
//! Refreshed tokens are written back to the file they came from.

const std = @import("std");
const store = @import("store.zig");
const oauth = @import("oauth.zig");

pub const Source = enum { nib, cli };

pub const Locations = struct {
    nib_home: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
    issuer: ?[]const u8 = null,

    pub fn issuerUrl(l: Locations) []const u8 {
        return l.issuer orelse oauth.default_issuer;
    }
};

pub const Login = struct {
    arena: std.heap.ArenaAllocator,
    access_token: []const u8,
    account_id: []const u8,
    refresh_token: []const u8,
    id_token: []const u8,
    plan: ?[]const u8,
    source: Source,
    file: []const u8,

    pub fn deinit(l: *Login) void {
        l.arena.deinit();
    }
};

fn filePath(a: std.mem.Allocator, dir: ?[]const u8) !?[]u8 {
    const d = dir orelse return null;
    if (d.len == 0) return null;
    return try store.path(a, d);
}

/// error.NotSignedIn when no file exists; error.InvalidCredentials when a file exists without usable tokens.
pub fn load(gpa: std.mem.Allocator, io: std.Io, loc: Locations) !Login {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var invalid = false;
    for ([_]Source{ .nib, .cli }) |source| {
        const file = (try filePath(a, if (source == .nib) loc.nib_home else loc.codex_home)) orelse continue;
        var doc = store.Doc.load(gpa, io, file) catch |err| switch (err) {
            error.InvalidAuthFile => {
                invalid = source == .cli;
                continue;
            },
            else => continue,
        };
        defer doc.deinit();
        const tokens = doc.tokens() orelse {
            if (source == .cli and doc.root.object.count() > 0) invalid = true;
            continue;
        };
        if (std.mem.indexOfAny(u8, tokens.access_token, "\r\n") != null or std.mem.indexOfAny(u8, tokens.account_id, "\r\n") != null) {
            invalid = true;
            continue;
        }
        const claim = oauth.claims(a, tokens.id_token);
        const access = try a.dupe(u8, tokens.access_token);
        const account = try a.dupe(u8, tokens.account_id);
        const refresh_token = try a.dupe(u8, tokens.refresh_token);
        const id_token = try a.dupe(u8, tokens.id_token);
        const plan: ?[]const u8 = if (claim.plan) |p| try a.dupe(u8, p) else null;
        return .{
            .arena = arena,
            .access_token = access,
            .account_id = account,
            .refresh_token = refresh_token,
            .id_token = id_token,
            .plan = plan,
            .source = source,
            .file = file,
        };
    }
    return if (invalid) error.InvalidCredentials else error.NotSignedIn;
}

pub fn now(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn expiring(gpa: std.mem.Allocator, io: std.Io, access_token: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const exp = oauth.claims(arena.allocator(), access_token).exp orelse return false;
    return exp - now(io) < 60;
}

/// Credentials to use for a request. `rejected` is the access token the server refused,
/// if any: a different token on disk is used as is; otherwise a real (JWT) token is refreshed.
/// Tokens that are not JWTs cannot be dated and are never refreshed on their own.
pub fn current(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, loc: Locations, rejected: ?[]const u8) !Login {
    var login = try load(gpa, io, loc);
    errdefer login.deinit();
    if (rejected) |token| if (!std.mem.eql(u8, token, login.access_token)) return login;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const dated = oauth.claims(scratch.allocator(), login.access_token).exp != null;
    const stale = dated and (rejected != null or expiring(gpa, io, login.access_token));
    if (!stale or login.refresh_token.len == 0) return login;
    const fresh = refresh(gpa, io, client, loc, login) catch |err| {
        if (rejected == null and !expiring(gpa, io, login.access_token)) return login;
        return err;
    };
    login.deinit();
    return fresh;
}

fn refresh(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, loc: Locations, old: Login) !Login {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const reply = oauth.refreshRequest(a, client, loc.issuerUrl(), old.refresh_token) catch return error.RefreshFailed;
    const access = reply.access_token orelse return error.RefreshFailed;
    const id_token = reply.id_token orelse old.id_token;
    const claim = oauth.claims(a, id_token);
    const tokens: store.Tokens = .{
        .access_token = access,
        .refresh_token = reply.refresh_token orelse old.refresh_token,
        .id_token = id_token,
        .account_id = claim.account_id orelse old.account_id,
    };
    var doc: store.Doc = try .load(gpa, io, old.file);
    defer doc.deinit();
    var stamp: [20]u8 = undefined;
    try doc.setTokens(tokens, store.timestamp(&stamp, now(io)));
    if (old.source == .nib) try doc.saveSecret(io, gpa, old.file) else try doc.save(io, gpa, old.file);
    return load(gpa, io, loc);
}

/// Stores tokens from a completed browser or device login in nib's own store.
/// Returns the plan claim, allocated with `a`.
pub fn save(a: std.mem.Allocator, io: std.Io, nib_home: []const u8, exchanged: oauth.Exchanged) !?[]const u8 {
    const claim = oauth.claims(a, exchanged.id_token);
    const account = claim.account_id orelse oauth.claims(a, exchanged.access_token).account_id orelse return error.MissingAccountId;
    const file = try store.path(a, nib_home);
    var doc: store.Doc = try .load(a, io, file);
    defer doc.deinit();
    var stamp: [20]u8 = undefined;
    try doc.setTokens(.{
        .access_token = exchanged.access_token,
        .refresh_token = exchanged.refresh_token,
        .id_token = exchanged.id_token,
        .account_id = account,
    }, store.timestamp(&stamp, now(io)));
    try doc.saveSecret(io, a, file);
    return if (claim.plan) |plan| try a.dupe(u8, plan) else null;
}

/// Removes nib's own tokens. Returns whether any were stored.
pub fn remove(gpa: std.mem.Allocator, io: std.Io, nib_home: []const u8) !bool {
    const file = try store.path(gpa, nib_home);
    defer gpa.free(file);
    var doc: store.Doc = try .load(gpa, io, file);
    defer doc.deinit();
    if (!doc.removeTokens()) return false;
    try doc.saveSecret(io, gpa, file);
    return true;
}

const testing = std.testing;

fn writeAuth(tmp: *testing.TmpDir, sub: []const u8, text: []const u8) !void {
    try tmp.dir.createDirPath(testing.io, std.fs.path.dirname(sub).?);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = text });
}

fn dirOf(tmp: *testing.TmpDir, a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(root);
    return std.fs.path.join(a, &.{ root, sub });
}

test "nib tokens take precedence over the Codex CLI file and a missing store falls back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const nib = try dirOf(&tmp, testing.allocator, "nib");
    defer testing.allocator.free(nib);
    const cli = try dirOf(&tmp, testing.allocator, "codex");
    defer testing.allocator.free(cli);
    const loc: Locations = .{ .nib_home = nib, .codex_home = cli };
    try testing.expectError(error.NotSignedIn, load(testing.allocator, testing.io, loc));
    try writeAuth(&tmp, "codex/auth.json", "{\"tokens\":{\"access_token\":\"cli-a\",\"account_id\":\"cli-acc\"}}");
    {
        var login = try load(testing.allocator, testing.io, loc);
        defer login.deinit();
        try testing.expectEqual(Source.cli, login.source);
        try testing.expectEqualStrings("cli-a", login.access_token);
    }
    try writeAuth(&tmp, "nib/auth.json", "{\"tokens\":{\"access_token\":\"nib-a\",\"account_id\":\"nib-acc\"}}");
    var login = try load(testing.allocator, testing.io, loc);
    defer login.deinit();
    try testing.expectEqual(Source.nib, login.source);
    try testing.expectEqualStrings("nib-acc", login.account_id);
}

test "unusable CLI file is invalid rather than missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cli = try dirOf(&tmp, testing.allocator, "codex");
    defer testing.allocator.free(cli);
    try writeAuth(&tmp, "codex/auth.json", "{\"tokens\":{\"access_token\":\"x\"}}");
    try testing.expectError(error.InvalidCredentials, load(testing.allocator, testing.io, .{ .codex_home = cli }));
    try writeAuth(&tmp, "codex/auth.json", "not json");
    try testing.expectError(error.InvalidCredentials, load(testing.allocator, testing.io, .{ .codex_home = cli }));
}

test "save and remove touch only nib's store and keep API keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const nib = try dirOf(&tmp, testing.allocator, "nib");
    defer testing.allocator.free(nib);
    try writeAuth(&tmp, "nib/auth.json", "{\"keys\":{\"openai\":\"fake\"}}");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc-9\",\"chatgpt_plan_type\":\"pro\"}}";
    const enc = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(enc, payload);
    const id = try std.fmt.allocPrint(a, "h.{s}.s", .{enc});
    const plan = try save(a, testing.io, nib, .{ .id_token = id, .access_token = "acc-tok", .refresh_token = "ref" });
    try testing.expectEqualStrings("pro", plan.?);
    var login = try load(testing.allocator, testing.io, .{ .nib_home = nib });
    defer login.deinit();
    try testing.expectEqualStrings("acc-9", login.account_id);
    try testing.expectEqualStrings("pro", login.plan.?);
    try testing.expect(try remove(testing.allocator, testing.io, nib));
    try testing.expect(!try remove(testing.allocator, testing.io, nib));
    var doc: store.Doc = try .load(testing.allocator, testing.io, try store.path(a, nib));
    defer doc.deinit();
    try testing.expectEqualStrings("fake", doc.key("openai").?);
    try testing.expectError(error.MissingAccountId, save(a, testing.io, nib, .{ .id_token = "x", .access_token = "y", .refresh_token = "" }));
}
