//! One fresh QuickJS runtime per `run`. No state survives between runs;
//! the session log is the only source of truth.

const std = @import("std");
const c = @import("qjs");

/// `JS_UNDEFINED` is a C compound-literal macro that translate-c cannot lower.
const js_undefined: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_UNDEFINED };

pub const Limits = struct {
    memory_bytes: usize = 64 * 1024 * 1024,
    stack_bytes: usize = 1024 * 1024,
};

pub const Outcome = struct {
    ok: bool,
    /// JSON (or string) result on success, error message + stack on failure.
    text: []u8,
};

/// Evaluate `code` in a fresh sandbox. Caller owns `Outcome.text`.
pub fn eval(gpa: std.mem.Allocator, code: []const u8, limits: Limits) !Outcome {
    const rt = c.JS_NewRuntime() orelse return error.OutOfMemory;
    defer c.JS_FreeRuntime(rt);
    c.JS_SetMemoryLimit(rt, limits.memory_bytes);
    c.JS_SetMaxStackSize(rt, limits.stack_bytes);

    const ctx = c.JS_NewContext(rt) orelse return error.OutOfMemory;
    defer c.JS_FreeContext(ctx);

    // JS_Eval needs a NUL-terminated buffer.
    const src = try gpa.dupeSentinel(u8, code, 0);
    defer gpa.free(src);

    const val = c.JS_Eval(ctx, src.ptr, code.len, "<run>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, val);

    if (c.JS_IsException(val)) {
        const exc = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, exc);
        return .{ .ok = false, .text = try describeError(gpa, ctx, exc) };
    }
    return .{ .ok = true, .text = try toJson(gpa, ctx, val) };
}

fn toJson(gpa: std.mem.Allocator, ctx: *c.JSContext, val: c.JSValue) ![]u8 {
    if (c.JS_IsUndefined(val)) return gpa.dupe(u8, "undefined");
    const json = c.JS_JSONStringify(ctx, val, js_undefined, js_undefined);
    defer c.JS_FreeValue(ctx, json);
    if (c.JS_IsException(json)) {
        c.JS_FreeValue(ctx, c.JS_GetException(ctx));
        return toStr(gpa, ctx, val);
    }
    return toStr(gpa, ctx, json);
}

fn describeError(gpa: std.mem.Allocator, ctx: *c.JSContext, exc: c.JSValue) ![]u8 {
    const msg = try toStr(gpa, ctx, exc);
    const stack = c.JS_GetPropertyStr(ctx, exc, "stack");
    defer c.JS_FreeValue(ctx, stack);
    if (c.JS_IsUndefined(stack)) return msg;
    defer gpa.free(msg);
    const st = try toStr(gpa, ctx, stack);
    defer gpa.free(st);
    return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ msg, st });
}

fn toStr(gpa: std.mem.Allocator, ctx: *c.JSContext, val: c.JSValue) ![]u8 {
    var len: usize = 0;
    const p = c.JS_ToCStringLen2(ctx, &len, val, false) orelse return gpa.dupe(u8, "<unprintable>");
    defer c.JS_FreeCString(ctx, p);
    return gpa.dupe(u8, p[0..len]);
}

test "eval returns json" {
    const gpa = std.testing.allocator;
    const r = try eval(gpa, "({a: [1, 2].map(x => x * 2)})", .{});
    defer gpa.free(r.text);
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("{\"a\":[2,4]}", r.text);
}

test "eval reports errors" {
    const gpa = std.testing.allocator;
    const r = try eval(gpa, "throw new TypeError('boom')", .{});
    defer gpa.free(r.text);
    try std.testing.expect(!r.ok);
    try std.testing.expect(std.mem.startsWith(u8, r.text, "TypeError: boom"));
}

test "sandbox has no host capabilities" {
    const gpa = std.testing.allocator;
    const r = try eval(gpa, "[typeof require, typeof process, typeof std, typeof os, typeof fetch]", .{});
    defer gpa.free(r.text);
    try std.testing.expectEqualStrings(
        "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]",
        r.text,
    );
}

test "memory limit is enforced" {
    const gpa = std.testing.allocator;
    const r = try eval(gpa, "let a = []; for (;;) a.push(new Array(1e5).fill(1));", .{ .memory_bytes = 8 * 1024 * 1024 });
    defer gpa.free(r.text);
    try std.testing.expect(!r.ok);
}
