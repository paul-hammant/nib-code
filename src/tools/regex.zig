const std = @import("std");
const c = @import("qjs");

extern fn lre_compile(plen: *c_int, error_msg: [*]u8, error_msg_size: c_int, buf: [*]const u8, buf_len: usize, re_flags: c_int, opaque_ptr: ?*anyopaque) ?[*]u8;
extern fn lre_exec(capture: [*]?[*]u8, bc_buf: [*]const u8, cbuf: [*]const u8, cindex: c_int, clen: c_int, cbuf_type: c_int, opaque_ptr: ?*anyopaque) c_int;
extern fn lre_get_capture_count(bc_buf: [*]const u8) c_int;

const flag_ignore_case = 1 << 1;
const flag_multiline = 1 << 2;

/// libregexp allocates, checks the stack and polls for interruption through a JSContext,
/// whose runtime records the creating thread's stack: create, use and destroy on one thread.
pub const Engine = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    cancel: ?*const std.atomic.Value(bool),

    /// In place: the interrupt handler keeps a pointer to `e`.
    pub fn init(e: *Engine, cancel: ?*const std.atomic.Value(bool)) !void {
        const rt = c.JS_NewRuntime() orelse return error.OutOfMemory;
        errdefer c.JS_FreeRuntime(rt);
        e.* = .{ .rt = rt, .ctx = c.JS_NewContextRaw(rt) orelse return error.OutOfMemory, .cancel = cancel };
        c.JS_SetInterruptHandler(rt, interrupt, e);
    }

    pub fn deinit(e: *Engine) void {
        c.JS_FreeContext(e.ctx);
        c.JS_FreeRuntime(e.rt);
    }

    fn interrupt(_: ?*c.JSContext, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
        const e: *Engine = @ptrCast(@alignCast(opaque_ptr.?));
        return @intFromBool(if (e.cancel) |flag| flag.load(.acquire) else false);
    }
};

/// JavaScript RegExp syntax, multiline so `^`/`$` work per line. Bytecode is read-only after
/// compilation and may be executed from any thread's Engine.
pub const Regex = struct {
    bytecode: [*]u8,
    captures: usize,

    /// libregexp's parser peeks at the byte after the pattern, hence the sentinel.
    pub fn compile(e: *Engine, pattern: [:0]const u8, ignore_case: bool, message: *[128]u8) !Regex {
        var len: c_int = 0;
        const flags: c_int = if (ignore_case) flag_multiline | flag_ignore_case else flag_multiline;
        @memset(message, 0);
        const bc = lre_compile(&len, message, message.len, pattern.ptr, pattern.len, flags, e.ctx) orelse return error.InvalidPattern;
        return .{ .bytecode = bc, .captures = @intCast(lre_get_capture_count(bc)) };
    }

    /// With the Engine that compiled it.
    pub fn deinit(r: Regex, e: *Engine) void {
        c.js_free_rt(e.rt, r.bytecode);
    }

    /// Start of the first match at or after `from`. `u8` text is matched as Latin-1, `u16` as UTF-16.
    pub fn find(r: Regex, e: *Engine, comptime T: type, text: []const T, from: usize, scratch: []?[*]u8) !?usize {
        std.debug.assert(scratch.len >= r.captures * 2);
        if (from > text.len) return null;
        const bytes: [*]const u8 = @ptrCast(text.ptr);
        const ret = lre_exec(scratch.ptr, r.bytecode, bytes, @intCast(from), @intCast(text.len), if (T == u8) 0 else 1, e.ctx);
        return switch (ret) {
            1 => (@intFromPtr(scratch[0].?) - @intFromPtr(bytes)) / @sizeOf(T),
            0 => null,
            -2 => error.Canceled,
            else => error.OutOfMemory,
        };
    }
};

const testing = std.testing;

test "JS regex over Latin-1 and UTF-16 text, with per-line anchors" {
    var e: Engine = undefined;
    try e.init(null);
    defer e.deinit();
    var message: [128]u8 = undefined;
    const r = try Regex.compile(&e, "^fn \\w+\\(", false, &message);
    defer r.deinit(&e);
    var scratch: [8]?[*]u8 = undefined;
    const text = "const x = 1;\nfn main() {}\n";
    try testing.expectEqual(@as(?usize, 13), try r.find(&e, u8, text, 0, &scratch));
    try testing.expectEqual(@as(?usize, null), try r.find(&e, u8, text, 14, &scratch));

    const wide = try std.unicode.utf8ToUtf16LeAlloc(testing.allocator, "注释\n函数 fn 名字(");
    defer testing.allocator.free(wide);
    const zh = try Regex.compile(&e, "函数.*名字", true, &message);
    defer zh.deinit(&e);
    try testing.expectEqual(@as(?usize, 3), try zh.find(&e, u16, wide, 0, &scratch));

    try testing.expectError(error.InvalidPattern, Regex.compile(&e, "(unclosed", false, &message));
    try testing.expect(std.mem.sliceTo(&message, 0).len > 0);
}

test "a set cancel flag interrupts catastrophic backtracking" {
    var cancel: std.atomic.Value(bool) = .init(true);
    var e: Engine = undefined;
    try e.init(&cancel);
    defer e.deinit();
    var message: [128]u8 = undefined;
    const r = try Regex.compile(&e, "(a+)+$", false, &message);
    defer r.deinit(&e);
    var scratch: [8]?[*]u8 = undefined;
    try testing.expectError(error.Canceled, r.find(&e, u8, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab", 0, &scratch));
}
