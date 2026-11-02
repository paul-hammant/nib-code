const std = @import("std");
const html = @import("html.zig");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;

pub fn fetch(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const a = std.json.parseFromSlice(Options, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ url: string, raw?: boolean, timeout_ms?: number }}", .{});
    defer a.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var content_type: []const u8 = "";
    const page = get(t.io, gpa, arena.allocator(), t.environ, a.value, &t.cancel, &content_type) catch |err| return switch (err) {
        error.Canceled => fail(gpa, "canceled", .{}),
        error.Timeout => fail(gpa, "timed out after {d} ms", .{a.value.timeout_ms}),
        error.BinaryContent => fail(gpa, "binary content ({s}); download it with bash if needed", .{content_type}),
        error.ResponseTooLarge => fail(gpa, "response exceeds 5 MB", .{}),
        else => fail(gpa, "{s}: {s}", .{ a.value.url, @errorName(err) }),
    };
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, page, .{}) };
}

pub const Options = struct {
    url: []const u8,
    raw: bool = false,
    timeout_ms: u64 = 30_000,
};

pub const Page = struct {
    /// After redirects.
    url: []const u8,
    status: u16,
    content_type: []const u8,
    text: []const u8,
    truncated: bool,
};

const max_body = 5 * 1024 * 1024;
const max_text = 1024 * 1024;
const max_redirects = 5;
const accept = "text/markdown, text/plain;q=0.9, text/html;q=0.8, */*;q=0.5";

/// GET `options.url`, following redirects. The result is allocated with `a`, which only one
/// thread uses at a time; `gpa` must be thread-safe. On error.BinaryContent `content_type` is set.
pub fn get(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, environ: ?*const std.process.Environ.Map, options: Options, cancel: *const std.atomic.Value(bool), content_type: *[]const u8) !Page {
    if (!std.mem.startsWith(u8, options.url, "http://") and !std.mem.startsWith(u8, options.url, "https://")) return error.UnsupportedUrlScheme;
    const Stop = enum { canceled, timed_out };
    const U = union(enum) { page: anyerror!Page, stop: Stop };
    var buffer: [2]U = undefined;
    var select = std.Io.Select(U).init(io, &buffer);
    // Blocking reads only return once canceled, so the request runs as its own task.
    defer select.cancelDiscard();
    try select.concurrent(.page, request, .{ io, gpa, a, environ, options, content_type });
    try select.concurrent(.stop, struct {
        fn watch(w_io: std.Io, flag: *const std.atomic.Value(bool), ms: u64) Stop {
            var waited: u64 = 0;
            while (waited < ms) : (waited += 50) {
                if (flag.load(.acquire)) return .canceled;
                std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(50), .clock = .awake }, w_io) catch return .canceled;
            }
            return .timed_out;
        }
    }.watch, .{ io, cancel, options.timeout_ms });
    return switch (try select.await()) {
        .page => |page| page,
        .stop => |stop| if (stop == .canceled) error.Canceled else error.Timeout,
    };
}

fn request(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, environ: ?*const std.process.Environ.Map, options: Options, content_type: *[]const u8) anyerror!Page {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    if (environ) |env| try client.initDefaultProxies(a, env);
    var req = try client.request(.GET, try std.Uri.parse(options.url), .{
        .redirect_behavior = @fromBackingInt(@intCast(max_redirects)),
        .headers = .{ .user_agent = .{ .override = "Mozilla/5.0 (compatible; nib)" } },
        .extra_headers = &.{.{ .name = "accept", .value = accept }},
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    content_type.* = try a.dupe(u8, response.head.content_type orelse "");
    const url = try std.fmt.allocPrint(a, "{f}", .{req.uri});

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try a.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try a.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, decompress_buffer);
    const body = reader.allocRemaining(a, .limited(max_body)) catch |err| return switch (err) {
        error.ReadFailed => response.bodyErr() orelse err,
        error.StreamTooLong => error.ResponseTooLarge,
        else => err,
    };
    const text = try render(a, body, content_type.*, url, options.raw);
    return .{
        .url = url,
        .status = @backingInt(response.head.status),
        .content_type = content_type.*,
        .text = cap(text),
        .truncated = text.len > max_text,
    };
}

fn render(a: std.mem.Allocator, body: []const u8, content_type: []const u8, url: []const u8, raw: bool) ![]const u8 {
    const media = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " ");
    const is_html = std.ascii.eqlIgnoreCase(media, "text/html") or std.ascii.eqlIgnoreCase(media, "application/xhtml+xml") or
        (media.len == 0 and std.ascii.startsWithIgnoreCase(std.mem.trimStart(u8, body, " \t\r\n"), "<!doctype html"));
    if (std.mem.indexOfScalar(u8, body[0..@min(body.len, 4096)], 0) != null or !std.unicode.utf8ValidateSlice(body)) return error.BinaryContent;
    if (is_html and !raw) return html.toMarkdown(a, body, url);
    return body;
}

fn cap(text: []const u8) []const u8 {
    if (text.len <= max_text) return text;
    var end: usize = max_text;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;

test "render converts HTML, passes text through and rejects binary" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("# Hi\n\n[next](https://x.dev/b)", try render(a, "<h1>Hi</h1><a href=b>next</a>", "text/html; charset=utf-8", "https://x.dev/a", false));
    try testing.expectEqualStrings("<h1>Hi</h1>", try render(a, "<h1>Hi</h1>", "text/html", "https://x.dev/", true));
    try testing.expectEqualStrings("# Doc\n", try render(a, "# Doc\n", "text/markdown", "https://x.dev/", false));
    try testing.expectEqualStrings("# Doc", try render(a, "<!DOCTYPE html><h1>Doc</h1>", "", "https://x.dev/", false));
    try testing.expectError(error.BinaryContent, render(a, "PNG\x00\x01", "image/png", "https://x.dev/", false));
    const long = try a.alloc(u8, max_text + 10);
    @memset(long, 'x');
    try testing.expectEqualStrings(long[0..max_text], cap(long));
}

test "fetch text cap preserves UTF-8 and adds no marker" {
    const text = try testing.allocator.alloc(u8, max_text + 5);
    defer testing.allocator.free(text);
    @memset(text, 'x');
    try testing.expectEqual(max_text, cap(text[0..max_text]).len);
    @memcpy(text[max_text - 1 ..], "中文");
    const capped = cap(text);
    try testing.expectEqual(max_text - 1, capped.len);
    try testing.expect(std.unicode.utf8ValidateSlice(capped));
    try testing.expectEqualStrings("short", cap("short"));
}

test "unsupported schemes are refused before any request" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var content_type: []const u8 = "";
    try testing.expectError(error.UnsupportedUrlScheme, get(testing.io, testing.allocator, testing.allocator, null, .{ .url = "file:///etc/passwd" }, &cancel, &content_type));
}
