//! ChatGPT OAuth as the Codex CLI does it (openai/codex `codex-rs/login`):
//! authorization code with PKCE, device code, refresh. Request building and
//! response parsing are pure; the `*Request` functions perform one HTTP call each.

const std = @import("std");

pub const default_issuer = "https://auth.openai.com";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const scope = "openid profile email offline_access api.connectors.read api.connectors.invoke";
pub const default_port: u16 = 1455;
const b64 = std.base64.url_safe_no_pad;

pub const Pkce = struct {
    verifier: [43]u8,
    challenge: [43]u8,

    pub fn generate(io: std.Io) Pkce {
        var raw: [32]u8 = undefined;
        io.random(&raw);
        var p: Pkce = undefined;
        _ = b64.Encoder.encode(&p.verifier, &raw);
        p.challenge = challengeFor(&p.verifier);
        return p;
    }

    pub fn challengeFor(verifier: []const u8) [43]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        var out: [43]u8 = undefined;
        _ = b64.Encoder.encode(&out, &digest);
        return out;
    }
};

pub fn randomState(io: std.Io) [43]u8 {
    var raw: [32]u8 = undefined;
    io.random(&raw);
    var out: [43]u8 = undefined;
    _ = b64.Encoder.encode(&out, &raw);
    return out;
}

fn appendEncoded(list: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try list.append(a, c);
        } else try list.print(a, "%{X:0>2}", .{c});
    }
}

fn form(a: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |pair, i| {
        if (i > 0) try out.append(a, '&');
        try appendEncoded(&out, a, pair[0]);
        try out.append(a, '=');
        try appendEncoded(&out, a, pair[1]);
    }
    return out.toOwnedSlice(a);
}

pub fn redirectUri(a: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/auth/callback", .{port});
}

pub fn authorizeUrl(a: std.mem.Allocator, issuer: []const u8, redirect_uri: []const u8, challenge: []const u8, state: []const u8) ![]u8 {
    const query = try form(a, &.{
        .{ "response_type", "code" },
        .{ "client_id", client_id },
        .{ "redirect_uri", redirect_uri },
        .{ "scope", scope },
        .{ "code_challenge", challenge },
        .{ "code_challenge_method", "S256" },
        .{ "id_token_add_organizations", "true" },
        .{ "codex_cli_simplified_flow", "true" },
        .{ "state", state },
        .{ "originator", "nib" },
    });
    defer a.free(query);
    return std.fmt.allocPrint(a, "{s}/oauth/authorize?{s}", .{ std.mem.trimEnd(u8, issuer, "/"), query });
}

pub fn exchangeBody(a: std.mem.Allocator, code: []const u8, redirect_uri: []const u8, verifier: []const u8) ![]u8 {
    return form(a, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
        .{ "redirect_uri", redirect_uri },
        .{ "client_id", client_id },
        .{ "code_verifier", verifier },
    });
}

pub fn refreshBody(a: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .client_id = client_id,
        .grant_type = "refresh_token",
        .refresh_token = refresh_token,
        .scope = "openid profile email",
    }, .{});
}

pub fn deviceCodeBody(a: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .client_id = client_id }, .{});
}

pub fn devicePollBody(a: std.mem.Allocator, device_auth_id: []const u8, user_code: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .device_auth_id = device_auth_id, .user_code = user_code }, .{});
}

pub const TokenResponse = struct {
    id_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
};

pub fn parseTokens(a: std.mem.Allocator, body: []const u8) !TokenResponse {
    return std.json.parseFromSliceLeaky(TokenResponse, a, body, .{ .ignore_unknown_fields = true }) catch error.InvalidTokenResponse;
}

pub const Claims = struct {
    account_id: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    email: ?[]const u8 = null,
    /// Unix seconds.
    exp: ?i64 = null,
};

/// Reads the payload of a JWT without verifying it; the server already did.
pub fn claims(a: std.mem.Allocator, token: []const u8) Claims {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return .{};
    const payload = parts.next() orelse return .{};
    if (parts.next() == null) return .{};
    const size = b64.Decoder.calcSizeForSlice(payload) catch return .{};
    const raw = a.alloc(u8, size) catch return .{};
    b64.Decoder.decode(raw, payload) catch return .{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return .{};
    if (root != .object) return .{};
    var out: Claims = .{};
    if (stringField(root.object, "email")) |email| out.email = email;
    if (root.object.get("exp")) |exp| switch (exp) {
        .integer => |n| out.exp = n,
        .float => |f| out.exp = @intFromFloat(f),
        else => {},
    };
    if (root.object.get("https://api.openai.com/auth")) |auth| if (auth == .object) {
        out.account_id = stringField(auth.object, "chatgpt_account_id");
        out.plan = stringField(auth.object, "chatgpt_plan_type");
    };
    return out;
}

fn stringField(map: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = map.get(name) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

pub fn planLabel(buf: []u8, plan: ?[]const u8) []const u8 {
    const raw = plan orelse return "ChatGPT";
    if (raw.len == 0 or raw.len + 8 > buf.len) return "ChatGPT";
    @memcpy(buf[0..8], "ChatGPT ");
    @memcpy(buf[8..][0..raw.len], raw);
    buf[8] = std.ascii.toUpper(buf[8]);
    return buf[0 .. 8 + raw.len];
}

pub const Post = struct { status: u16, body: []u8 };

pub fn post(a: std.mem.Allocator, client: *std.http.Client, url: []const u8, content_type: []const u8, body: []const u8) !Post {
    var response: std.Io.Writer.Allocating = .init(a);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = content_type } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        .response_writer = &response.writer,
    });
    return .{ .status = @intFromEnum(result.status), .body = response.written() };
}

fn tokenUrl(a: std.mem.Allocator, issuer: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/oauth/token", .{std.mem.trimEnd(u8, issuer, "/")});
}

pub const Exchanged = struct { id_token: []const u8, access_token: []const u8, refresh_token: []const u8 };

pub fn exchangeCode(a: std.mem.Allocator, client: *std.http.Client, issuer: []const u8, code: []const u8, redirect: []const u8, verifier: []const u8) !Exchanged {
    const body = try exchangeBody(a, code, redirect, verifier);
    const reply = try post(a, client, try tokenUrl(a, issuer), "application/x-www-form-urlencoded", body);
    if (reply.status < 200 or reply.status >= 300) return error.TokenExchangeRejected;
    const tokens = try parseTokens(a, reply.body);
    return .{
        .id_token = tokens.id_token orelse return error.InvalidTokenResponse,
        .access_token = tokens.access_token orelse return error.InvalidTokenResponse,
        .refresh_token = tokens.refresh_token orelse "",
    };
}

pub fn refreshRequest(a: std.mem.Allocator, client: *std.http.Client, issuer: []const u8, refresh_token: []const u8) !TokenResponse {
    const body = try refreshBody(a, refresh_token);
    const reply = try post(a, client, try tokenUrl(a, issuer), "application/json", body);
    if (reply.status < 200 or reply.status >= 300) return error.RefreshRejected;
    return parseTokens(a, reply.body);
}

pub const DeviceCode = struct {
    verification_url: []const u8,
    user_code: []const u8,
    device_auth_id: []const u8,
    interval_s: u64,
};

const UserCodeReply = struct {
    device_auth_id: []const u8,
    user_code: ?[]const u8 = null,
    usercode: ?[]const u8 = null,
    interval: ?std.json.Value = null,
};

pub fn parseDeviceCode(a: std.mem.Allocator, issuer: []const u8, body: []const u8) !DeviceCode {
    const reply = std.json.parseFromSliceLeaky(UserCodeReply, a, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidDeviceCodeResponse;
    const interval: u64 = if (reply.interval) |value| switch (value) {
        .integer => |n| @intCast(@max(n, 1)),
        .string => |s| std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 10) catch 5,
        else => 5,
    } else 5;
    return .{
        .verification_url = try std.fmt.allocPrint(a, "{s}/codex/device", .{std.mem.trimEnd(u8, issuer, "/")}),
        .user_code = reply.user_code orelse reply.usercode orelse return error.InvalidDeviceCodeResponse,
        .device_auth_id = reply.device_auth_id,
        .interval_s = @max(interval, 1),
    };
}

pub fn requestDeviceCode(a: std.mem.Allocator, client: *std.http.Client, issuer: []const u8) !DeviceCode {
    const url = try std.fmt.allocPrint(a, "{s}/api/accounts/deviceauth/usercode", .{std.mem.trimEnd(u8, issuer, "/")});
    const reply = try post(a, client, url, "application/json", try deviceCodeBody(a));
    if (reply.status == 404) return error.DeviceCodeUnavailable;
    if (reply.status < 200 or reply.status >= 300) return error.DeviceCodeRejected;
    return parseDeviceCode(a, issuer, reply.body);
}

pub const DeviceGrant = struct { authorization_code: []const u8, code_verifier: []const u8 };

/// One poll. null while the user has not approved yet (HTTP 403/404).
pub fn pollDeviceCode(a: std.mem.Allocator, client: *std.http.Client, issuer: []const u8, code: DeviceCode) !?DeviceGrant {
    const url = try std.fmt.allocPrint(a, "{s}/api/accounts/deviceauth/token", .{std.mem.trimEnd(u8, issuer, "/")});
    const reply = try post(a, client, url, "application/json", try devicePollBody(a, code.device_auth_id, code.user_code));
    if (reply.status == 403 or reply.status == 404) return null;
    if (reply.status < 200 or reply.status >= 300) return error.DeviceCodeRejected;
    return std.json.parseFromSliceLeaky(DeviceGrant, a, reply.body, .{ .ignore_unknown_fields = true }) catch error.InvalidDeviceCodeResponse;
}

pub fn deviceRedirectUri(a: std.mem.Allocator, issuer: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/deviceauth/callback", .{std.mem.trimEnd(u8, issuer, "/")});
}

const testing = std.testing;

fn jwt(a: std.mem.Allocator, payload: []const u8) ![]u8 {
    const encoded = try a.alloc(u8, b64.Encoder.calcSize(payload.len));
    _ = b64.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(a, "e30.{s}.sig", .{encoded});
}

test "PKCE challenge matches the RFC 7636 example and verifiers are fresh" {
    const challenge = Pkce.challengeFor("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &challenge);
    const one: Pkce = .generate(testing.io);
    const two: Pkce = .generate(testing.io);
    try testing.expect(!std.mem.eql(u8, &one.verifier, &two.verifier));
    try testing.expectEqualSlices(u8, &Pkce.challengeFor(&one.verifier), &one.challenge);
}

test "authorize URL carries the Codex CLI parameters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = try authorizeUrl(a, "https://auth.example/", "http://127.0.0.1:1455/auth/callback", "chal", "st8");
    try testing.expect(std.mem.startsWith(u8, url, "https://auth.example/oauth/authorize?response_type=code&client_id=" ++ client_id));
    for ([_][]const u8{
        "redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback",
        "scope=openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke",
        "code_challenge=chal&code_challenge_method=S256",
        "id_token_add_organizations=true&codex_cli_simplified_flow=true&state=st8&originator=nib",
    }) |part| try testing.expect(std.mem.indexOf(u8, url, part) != null);
}

test "token request bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "grant_type=authorization_code&code=c%2Fd&redirect_uri=http%3A%2F%2Fx%2Fcb&client_id=" ++ client_id ++ "&code_verifier=ver",
        try exchangeBody(a, "c/d", "http://x/cb", "ver"),
    );
    try testing.expectEqualStrings(
        "{\"client_id\":\"" ++ client_id ++ "\",\"grant_type\":\"refresh_token\",\"refresh_token\":\"r1\",\"scope\":\"openid profile email\"}",
        try refreshBody(a, "r1"),
    );
    try testing.expectEqualStrings("{\"device_auth_id\":\"d1\",\"user_code\":\"AB-CD\"}", try devicePollBody(a, "d1", "AB-CD"));
}

test "token responses and id_token claims" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try parseTokens(a, "{\"id_token\":\"i\",\"access_token\":\"a\",\"extra\":1}");
    try testing.expectEqualStrings("a", tokens.access_token.?);
    try testing.expect(tokens.refresh_token == null);
    try testing.expectError(error.InvalidTokenResponse, parseTokens(a, "nope"));
    const id = try jwt(a, "{\"email\":\"u@example.com\",\"exp\":1900000000,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc-1\",\"chatgpt_plan_type\":\"plus\"}}");
    const c = claims(a, id);
    try testing.expectEqualStrings("acc-1", c.account_id.?);
    try testing.expectEqualStrings("plus", c.plan.?);
    try testing.expectEqual(@as(i64, 1900000000), c.exp.?);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("ChatGPT Plus", planLabel(&buf, c.plan));
    try testing.expectEqualStrings("ChatGPT", planLabel(&buf, null));
    try testing.expect(claims(a, "not-a-jwt").exp == null);
    try testing.expect(claims(a, "a.!!!.c").account_id == null);
}

test "device code responses accept user_code aliases and string intervals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try parseDeviceCode(a, "https://auth.example/", "{\"device_auth_id\":\"d\",\"usercode\":\"AB-1\",\"interval\":\"7\"}");
    try testing.expectEqualStrings("AB-1", one.user_code);
    try testing.expectEqual(@as(u64, 7), one.interval_s);
    try testing.expectEqualStrings("https://auth.example/codex/device", one.verification_url);
    const two = try parseDeviceCode(a, "https://auth.example", "{\"device_auth_id\":\"d\",\"user_code\":\"X\"}");
    try testing.expectEqual(@as(u64, 5), two.interval_s);
    try testing.expectError(error.InvalidDeviceCodeResponse, parseDeviceCode(a, "i", "{\"device_auth_id\":\"d\"}"));
}
