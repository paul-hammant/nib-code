const std = @import("std");
const provider = @import("../provider.zig");
const responses = @import("../provider/responses.zig");
const sse = @import("../provider/sse.zig");
const codex_login = @import("../auth/codex.zig");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const web = @import("web.zig");
const V = std.json.Value;

const timeout_ms = 60_000;
const max_body = 8 * 1024 * 1024;
const max_count = 50;
const deepseek_query_chars = 128;
const responses_model = "gpt-6-luna";
const anthropic_model = "claude-haiku-5-5";
const anthropic_tool = "web_search_20250305";
const instructions = "Search the web and answer concisely, citing sources.";

const Route = enum { codex, openai, anthropic, deepseek };

const Args = struct { query: []const u8, count: i64 = 10 };

const Item = struct { title: []const u8, url: []const u8, date: ?[]const u8 = null, summary: []const u8 = "" };

const Outcome = struct { answer: ?[]const u8 = null, results: []const Item = &.{}, failure: ?[]const u8 = null };

const Call = struct { cfg: provider.Config, route: Route, url: []const u8, body: []const u8 };

const Reply = struct { status: u16, body: []const u8 };

fn route(cfg: provider.Config) ?Route {
    return switch (cfg.provider) {
        .codex => .codex,
        .openai => .openai,
        .anthropic => .anthropic,
        .deepseek => .deepseek,
        else => null,
    };
}

pub fn supported(cfg: provider.Config) bool {
    return route(cfg) != null;
}

fn failure(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !sandbox.ToolResult {
    const message = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(message);
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .@"error" = message }, .{}) };
}

pub fn search(t: *tools.Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(Args, a, args, .{ .ignore_unknown_fields = true }) catch
        return tools.fail(gpa, "expected {{ query: string, count?: number }}", .{});
    if (std.mem.trim(u8, parsed.query, " \t\r\n").len == 0) return tools.fail(gpa, "query must not be empty", .{});
    if (parsed.count < 1 or parsed.count > max_count) return tools.fail(gpa, "count must be between 1 and {d}", .{max_count});
    const count: usize = @intCast(parsed.count);
    const cfg = t.cfg orelse return failure(gpa, "web search needs a configured provider", .{});
    const kind = route(cfg) orelse return failure(gpa, "web search is not available for provider {s}", .{cfg.name()});
    if (kind == .deepseek) {
        const chars = std.unicode.utf8CountCodepoints(parsed.query) catch return tools.fail(gpa, "query must be valid UTF-8", .{});
        if (chars > deepseek_query_chars) return tools.fail(gpa, "query is {d} characters; DeepSeek search accepts at most {d}", .{ chars, deepseek_query_chars });
    }
    const call = try buildCall(a, cfg, kind, parsed.query, count);
    var detail: ?[]u8 = null;
    const reply = exchange(t, gpa, a, call, &detail) catch |err| return switch (err) {
        error.Canceled => tools.fail(gpa, "canceled", .{}),
        error.Timeout => failure(gpa, "timed out after {d} ms", .{timeout_ms}),
        error.InvalidCredentials => failure(gpa, "{s}", .{detail orelse "invalid credentials"}),
        else => failure(gpa, "{s}", .{@errorName(err)}),
    };
    if (reply.status < 200 or reply.status >= 300) return failure(gpa, "HTTP {d}: {s}", .{ reply.status, clip(reply.body, 300) });
    const outcome = (switch (kind) {
        .codex, .openai => parseResponses(a, reply.body, count),
        .anthropic => parseAnthropic(a, reply.body, count),
        .deepseek => parseDeepseek(a, reply.body, count),
    }) catch |err| return failure(gpa, "invalid search response: {s}", .{@errorName(err)});
    if (outcome.failure) |message| return failure(gpa, "{s}", .{message});
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .answer = outcome.answer, .results = outcome.results }, .{ .emit_null_optional_fields = false }) };
}

fn buildCall(a: std.mem.Allocator, cfg: provider.Config, kind: Route, query: []const u8, count: usize) !Call {
    const base = std.mem.trimEnd(u8, cfg.base_url, "/");
    const path = switch (kind) {
        .codex => "codex/responses",
        .openai => "responses",
        .anthropic => "v1/messages",
        .deepseek => "v1/tools/search",
    };
    const body = switch (kind) {
        .codex, .openai => try std.json.Stringify.valueAlloc(a, .{
            .model = responses_model,
            .instructions = instructions,
            .input = &.{.{ .role = "user", .content = &.{.{ .type = "input_text", .text = query }} }},
            .tools = &.{.{ .type = "web_search", .search_context_size = "high" }},
            .tool_choice = "required",
            .include = &.{"web_search_call.action.sources"},
            .store = false,
            .stream = true,
        }, .{}),
        .anthropic => try std.json.Stringify.valueAlloc(a, .{
            .model = anthropic_model,
            .max_tokens = 4096,
            .messages = &.{.{ .role = "user", .content = query }},
            .tools = &.{.{ .type = anthropic_tool, .name = "web_search", .max_uses = 5 }},
        }, .{}),
        .deepseek => try std.json.Stringify.valueAlloc(a, .{ .query = query, .count = count }, .{}),
    };
    return .{ .cfg = cfg, .route = kind, .url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, path }), .body = body };
}

fn exchange(t: *tools.Tools, gpa: std.mem.Allocator, a: std.mem.Allocator, call: Call, detail: *?[]u8) !Reply {
    const U = union(enum) { reply: anyerror!Reply, stop: web.Stop };
    var buffer: [2]U = undefined;
    var select = std.Io.Select(U).init(t.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.reply, post, .{ t.io, gpa, a, t.environ, call, detail });
    try select.concurrent(.stop, web.watch, .{ t.io, t.cancelFlag(), @as(u64, timeout_ms) });
    return switch (try select.await()) {
        .reply => |reply| reply,
        .stop => |stop| if (stop == .canceled) error.Canceled else error.Timeout,
    };
}

fn post(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, environ: ?*const std.process.Environ.Map, call: Call, detail: *?[]u8) anyerror!Reply {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    if (environ) |env| try client.initDefaultProxies(a, env);
    const uri = try std.Uri.parse(call.url);
    var rejected: ?[]const u8 = null;
    for (0..2) |attempt| {
        var login: ?codex_login.Login = if (call.route == .codex) try responses.credentials(a, &client, call.cfg, detail, rejected) else null;
        defer if (login) |*value| value.deinit();
        var headers: std.ArrayList(std.http.Header) = .empty;
        const events = call.route == .codex or call.route == .openai;
        try headers.append(a, .{ .name = "accept", .value = if (events) "text/event-stream" else "application/json" });
        if (call.route == .anthropic) {
            try headers.append(a, .{ .name = "anthropic-version", .value = "2023-06-01" });
            if (call.cfg.api_key.len > 0) try headers.append(a, .{ .name = "x-api-key", .value = call.cfg.api_key });
        } else {
            const token = if (login) |value| value.access_token else call.cfg.api_key;
            if (token.len > 0) try headers.append(a, .{ .name = "authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) });
        }
        if (login) |value| {
            try headers.append(a, .{ .name = "chatgpt-account-id", .value = value.account_id });
            try headers.append(a, .{ .name = "OpenAI-Beta", .value = "responses=experimental" });
            try headers.append(a, .{ .name = "originator", .value = "nib" });
        }
        var req = try client.request(.POST, uri, .{
            .redirect_behavior = .not_allowed,
            .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
            .extra_headers = headers.items,
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = call.body.len };
        var writer = try req.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(call.body);
        try writer.end();
        try req.connection.?.flush();
        var response = try req.receiveHead(&.{});
        const reader = response.reader(try a.alloc(u8, 16 * 1024));
        const body = reader.allocRemaining(a, .limited(max_body)) catch |err| return switch (err) {
            error.ReadFailed => response.bodyErr() orelse err,
            error.StreamTooLong => error.ResponseTooLarge,
            else => err,
        };
        const status: u16 = @backingInt(response.head.status);
        if (status == 401 and login != null and attempt == 0) {
            rejected = try a.dupe(u8, login.?.access_token);
            continue;
        }
        return .{ .status = status, .body = body };
    }
    unreachable;
}

fn field(v: V, name: []const u8) V {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}

fn str(v: V) ?[]const u8 {
    return if (v == .string) v.string else null;
}

fn items(v: V) []const V {
    return if (v == .array) v.array.items else &.{};
}

fn clip(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

/// Gathers one search across providers: cited results rank before other sources.
const Collector = struct {
    a: std.mem.Allocator,
    cited: std.ArrayList(Item) = .empty,
    other: std.ArrayList(Item) = .empty,
    text: std.ArrayList(u8) = .empty,
    searched: bool = false,
    failed: ?[]const u8 = null,

    fn finish(c: *Collector, count: usize) !Outcome {
        if (c.failed) |message| return .{ .failure = message };
        if (!c.searched) return .{ .failure = "model answered without searching" };
        var out: std.ArrayList(Item) = .empty;
        for ([_][]const Item{ c.cited.items, c.other.items }) |list| for (list) |item| {
            const existing = for (out.items) |*seen| {
                if (std.mem.eql(u8, seen.url, item.url)) break seen;
            } else null;
            if (existing) |seen| {
                if (seen.date == null) seen.date = item.date;
                if (seen.summary.len == 0) seen.summary = item.summary;
                continue;
            }
            if (out.items.len < count) try out.append(c.a, item);
        };
        return .{ .answer = if (c.text.items.len > 0) c.text.items else null, .results = out.items };
    }
};

fn parseResponses(a: std.mem.Allocator, body: []const u8, count: usize) !Outcome {
    var c: Collector = .{ .a = a };
    var parser: sse.Parser = .{};
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (true) {
        const line = lines.next();
        const data = (try parser.feed(a, line orelse "")) orelse {
            if (line == null) break;
            continue;
        };
        if (std.mem.eql(u8, data, "[DONE]")) continue;
        const event = std.json.parseFromSliceLeaky(V, a, data, .{}) catch continue;
        const kind = str(field(event, "type")) orelse "";
        if (std.mem.eql(u8, kind, "response.output_item.done")) {
            const item = field(event, "item");
            const item_kind = str(field(item, "type")) orelse "";
            if (std.mem.eql(u8, item_kind, "web_search_call")) {
                c.searched = true;
                for (items(field(field(item, "action"), "sources"))) |source| if (str(field(source, "url"))) |url|
                    try c.other.append(a, .{ .title = str(field(source, "title")) orelse url, .url = url });
            } else if (std.mem.eql(u8, item_kind, "message")) {
                for (items(field(item, "content"))) |part| {
                    if (str(field(part, "text"))) |text| try c.text.appendSlice(a, text);
                    for (items(field(part, "annotations"))) |note| {
                        if (!std.mem.eql(u8, str(field(note, "type")) orelse "", "url_citation")) continue;
                        if (str(field(note, "url"))) |url| try c.cited.append(a, .{ .title = str(field(note, "title")) orelse url, .url = url });
                    }
                }
            }
        } else if (std.mem.eql(u8, kind, "response.failed") or std.mem.eql(u8, kind, "error")) {
            const err = if (field(event, "response") != .null) field(field(event, "response"), "error") else if (field(event, "error") != .null) field(event, "error") else event;
            c.failed = str(field(err, "message")) orelse "search request failed";
        }
    }
    return c.finish(count);
}

fn parseAnthropic(a: std.mem.Allocator, body: []const u8, count: usize) !Outcome {
    const root = try std.json.parseFromSliceLeaky(V, a, body, .{});
    var c: Collector = .{ .a = a };
    if (std.mem.eql(u8, str(field(root, "type")) orelse "", "error"))
        c.failed = str(field(field(root, "error"), "message")) orelse "search request failed";
    for (items(field(root, "content"))) |block| {
        const kind = str(field(block, "type")) orelse "";
        if (std.mem.eql(u8, kind, "text")) {
            if (str(field(block, "text"))) |text| try c.text.appendSlice(a, text);
            for (items(field(block, "citations"))) |cite| if (str(field(cite, "url"))) |url|
                try c.cited.append(a, .{ .title = str(field(cite, "title")) orelse url, .url = url, .summary = str(field(cite, "cited_text")) orelse "" });
        } else if (std.mem.eql(u8, kind, "server_tool_use")) {
            c.searched = true;
        } else if (std.mem.eql(u8, kind, "web_search_tool_result")) {
            c.searched = true;
            const content = field(block, "content");
            if (content == .object) c.failed = c.failed orelse try std.fmt.allocPrint(a, "web search failed: {s}", .{str(field(content, "error_code")) orelse "unknown"});
            for (items(content)) |hit| if (str(field(hit, "url"))) |url|
                try c.other.append(a, .{ .title = str(field(hit, "title")) orelse url, .url = url, .date = str(field(hit, "page_age")) });
        }
    }
    return c.finish(count);
}

fn parseDeepseek(a: std.mem.Allocator, body: []const u8, count: usize) !Outcome {
    const root = try std.json.parseFromSliceLeaky(V, a, body, .{});
    var out: std.ArrayList(Item) = .empty;
    for (items(field(root, "results"))) |hit| {
        if (out.items.len >= count) break;
        const url = str(field(hit, "url")) orelse continue;
        try out.append(a, .{
            .title = str(field(hit, "title")) orelse url,
            .url = url,
            .date = str(field(hit, "date")),
            .summary = str(field(hit, "summary")) orelse str(field(hit, "snippet")) orelse "",
        });
    }
    return .{ .results = out.items };
}

const testing = std.testing;

fn expectJson(comptime expected: []const u8, outcome: Outcome) !void {
    const actual = try std.json.Stringify.valueAlloc(testing.allocator, .{ .answer = outcome.answer, .results = outcome.results }, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn arenaTest() std.heap.ArenaAllocator {
    return .init(testing.allocator);
}

test "responses stream: cited results first, deduped, capped, sources kept" {
    var arena = arenaTest();
    defer arena.deinit();
    const body =
        \\data: {"type":"response.created"}
        \\
        \\data: {"type":"response.output_item.done","item":{"type":"web_search_call","action":{"type":"search","sources":[{"type":"url","url":"https://a.dev/1"},{"type":"url","url":"https://b.dev/2"},{"type":"url","url":"https://c.dev/3"}]}}}
        \\
        \\data: {"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"Answer.","annotations":[{"type":"url_citation","url":"https://b.dev/2","title":"B"},{"type":"file_citation"}]}]}}
        \\
        \\data: [DONE]
        \\
    ;
    try expectJson(
        \\{"answer":"Answer.","results":[{"title":"B","url":"https://b.dev/2","summary":""},{"title":"https://a.dev/1","url":"https://a.dev/1","summary":""}]}
    , try parseResponses(arena.allocator(), body, 2));
    const all = try parseResponses(arena.allocator(), body, 10);
    try testing.expectEqual(@as(usize, 3), all.results.len);
}

test "responses stream without web_search_call is a failure" {
    var arena = arenaTest();
    defer arena.deinit();
    const body = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"guess\"}]}}\n\n";
    const outcome = try parseResponses(arena.allocator(), body, 10);
    try testing.expectEqualStrings("model answered without searching", outcome.failure.?);
}

test "responses stream failure carries the upstream message" {
    var arena = arenaTest();
    defer arena.deinit();
    const outcome = try parseResponses(arena.allocator(), "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"quota\"}}}\n\n", 10);
    try testing.expectEqualStrings("quota", outcome.failure.?);
}

test "anthropic message: results, citations, dates" {
    var arena = arenaTest();
    defer arena.deinit();
    const body =
        \\{"content":[{"type":"server_tool_use","name":"web_search","input":{"query":"q"}},
        \\{"type":"web_search_tool_result","content":[{"type":"web_search_result","url":"https://a.dev","title":"A","page_age":"May 1, 2026"},{"type":"web_search_result","url":"https://b.dev","title":"B","page_age":null}]},
        \\{"type":"text","text":"Found.","citations":[{"type":"web_search_result_location","url":"https://b.dev","title":"B","cited_text":"quote"}]}]}
    ;
    try expectJson(
        \\{"answer":"Found.","results":[{"title":"B","url":"https://b.dev","summary":"quote"},{"title":"A","url":"https://a.dev","date":"May 1, 2026","summary":""}]}
    , try parseAnthropic(arena.allocator(), body, 10));
}

test "anthropic without a search or with a tool error fails" {
    var arena = arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("model answered without searching", (try parseAnthropic(a, "{\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}", 10)).failure.?);
    const failed = try parseAnthropic(a, "{\"content\":[{\"type\":\"web_search_tool_result\",\"content\":{\"type\":\"web_search_tool_result_error\",\"error_code\":\"max_uses_exceeded\"}}]}", 10);
    try testing.expectEqualStrings("web search failed: max_uses_exceeded", failed.failure.?);
}

test "deepseek results use summary, fall back to snippet and tolerate null date" {
    var arena = arenaTest();
    defer arena.deinit();
    const body =
        \\{"results":[{"title":"A","url":"https://a.dev","snippet":"s","summary":"sum","date":"2026-01-02"},{"title":"B","url":"https://b.dev","snippet":"only snippet","summary":null,"date":null},{"title":"C","url":"https://c.dev","summary":"x"}]}
    ;
    try expectJson(
        \\{"results":[{"title":"A","url":"https://a.dev","date":"2026-01-02","summary":"sum"},{"title":"B","url":"https://b.dev","summary":"only snippet"}]}
    , try parseDeepseek(arena.allocator(), body, 2));
}

test "search validates arguments and provider before any request" {
    var cfg: provider.Config = .{ .base_url = "http://127.0.0.1:1", .api_key = "k", .model = "m", .provider = .chat_completions };
    var t: tools.Tools = .{ .io = testing.io, .home = "/home/nobody", .cfg = cfg };
    const bad = [_][]const u8{ "{}", "{\"query\":\"\"}", "{\"query\":\"x\",\"count\":0}", "{\"query\":\"x\",\"count\":51}", "{\"query\":1}" };
    for (bad) |args| {
        const result = try search(&t, testing.allocator, args);
        defer tools.freeResult(result);
        try testing.expect(result == .err);
    }
    const unsupported = try search(&t, testing.allocator, "{\"query\":\"x\"}");
    defer tools.freeResult(unsupported);
    try testing.expectEqualStrings("{\"ok\":false,\"error\":\"web search is not available for provider chat_completions\"}", unsupported.ok);
    cfg.provider = .deepseek;
    t.cfg = cfg;
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(testing.allocator);
    for (0..129) |_| try query.appendSlice(testing.allocator, "中");
    const long = try std.fmt.allocPrint(testing.allocator, "{{\"query\":\"{s}\"}}", .{query.items});
    defer testing.allocator.free(long);
    const rejected = try search(&t, testing.allocator, long);
    defer tools.freeResult(rejected);
    try testing.expect(rejected == .err);
}
