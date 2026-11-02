//! One fresh QuickJS runtime per Run. No state survives between Runs;
//! the Session log is the only source of truth.
//!
//! Scripts see `tools.<name>(args)` (async, backed by `Host.call`) and
//! `console.log`. Top-level `await` works. Host calls currently execute
//! synchronously on the Run's thread, so `Promise.all` over tools is
//! correct but not concurrent.

const std = @import("std");
const c = @import("qjs");

/// `JS_UNDEFINED` is a C compound-literal macro that translate-c cannot lower.
const js_undefined: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_UNDEFINED };

pub const Limits = struct {
    memory_bytes: usize = 64 * 1024 * 1024,
    stack_bytes: usize = 1024 * 1024,
    timeout_ms: i64 = 5 * 60 * 1000,
    max_log_bytes: usize = 64 * 1024,
};

pub const ToolResult = union(enum) {
    /// JSON text of the result.
    ok: []u8,
    err: []u8,
};

pub const Host = struct {
    ctx: *anyopaque,
    names: []const []const u8,
    /// Returned slices are owned by the caller (allocated with `gpa`).
    call: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args_json: []const u8) ToolResult,
};

pub const Outcome = struct {
    ok: bool,
    /// JSON of the completion value on success, error message + stack on failure.
    text: []u8,
    /// Everything the script wrote through `console.*`.
    logs: []u8,

    pub fn deinit(o: Outcome, gpa: std.mem.Allocator) void {
        gpa.free(o.text);
        gpa.free(o.logs);
    }
};

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    host: ?Host,
    logs: std.ArrayList(u8) = .empty,
    max_log: usize,
    log_truncated: bool = false,
    deadline: std.Io.Clock.Timestamp,
    cancel: ?*const std.atomic.Value(bool),
    oom: bool = false,
};

const prelude =
    \\(() => {
    \\  const host = globalThis.__host, log = globalThis.__log, names = JSON.parse(globalThis.__names);
    \\  delete globalThis.__host; delete globalThis.__log; delete globalThis.__names;
    \\  const fmt = (x) => {
    \\    if (typeof x === "string") return x;
    \\    try { const s = JSON.stringify(x); return s === undefined ? String(x) : s; } catch { return String(x); }
    \\  };
    \\  const out = (...a) => log(a.map(fmt).join(" ") + "\n");
    \\  globalThis.console = Object.freeze({ log: out, info: out, warn: out, error: out });
    \\  const call = async (name, args) => {
    \\    const r = JSON.parse(host(name, JSON.stringify(args ?? {})));
    \\    if ("error" in r) throw new Error(name + ": " + r.error);
    \\    return r.ok;
    \\  };
    \\  globalThis.tools = Object.freeze(Object.fromEntries(names.map((n) => [n, (a) => call(n, a)])));
    \\})();
;

/// Evaluate `code` in a fresh sandbox. Caller owns the returned Outcome.
pub fn eval(
    gpa: std.mem.Allocator,
    io: std.Io,
    code: []const u8,
    limits: Limits,
    host: ?Host,
    cancel: ?*const std.atomic.Value(bool),
) !Outcome {
    var st: State = .{
        .gpa = gpa,
        .io = io,
        .host = host,
        .max_log = limits.max_log_bytes,
        .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(limits.timeout_ms), .clock = .awake }),
        .cancel = cancel,
    };
    defer st.logs.deinit(gpa);

    const rt = c.JS_NewRuntime() orelse return error.OutOfMemory;
    defer c.JS_FreeRuntime(rt);
    c.JS_SetMemoryLimit(rt, limits.memory_bytes);
    c.JS_SetMaxStackSize(rt, limits.stack_bytes);
    c.JS_SetInterruptHandler(rt, interrupt, &st);

    const ctx = c.JS_NewContext(rt) orelse return error.OutOfMemory;
    defer c.JS_FreeContext(ctx);
    c.JS_SetContextOpaque(ctx, &st);

    try install(gpa, ctx, host);
    {
        const v = c.JS_Eval(ctx, prelude, prelude.len, "<prelude>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(ctx, v);
        if (c.JS_IsException(v)) return error.PreludeFailed;
    }

    // JS_Eval needs a NUL-terminated buffer.
    const src = try gpa.dupeSentinel(u8, code, 0);
    defer gpa.free(src);

    const promise = c.JS_Eval(ctx, src.ptr, code.len, "<run>", c.JS_EVAL_TYPE_GLOBAL | c.JS_EVAL_FLAG_ASYNC);
    defer c.JS_FreeValue(ctx, promise);

    var ok = false;
    var text: []u8 = undefined;
    if (c.JS_IsException(promise)) {
        text = try takeException(gpa, ctx);
    } else {
        var pctx: ?*c.JSContext = null;
        while (c.JS_ExecutePendingJob(rt, &pctx) > 0) {}
        switch (c.JS_PromiseState(ctx, promise)) {
            c.JS_PROMISE_FULFILLED => {
                const res = c.JS_PromiseResult(ctx, promise);
                defer c.JS_FreeValue(ctx, res);
                // Async global eval resolves to `{ value: <completion value> }`.
                const value = c.JS_GetPropertyStr(ctx, res, "value");
                defer c.JS_FreeValue(ctx, value);
                text = try toJson(gpa, ctx, value);
                ok = true;
            },
            c.JS_PROMISE_REJECTED => {
                const err = c.JS_PromiseResult(ctx, promise);
                defer c.JS_FreeValue(ctx, err);
                text = try describeError(gpa, ctx, err);
            },
            else => text = try gpa.dupe(u8, "Error: script is still awaiting something that can never settle"),
        }
    }
    errdefer gpa.free(text);

    if (!ok and isInterrupted(&st)) {
        gpa.free(text);
        text = try gpa.dupe(u8, if (st.cancel != null and st.cancel.?.load(.acquire)) "Error: run canceled" else "Error: run timed out");
    }
    if (st.log_truncated) try st.logs.appendSlice(gpa, "\n[console output truncated]\n");
    return .{ .ok = ok, .text = text, .logs = try st.logs.toOwnedSlice(gpa) };
}

fn install(gpa: std.mem.Allocator, ctx: *c.JSContext, host: ?Host) !void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    _ = c.JS_SetPropertyStr(ctx, global, "__log", c.JS_NewCFunction2(ctx, nativeLog, "__log", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "__host", c.JS_NewCFunction2(ctx, nativeHost, "__host", 2, c.JS_CFUNC_generic, 0));
    const names = try std.json.Stringify.valueAlloc(gpa, if (host) |h| h.names else &.{}, .{});
    defer gpa.free(names);
    _ = c.JS_SetPropertyStr(ctx, global, "__names", c.JS_NewStringLen(ctx, names.ptr, names.len));
}

fn state(ctx: ?*c.JSContext) *State {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
}

fn isInterrupted(st: *State) bool {
    if (st.cancel) |flag| if (flag.load(.acquire)) return true;
    return std.Io.Clock.Timestamp.now(st.io, .awake).compare(.gte, st.deadline);
}

fn interrupt(_: ?*c.JSContext, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(isInterrupted(@ptrCast(@alignCast(opaque_ptr.?))));
}

fn nativeLog(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const st = state(ctx);
    if (argc < 1) return js_undefined;
    var len: usize = 0;
    const p = c.JS_ToCStringLen2(ctx, &len, argv[0], false) orelse return js_undefined;
    defer c.JS_FreeCString(ctx, p);
    const room = st.max_log -| st.logs.items.len;
    if (len > room) st.log_truncated = true;
    st.logs.appendSlice(st.gpa, p[0..@min(len, room)]) catch {
        st.oom = true;
    };
    return js_undefined;
}

/// `__host(name, argsJson)` → `{"ok": <json>}` or `{"error": "<msg>"}` as a string.
fn nativeHost(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const st = state(ctx);
    const reply = hostReply(st, ctx, argc, argv) catch {
        const oom = "{\"error\":\"out of memory\"}";
        return c.JS_NewStringLen(ctx, oom, oom.len);
    };
    defer st.gpa.free(reply);
    return c.JS_NewStringLen(ctx, reply.ptr, reply.len);
}

fn hostReply(st: *State, ctx: ?*c.JSContext, argc: c_int, argv: [*c]c.JSValue) ![]u8 {
    const gpa = st.gpa;
    const host = st.host orelse return std.json.Stringify.valueAlloc(gpa, .{ .@"error" = "no tools available" }, .{});
    if (argc < 2) return std.json.Stringify.valueAlloc(gpa, .{ .@"error" = "bad host call" }, .{});

    var nlen: usize = 0;
    const name = c.JS_ToCStringLen2(ctx, &nlen, argv[0], false) orelse return error.OutOfMemory;
    defer c.JS_FreeCString(ctx, name);
    var alen: usize = 0;
    const args = c.JS_ToCStringLen2(ctx, &alen, argv[1], false) orelse return error.OutOfMemory;
    defer c.JS_FreeCString(ctx, args);

    switch (host.call(host.ctx, gpa, name[0..nlen], args[0..alen])) {
        .ok => |json| {
            defer gpa.free(json);
            return std.fmt.allocPrint(gpa, "{{\"ok\":{s}}}", .{json});
        },
        .err => |msg| {
            defer gpa.free(msg);
            return std.json.Stringify.valueAlloc(gpa, .{ .@"error" = msg }, .{});
        },
    }
}

fn takeException(gpa: std.mem.Allocator, ctx: *c.JSContext) ![]u8 {
    const exc = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exc);
    return describeError(gpa, ctx, exc);
}

fn toJson(gpa: std.mem.Allocator, ctx: *c.JSContext, val: c.JSValue) ![]u8 {
    if (c.JS_IsUndefined(val)) return gpa.dupe(u8, "undefined");
    const json = c.JS_JSONStringify(ctx, val, js_undefined, js_undefined);
    defer c.JS_FreeValue(ctx, json);
    if (c.JS_IsException(json) or c.JS_IsUndefined(json)) {
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
    return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ msg, std.mem.trimEnd(u8, st, "\n") });
}

fn toStr(gpa: std.mem.Allocator, ctx: *c.JSContext, val: c.JSValue) ![]u8 {
    var len: usize = 0;
    const p = c.JS_ToCStringLen2(ctx, &len, val, false) orelse return gpa.dupe(u8, "<unprintable>");
    defer c.JS_FreeCString(ctx, p);
    return gpa.dupe(u8, p[0..len]);
}

// ---- tests ----

const testing = std.testing;

fn run(code: []const u8, limits: Limits, host: ?Host) !Outcome {
    return eval(testing.allocator, testing.io, code, limits, host, null);
}

test "completion value is returned as json" {
    const r = try run("const x = [1, 2].map(v => v * 2); ({ a: x })", .{}, null);
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok);
    try testing.expectEqualStrings("{\"a\":[2,4]}", r.text);
}

test "top-level await and console capture" {
    const r = try run("console.log('hi', {n: 1}); await Promise.resolve(7)", .{}, null);
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok);
    try testing.expectEqualStrings("7", r.text);
    try testing.expectEqualStrings("hi {\"n\":1}\n", r.logs);
}

test "errors are reported, sync and async" {
    const a = try run("throw new TypeError('boom')", .{}, null);
    defer a.deinit(testing.allocator);
    try testing.expect(!a.ok);
    try testing.expect(std.mem.startsWith(u8, a.text, "TypeError: boom"));

    const b = try run("await Promise.reject(new Error('later'))", .{}, null);
    defer b.deinit(testing.allocator);
    try testing.expect(!b.ok);
    try testing.expect(std.mem.startsWith(u8, b.text, "Error: later"));
}

test "sandbox has no host capabilities" {
    const r = try run("[typeof require, typeof process, typeof std, typeof os, typeof fetch, typeof __host]", .{}, null);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]",
        r.text,
    );
}

test "memory limit is enforced" {
    const r = try run("let a = []; for (;;) a.push(new Array(1e5).fill(1));", .{ .memory_bytes = 8 * 1024 * 1024 }, null);
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok);
}

test "timeout interrupts an infinite loop" {
    const r = try run("for (;;) {}", .{ .timeout_ms = 50 }, null);
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok);
    try testing.expectEqualStrings("Error: run timed out", r.text);
}

const EchoHost = struct {
    fn call(_: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args: []const u8) ToolResult {
        if (std.mem.eql(u8, name, "fail")) return .{ .err = gpa.dupe(u8, "nope") catch unreachable };
        return .{ .ok = std.fmt.allocPrint(gpa, "{{\"tool\":\"{s}\",\"args\":{s}}}", .{ name, args }) catch unreachable };
    }
};

test "tools route through the host, errors become exceptions" {
    var dummy: u8 = 0;
    const host: Host = .{ .ctx = &dummy, .names = &.{ "echo", "fail" }, .call = EchoHost.call };
    const r = try run(
        \\const [a, b] = await Promise.all([tools.echo({x: 1}), tools.echo()]);
        \\let msg = "";
        \\try { await tools.fail({}); } catch (e) { msg = e.message; }
        \\({ a, b, msg, keys: Object.keys(tools) })
    , .{}, host);
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok);
    try testing.expectEqualStrings(
        "{\"a\":{\"tool\":\"echo\",\"args\":{\"x\":1}},\"b\":{\"tool\":\"echo\",\"args\":{}},\"msg\":\"fail: nope\",\"keys\":[\"echo\",\"fail\"]}",
        r.text,
    );
}
