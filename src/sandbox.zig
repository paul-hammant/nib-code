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
    /// JSON.
    ok: []u8,
    err: []u8,
};

pub const Host = struct {
    ctx: *anyopaque,
    names: []const []const u8,
    /// Returned slices are allocated with `gpa` and owned by the caller.
    cancel: ?*std.atomic.Value(bool) = null,
    call: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args_json: []const u8) ToolResult,
    poll: ?*const fn (ctx: *anyopaque) anyerror!void = null,
};

pub const Outcome = struct {
    ok: bool,
    /// Completion value as JSON when `ok`, otherwise error message and stack.
    text: []u8,
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
    js_remaining_ns: i96,
    js_started: ?std.Io.Clock.Timestamp = null,
    cancel: ?*const std.atomic.Value(bool),
    oom: bool = false,
    calls: std.ArrayList(?*Call) = .empty,
    mutex: std.Io.Mutex = .init,
    completed: std.Io.Condition = .init,
    ready: ?*Call = null,
    ready_tail: ?*Call = null,

    const Call = struct {
        state: *State,
        index: usize,
        name: []u8,
        args: []u8,
        settle: [2]c.JSValue,
        thread: ?std.Thread = null,
        result: ?ToolResult = null,
        next: ?*Call = null,

        fn deinit(call: *Call, ctx: *c.JSContext) void {
            const gpa = call.state.gpa;
            if (call.result) |result| switch (result) {
                inline else => |bytes| gpa.free(bytes),
            };
            for (call.settle) |value| c.JS_FreeValue(ctx, value);
            gpa.free(call.name);
            gpa.free(call.args);
            gpa.destroy(call);
        }

        fn work(call: *Call) void {
            const st = call.state;
            const h = st.host.?;
            const result = h.call(h.ctx, st.gpa, call.name, call.args);
            st.mutex.lockUncancelable(st.io);
            defer st.mutex.unlock(st.io);
            call.result = result;
            if (st.ready_tail) |tail| tail.next = call else st.ready = call;
            st.ready_tail = call;
            st.completed.signal(st.io);
        }
    };

    fn beginJs(st: *State) void {
        std.debug.assert(st.js_started == null);
        st.js_started = .now(st.io, .awake);
    }

    fn endJs(st: *State) void {
        const started = st.js_started.?;
        st.js_remaining_ns -= started.durationTo(.now(st.io, .awake)).raw.toNanoseconds();
        st.js_started = null;
    }

    fn stop(st: *State) void {
        if (st.host) |h| if (h.cancel) |flag| flag.store(true, .release);
    }

    fn deinit(st: *State, ctx: *c.JSContext) void {
        st.stop();
        for (st.calls.items) |item| if (item) |call| if (call.thread) |thread| thread.join();
        for (st.calls.items) |item| if (item) |call| call.deinit(ctx);
        st.calls.deinit(st.gpa);
    }

    fn jobs(st: *State, ctx: *c.JSContext, rt: *c.JSRuntime, promise: c.JSValue) !void {
        var active: usize = 0;
        var next: usize = 0;
        while (true) {
            if (st.host) |h| if (h.poll) |poll| try poll(h.ctx);
            if (active == 0 and next == st.calls.items.len) {
                st.calls.clearRetainingCapacity();
                next = 0;
            }
            if (isInterrupted(st) or c.JS_PromiseState(ctx, promise) == c.JS_PROMISE_REJECTED) {
                st.stop();
                return;
            }
            var pctx: ?*c.JSContext = null;
            st.beginJs();
            const n = c.JS_ExecutePendingJob(rt, &pctx);
            st.endJs();
            if (n < 0) return;
            if (n > 0) continue;
            st.mutex.lockUncancelable(st.io);
            var ready = st.ready;
            st.ready = null;
            st.ready_tail = null;
            st.mutex.unlock(st.io);
            while (ready) |call| {
                ready = call.next;
                call.thread.?.join();
                call.thread = null;
                active -= 1;
                st.beginJs();
                defer st.endJs();
                const result = call.result.?;
                const value = switch (result) {
                    .ok => |json| blk: {
                        // QuickJS requires buf[len] == 0 even with an explicit length.
                        const source = try st.gpa.dupeSentinel(u8, json, 0);
                        defer st.gpa.free(source);
                        break :blk c.JS_ParseJSON(ctx, source.ptr, source.len, "<tool>");
                    },
                    .err => |msg| blk: {
                        const err = c.JS_NewError(ctx);
                        _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
                        break :blk err;
                    },
                };
                const rejected = result == .err or c.JS_IsException(value);
                const arg = if (c.JS_IsException(value)) c.JS_GetException(ctx) else value;
                const r = c.JS_Call(ctx, call.settle[@intFromBool(rejected)], js_undefined, 1, @constCast(&arg));
                c.JS_FreeValue(ctx, r);
                c.JS_FreeValue(ctx, arg);
                st.calls.items[call.index] = null;
                call.deinit(ctx);
            }
            if (c.JS_IsJobPending(rt)) continue;
            while (next < st.calls.items.len and active < 8) : (next += 1) {
                const call = st.calls.items[next].?;
                call.thread = try std.Thread.spawn(.{}, Call.work, .{call});
                active += 1;
            }
            if (active == 0) return;
            st.mutex.lockUncancelable(st.io);
            if (st.ready == null) st.completed.waitTimeout(st.io, &st.mutex, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
            st.mutex.unlock(st.io);
        }
    }
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
    \\    let r;
    \\    try { r = await host(name, JSON.stringify(args ?? {})); } catch (e) { throw new Error(name + ": " + e.message); }
    \\    return r;
    \\  };
    \\  globalThis.tools = Object.freeze(Object.fromEntries(names.map((n) => [n, (a) => call(n, a)])));
    \\})();
;

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
        .js_remaining_ns = std.Io.Duration.fromMilliseconds(limits.timeout_ms).toNanoseconds(),
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
    defer st.deinit(ctx);
    c.JS_SetContextOpaque(ctx, &st);

    try install(gpa, ctx, host);
    {
        const v = c.JS_Eval(ctx, prelude, prelude.len, "<prelude>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(ctx, v);
        if (c.JS_IsException(v)) return error.PreludeFailed;
    }

    const src = try gpa.dupeSentinel(u8, code, 0);
    defer gpa.free(src);

    st.beginJs();
    const promise = c.JS_Eval(ctx, src.ptr, code.len, "<run>", c.JS_EVAL_TYPE_GLOBAL | c.JS_EVAL_FLAG_ASYNC);
    st.endJs();
    defer c.JS_FreeValue(ctx, promise);

    var ok = false;
    var text: []u8 = undefined;
    if (c.JS_IsException(promise)) {
        st.beginJs();
        defer st.endJs();
        text = try takeException(gpa, ctx);
    } else {
        try st.jobs(ctx, rt, promise);
        st.beginJs();
        defer st.endJs();
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

    if (isInterrupted(&st)) {
        ok = false;
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
    const elapsed = if (st.js_started) |started| started.durationTo(.now(st.io, .awake)).raw.toNanoseconds() else 0;
    return elapsed >= st.js_remaining_ns;
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

fn nativeHost(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    return enqueue(state(ctx), ctx.?, argc, argv) catch c.JS_ThrowOutOfMemory(ctx);
}

fn enqueue(st: *State, ctx: *c.JSContext, argc: c_int, argv: [*c]c.JSValue) !c.JSValue {
    if (st.host == null or argc < 2) return error.InvalidHostCall;
    const call = try st.gpa.create(State.Call);
    errdefer st.gpa.destroy(call);
    const name = try toStr(st.gpa, ctx, argv[0]);
    errdefer st.gpa.free(name);
    const args = try toStr(st.gpa, ctx, argv[1]);
    errdefer st.gpa.free(args);
    var settle: [2]c.JSValue = undefined;
    const promise = c.JS_NewPromiseCapability(ctx, &settle);
    if (c.JS_IsException(promise)) return error.OutOfMemory;
    errdefer {
        c.JS_FreeValue(ctx, promise);
        for (settle) |v| c.JS_FreeValue(ctx, v);
    }
    call.* = .{ .state = st, .index = st.calls.items.len, .name = name, .args = args, .settle = settle };
    try st.calls.append(st.gpa, call);
    return promise;
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

test "timeout also covers JS invoked by result and error conversion" {
    for ([_][]const u8{
        "({ get x() { for (;;) {} } })",
        "throw { toString() { for (;;) {} } }",
        "throw { toString() { return 'bad' }, get stack() { for (;;) {} } }",
    }) |code| {
        const r = try run(code, .{ .timeout_ms = 50 }, null);
        defer r.deinit(testing.allocator);
        try testing.expect(!r.ok);
        try testing.expectEqualStrings("Error: run timed out", r.text);
    }
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

test "tool concurrency is bounded while excess calls queue" {
    const Slow = struct {
        active: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),
        fn call(ctx: *anyopaque, gpa: std.mem.Allocator, _: []const u8, _: []const u8) ToolResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            defer _ = self.active.fetchSub(1, .acq_rel);
            _ = self.peak.fetchMax(active, .monotonic);
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, testing.io) catch unreachable;
            return .{ .ok = gpa.dupe(u8, "1") catch unreachable };
        }
    };
    var slow: Slow = .{};
    const result = try run("(await Promise.all(Array.from({length: 24}, () => tools.slow()))).length", .{}, .{ .ctx = &slow, .names = &.{"slow"}, .call = Slow.call });
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("24", result.text);
    try testing.expect(slow.peak.load(.monotonic) > 1 and slow.peak.load(.monotonic) <= 8);
    try testing.expectEqual(0, slow.active.load(.monotonic));
}
