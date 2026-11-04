const std = @import("std");
const c = @import("qjs");
const console = @import("sandbox/console.zig");
const run_timing = @import("sandbox/timing.zig");
pub const RunTiming = run_timing.Run;
pub const tool_concurrency = 8;

pub const Recorder = @import("sandbox/record.zig").Recorder;
pub const replay = @import("sandbox/replay.zig");

// Callbacks run only on the eval thread; contexts and pending-index slices are borrowed.
pub const Virtual = struct {
    ctx: *anyopaque,
    create: *const fn (*anyopaque, usize, []const u8, []const u8) void,
    select: *const fn (*anyopaque, []const usize) ?usize,
    result: *const fn (*anyopaque, std.mem.Allocator, usize) anyerror!VirtualResult,
    stopped: *const fn (*anyopaque) bool,
    start_ms_epoch: i64,
    uses_time: bool = false,
    uses_random: bool = false,
};

pub const VirtualResult = struct {
    result: ToolResult,
    string_result: bool = false,
};

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

// Tool workers publish session-owned IDs without changing the JavaScript return value.
pub threadlocal var tool_identity: struct { id: ?[]const u8 = null, background: bool = false } = .{};

pub const Host = struct {
    ctx: *anyopaque,
    names: []const []const u8,
    /// Returned slices are allocated with `gpa` and owned by the caller.
    cancel: ?*std.atomic.Value(bool) = null,
    call: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args_json: []const u8) ToolResult,
    poll: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    /// Runs before enqueue; rejection messages use `gpa` and are caller-owned.
    admit: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) anyerror!?[]u8 = null,
    /// Borrowed until eval returns; inspect entries or change started/run_index only between evals.
    timing: ?*RunTiming = null,
    record: ?*Recorder = null,
    virtual: ?*Virtual = null,
};

pub const LogEntry = console.Entry;
pub const max_log_entries = console.max_entries;

pub const Outcome = struct {
    ok: bool,
    /// Completion value as JSON when `ok`, otherwise error message and stack.
    text: []u8,
    logs: []u8,
    log_entries: []const LogEntry = &.{},
    log_bytes: usize = 0,
    log_head_bytes: usize = 0,
    log_tail_start: usize = 0,
    log_truncated: bool = false,
    tool_bytes: u64 = 0,

    pub fn deinit(o: Outcome, gpa: std.mem.Allocator) void {
        gpa.free(o.text);
        gpa.free(o.logs);
        gpa.free(o.log_entries);
    }
};

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    host: ?Host,
    logs: console.Capture,
    js_remaining_ns: i96,
    js_started: ?std.Io.Clock.Timestamp = null,
    cancel: ?*const std.atomic.Value(bool),
    oom: bool = false,
    calls: std.ArrayList(?*Call) = .empty,
    mutex: std.Io.Mutex = .init,
    completed: std.Io.Condition = .init,
    ready: ?*Call = null,
    ready_tail: ?*Call = null,
    creation_index: usize = 0,
    tool_bytes: u64 = 0,

    fn recordResult(st: *State, index: ?usize, bytes: usize) void {
        st.tool_bytes += bytes;
        if (st.host.?.timing) |t| t.result(index, bytes);
    }

    const Call = struct {
        state: *State,
        index: usize,
        creation_index: usize,
        string_result: bool = false,
        name: []u8,
        args: []u8,
        settle: [2]c.JSValue,
        thread: ?std.Thread = null,
        result: ?ToolResult = null,
        timing_index: ?usize = null,
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
            const timing = if (call.timing_index != null) h.timing else null;
            const start_ms = if (timing) |t| t.elapsed() else 0;
            tool_identity = .{};
            const result = h.call(h.ctx, st.gpa, call.name, call.args);
            const end_ms = if (timing) |t| t.elapsed() else 0;
            st.mutex.lockUncancelable(st.io);
            defer st.mutex.unlock(st.io);
            if (timing) |t| {
                t.complete(call.timing_index.?, start_ms, end_ms, result == .ok);
                if (tool_identity.id) |id| {
                    t.entries[call.timing_index.?].id = id;
                    t.entries[call.timing_index.?].background = tool_identity.background;
                }
            }
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

    fn deliver(st: *State, ctx: *c.JSContext, call: *Call) !void {
        const result = call.result.?;
        if (st.host.?.record) |recorder| recorder.settle(call.creation_index, call.name, call.args, result);
        st.recordResult(call.timing_index, switch (result) {
            inline else => |bytes| bytes.len,
        });
        st.beginJs();
        defer st.endJs();
        const value = switch (result) {
            .ok => |json| blk: {
                if (call.string_result) break :blk c.JS_NewStringLen(ctx, json.ptr, json.len);
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

    fn jobs(st: *State, ctx: *c.JSContext, rt: *c.JSRuntime, promise: c.JSValue) !void {
        var active: usize = 0;
        var next: usize = 0;
        while (true) {
            if (st.host) |h| if (h.poll) |poll| try poll(h.ctx);
            if (active == 0 and next == st.calls.items.len) {
                st.calls.clearRetainingCapacity();
                next = 0;
            }
            if (virtualStopped(st)) return;
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
            if (st.host) |h| if (h.virtual) |v| {
                if (v.stopped(v.ctx)) return;
                var pending: std.ArrayList(usize) = .empty;
                defer pending.deinit(st.gpa);
                for (st.calls.items) |item| if (item) |call| try pending.append(st.gpa, call.creation_index);
                if (pending.items.len == 0) return;
                const selected = v.select(v.ctx, pending.items) orelse return;
                for (st.calls.items) |item| {
                    const call = item orelse continue;
                    if (call.creation_index != selected) continue;
                    const result = try v.result(v.ctx, st.gpa, selected);
                    call.result = result.result;
                    call.string_result = result.string_result;
                    try st.deliver(ctx, call);
                    break;
                }
                continue;
            };
            st.mutex.lockUncancelable(st.io);
            const ready = st.ready;
            if (ready) |call| st.ready = call.next;
            if (st.ready == null) st.ready_tail = null;
            st.mutex.unlock(st.io);
            if (ready) |call| {
                if (call.thread) |thread| thread.join();
                call.thread = null;
                active -= 1;
                try st.deliver(ctx, call);
            }
            if (ready != null or c.JS_IsJobPending(rt)) continue;
            while (next < st.calls.items.len and active < tool_concurrency) : (next += 1) {
                const call = st.calls.items[next].?;
                if (call.result != null) {
                    st.mutex.lockUncancelable(st.io);
                    if (st.ready_tail) |tail| tail.next = call else st.ready = call;
                    st.ready_tail = call;
                    st.mutex.unlock(st.io);
                    active += 1;
                    continue;
                }
                const timing = st.host.?.timing;
                if (timing) |t| call.timing_index = t.reserve(call.name);
                call.thread = std.Thread.spawn(.{}, Call.work, .{call}) catch |err| {
                    if (timing) |t| t.undoReservation(call.timing_index, call.name);
                    return err;
                };
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
    \\    if (name === "grep" && args?.pattern instanceof RegExp) {
    \\      const re = args.pattern;
    \\      args = { ...args, pattern: re.source, ...(re.ignoreCase && !Object.hasOwn(args, "ignore_case") ? { ignore_case: true } : {}) };
    \\    }
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
        .logs = .{ .limit = limits.max_log_bytes },
        .js_remaining_ns = std.Io.Duration.fromMilliseconds(limits.timeout_ms).toNanoseconds(),
        .cancel = cancel,
    };
    defer st.logs.deinit(gpa);
    defer if (host) |h| if (h.record) |recorder| recorder.evalEnd(st.creation_index);

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

    if (host) |h| if (h.virtual) |v| try installVirtual(gpa, ctx, v);

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
    if (st.oom) return error.OutOfMemory;

    if (isInterrupted(&st)) {
        ok = false;
        gpa.free(text);
        text = try gpa.dupe(u8, if (st.cancel != null and st.cancel.?.load(.acquire)) "Error: run canceled" else "Error: run timed out");
    }
    const captured = try st.logs.snapshot(gpa);
    return .{
        .ok = ok,
        .tool_bytes = st.tool_bytes,
        .text = text,
        .logs = captured.logs,
        .log_entries = captured.entries,
        .log_bytes = st.logs.bytes,
        .log_head_bytes = captured.head_bytes,
        .log_tail_start = captured.tail_start,
        .log_truncated = st.logs.bytes > limits.max_log_bytes,
    };
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

fn virtualTime(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    state(ctx).host.?.virtual.?.uses_time = true;
    return js_undefined;
}

fn virtualRandom(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    state(ctx).host.?.virtual.?.uses_random = true;
    return js_undefined;
}

fn installVirtual(_: std.mem.Allocator, ctx: *c.JSContext, v: *Virtual) !void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    _ = c.JS_SetPropertyStr(ctx, global, "__replayEpoch", c.JS_NewFloat64(ctx, @floatFromInt(v.start_ms_epoch)));
    _ = c.JS_SetPropertyStr(ctx, global, "__replayTime", c.JS_NewCFunction2(ctx, virtualTime, "time", 0, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "__replayRandom", c.JS_NewCFunction2(ctx, virtualRandom, "random", 0, c.JS_CFUNC_generic, 0));
    const source = @import("sandbox/virtual.zig").prelude;
    const result = c.JS_Eval(ctx, source, source.len, "<virtual>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, result);
    if (c.JS_IsException(result)) return error.PreludeFailed;
}

fn state(ctx: ?*c.JSContext) *State {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
}

fn isInterrupted(st: *State) bool {
    if (st.cancel) |flag| if (flag.load(.acquire)) return true;
    const elapsed = if (st.js_started) |started| started.durationTo(.now(st.io, .awake)).raw.toNanoseconds() else 0;
    return elapsed >= st.js_remaining_ns;
}

fn virtualStopped(st: *State) bool {
    if (st.host) |h| if (h.virtual) |v| return v.stopped(v.ctx);
    return false;
}

fn interrupt(_: ?*c.JSContext, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const st: *State = @ptrCast(@alignCast(opaque_ptr.?));
    return @intFromBool(isInterrupted(st) or virtualStopped(st));
}

fn nativeLog(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const st = state(ctx);
    if (argc < 1) return js_undefined;
    var len: usize = 0;
    const p = c.JS_ToCStringLen2(ctx, &len, argv[0], false) orelse return js_undefined;
    defer c.JS_FreeCString(ctx, p);
    st.logs.append(st.gpa, p[0..len]) catch {
        st.oom = true;
    };
    return js_undefined;
}

fn nativeHost(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    return enqueue(state(ctx), ctx.?, argc, argv) catch |err| {
        if (err == error.ReplayDivergence) {
            const reason = c.JS_NewError(ctx);
            _ = c.JS_SetPropertyStr(ctx, reason, "message", c.JS_NewString(ctx, "replay diverged"));
            return c.JS_Throw(ctx, reason);
        }
        return c.JS_ThrowOutOfMemory(ctx);
    };
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
    call.* = .{ .state = st, .index = st.calls.items.len, .creation_index = st.creation_index, .name = name, .args = args, .settle = settle };
    if (st.host.?.virtual) |v| {
        v.create(v.ctx, st.creation_index, name, args);
        if (v.stopped(v.ctx)) return error.ReplayDivergence;
    } else if (st.host.?.admit) |admit| {
        if (try admit(st.host.?.ctx, st.gpa, name)) |message| {
            call.result = .{ .err = message };
            if (st.host.?.timing) |t| {
                call.timing_index = t.reserveEntry(name);
                if (call.timing_index) |i| {
                    const ms = t.elapsed();
                    t.complete(i, ms, ms, false);
                    t.entries[i].dispatched = false;
                }
            }
        }
    }
    errdefer if (call.result) |result| switch (result) {
        inline else => |bytes| st.gpa.free(bytes),
    };
    st.creation_index += 1;
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
    try testing.expect(slow.peak.load(.monotonic) > 1 and slow.peak.load(.monotonic) <= tool_concurrency);
    try testing.expectEqual(0, slow.active.load(.monotonic));
}

const TimingHost = struct {
    fetched: std.atomic.Value(bool) = .init(false),
    fail_fetch: bool = false,

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, _: []const u8) ToolResult {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "read")) {
            while (!self.fetched.load(.acquire)) std.Thread.yield() catch {};
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(40), .clock = .awake }, testing.io) catch unreachable;
        } else if (std.mem.eql(u8, name, "fetch")) {
            self.fetched.store(true, .release);
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, testing.io) catch unreachable;
            if (self.fail_fetch) return .{ .err = gpa.dupe(u8, "fetch failed") catch unreachable };
        }
        return .{ .ok = gpa.dupe(u8, "{\"exit_code\":7}") catch unreachable };
    }
};

test "native timings span evals and count omitted calls without treating exit codes as errors" {
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    var dummy: TimingHost = .{};
    const host: Host = .{ .ctx = &dummy, .names = &.{"bash"}, .call = TimingHost.call, .timing = &timing };
    const first = try run("await tools.bash()", .{}, host);
    defer first.deinit(testing.allocator);
    try testing.expect(first.ok);
    timing.started = .now(testing.io, .awake);
    timing.run_index = 1;
    const second = try run("await Promise.all(Array.from({length: 204}, () => tools.bash()))", .{}, host);
    defer second.deinit(testing.allocator);
    try testing.expect(second.ok);
    try testing.expectEqual(@as(usize, 200), timing.count);
    try testing.expectEqual(@as(u64, 5), timing.omitted);
    const result_size = "{\"exit_code\":7}".len;
    try testing.expectEqual(205 * result_size, timing.tool_bytes);
    try testing.expectEqual(result_size, first.tool_bytes);
    try testing.expectEqual(204 * result_size, second.tool_bytes);
    for (timing.entries[0..timing.count]) |entry| try testing.expectEqual(@as(?u64, result_size), entry.result_bytes);
    try testing.expectEqual(@as(usize, 0), timing.entries[0].run_index);
    for (timing.entries[1..timing.count]) |entry| {
        try testing.expectEqual(@as(usize, 1), entry.run_index);
        try testing.expectEqualStrings("bash", entry.name);
        try testing.expect(entry.end_ms >= entry.start_ms);
        try testing.expect(entry.ok);
    }
}

test "parallel native timings retain dispatch order and survive rejected JS with outstanding workers" {
    for ([_]bool{ false, true }) |fail_fetch| {
        var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
        var host_ctx: TimingHost = .{ .fail_fetch = fail_fetch };
        const result = try run("await Promise.all([tools.read(), tools.fetch()])", .{}, .{
            .ctx = &host_ctx,
            .names = &.{ "read", "fetch" },
            .call = TimingHost.call,
            .timing = &timing,
        });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(!fail_fetch, result.ok);
        try testing.expectEqual(@as(usize, 2), timing.count);
        try testing.expectEqual(@as(u64, 0), timing.omitted);
        const read = timing.entries[0];
        const fetch = timing.entries[1];
        try testing.expectEqualStrings("read", read.name);
        try testing.expectEqualStrings("fetch", fetch.name);
        try testing.expect(read.ok);
        try testing.expectEqual(!fail_fetch, fetch.ok);
        try testing.expect(read.end_ms - read.start_ms >= 40);
        try testing.expect(fetch.end_ms - fetch.start_ms >= 10);
        try testing.expect(read.start_ms <= fetch.end_ms);
        try testing.expect(fetch.start_ms <= read.end_ms);
    }
}

test "undispatched tools do not produce native timings" {
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    var dummy: TimingHost = .{};
    const result = try run("tools.bash(); throw new Error('before dispatch')", .{}, .{
        .ctx = &dummy,
        .names = &.{"bash"},
        .call = TimingHost.call,
        .timing = &timing,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expectEqual(@as(usize, 0), timing.count);
    try testing.expectEqual(@as(u64, 0), result.tool_bytes);
    try testing.expectEqual(@as(u64, 0), timing.tool_bytes);
}

const FileBytesHost = struct {
    dir: std.Io.Dir,
    const missing = "missing: 文件🙂";

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, _: []const u8, args: []const u8) ToolResult {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const parsed = std.json.parseFromSlice(struct { path: []const u8 }, gpa, args, .{}) catch unreachable;
        defer parsed.deinit();
        const text = self.dir.readFileAlloc(testing.io, parsed.value.path, gpa, .limited(1024)) catch
            return .{ .err = gpa.dupe(u8, missing) catch unreachable };
        defer gpa.free(text);
        return .{ .ok = serialize(gpa, text) catch unreachable };
    }

    fn serialize(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
        return std.json.Stringify.valueAlloc(gpa, .{ .text = text, .next_offset = @as(?usize, null) }, .{});
    }
};

test "tool bytes include both file results but output bytes only include the formatted short result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = "第一份🙂\n";
    const b = "second\nline\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = a });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b", .data = b });
    const json_a = try FileBytesHost.serialize(testing.allocator, a);
    defer testing.allocator.free(json_a);
    const json_b = try FileBytesHost.serialize(testing.allocator, b);
    defer testing.allocator.free(json_b);
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    var host: FileBytesHost = .{ .dir = tmp.dir };
    var result = try run("await Promise.all([tools.read({path:'a'}), tools.read({path:'b'})]); 'ok'", .{}, .{
        .ctx = &host,
        .names = &.{"read"},
        .call = FileBytesHost.call,
        .timing = &timing,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqual(json_a.len + json_b.len, result.tool_bytes);
    try testing.expectEqual(result.tool_bytes, timing.tool_bytes);
    try testing.expectEqual(@as(?u64, json_a.len), timing.entries[0].result_bytes);
    try testing.expectEqual(@as(?u64, json_b.len), timing.entries[1].result_bytes);
    const output = try @import("session/output.zig").format(testing.allocator, result);
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("result: \"ok\"", output);
}

test "rejected and unawaited settled calls contribute their UTF-8 result bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "unused🙂" });
    const json = try FileBytesHost.serialize(testing.allocator, "unused🙂");
    defer testing.allocator.free(json);
    var host: FileBytesHost = .{ .dir = tmp.dir };
    for ([_][]const u8{
        "tools.read({path:'a'}); 'ok'",
        "try { await tools.read({path:'missing'}); } catch (_) {} 'ok'",
    }, [_]usize{ json.len, FileBytesHost.missing.len }) |code, expected| {
        var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
        const result = try run(code, .{}, .{
            .ctx = &host,
            .names = &.{"read"},
            .call = FileBytesHost.call,
            .timing = &timing,
        });
        defer result.deinit(testing.allocator);
        try testing.expect(result.ok);
        try testing.expectEqual(expected, result.tool_bytes);
        try testing.expectEqual(expected, timing.tool_bytes);
        try testing.expectEqual(@as(?u64, expected), timing.entries[0].result_bytes);
    }
}

test "admission rejections count only the returned error text" {
    const Rejected = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) ToolResult {
            unreachable;
        }
        fn admit(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) anyerror!?[]u8 {
            return try gpa.dupe(u8, "denied🙂");
        }
    };
    var dummy: u8 = 0;
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    const result = try run("await tools.llm().catch(() => 'caught')", .{}, .{
        .ctx = &dummy,
        .names = &.{"llm"},
        .call = Rejected.call,
        .admit = Rejected.admit,
        .timing = &timing,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqual("denied🙂".len, result.tool_bytes);
    try testing.expectEqual(result.tool_bytes, timing.tool_bytes);
    try testing.expectEqual(@as(?u64, "denied🙂".len), timing.entries[0].result_bytes);
    try testing.expect(!timing.entries[0].ok);
    try testing.expect(!timing.entries[0].dispatched);
    try testing.expectEqual(@as(u64, 0), timing.llm_calls);
}

test "workers completed only during rejection cleanup do not contribute result bytes" {
    const CleanupHost = struct {
        cancel: std.atomic.Value(bool) = .init(false),
        reading: std.atomic.Value(bool) = .init(false),

        fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, _: []const u8) ToolResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "read")) {
                self.reading.store(true, .release);
                while (!self.cancel.load(.acquire)) std.Thread.yield() catch {};
                return .{ .ok = gpa.dupe(u8, "{\"text\":\"not delivered\"}") catch unreachable };
            }
            while (!self.reading.load(.acquire)) std.Thread.yield() catch {};
            return .{ .err = gpa.dupe(u8, "failed🙂") catch unreachable };
        }
    };
    var host: CleanupHost = .{};
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    const result = try run("await Promise.all([tools.read(), tools.fetch()])", .{}, .{
        .ctx = &host,
        .names = &.{ "read", "fetch" },
        .call = CleanupHost.call,
        .cancel = &host.cancel,
        .timing = &timing,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expectEqual("failed🙂".len, result.tool_bytes);
    try testing.expectEqual(result.tool_bytes, timing.tool_bytes);
    try testing.expectEqual(@as(?u64, 0), timing.entries[0].result_bytes);
    try testing.expectEqual(@as(?u64, "failed🙂".len), timing.entries[1].result_bytes);
}

test "record and virtual replay share settlement path including admission rejects and monotonic creation indices" {
    const RecordHost = struct {
        fast: std.atomic.Value(bool) = .init(false),
        calls: std.atomic.Value(usize) = .init(0),

        fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, _: []const u8) ToolResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.calls.fetchAdd(1, .monotonic);
            if (std.mem.eql(u8, name, "slow")) {
                while (!self.fast.load(.acquire)) std.Thread.yield() catch {};
                std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(30), .clock = .awake }, testing.io) catch unreachable;
            } else if (std.mem.eql(u8, name, "fast")) self.fast.store(true, .release);
            if (std.mem.eql(u8, name, "fail")) return .{ .err = gpa.dupe(u8, "worker denied") catch unreachable };
            return .{ .ok = std.json.Stringify.valueAlloc(gpa, name, .{}) catch unreachable };
        }

        fn admit(_: *anyopaque, gpa: std.mem.Allocator, name: []const u8) !?[]u8 {
            return if (std.mem.eql(u8, name, "denied")) try gpa.dupe(u8, "admission denied") else null;
        }
    };
    var recorder = Recorder.init(testing.allocator, testing.io, "unused-record-test-path", true);
    defer recorder.deinit();
    recorder.begin(7, 2);
    var host: RecordHost = .{};
    const code = "const pending=[tools.slow(),tools.fast()]; const winner=await Promise.race(pending); await Promise.all(pending); const again=await tools.fast(); let denied,fail; try { await tools.denied(); } catch(e) { denied=e.message; } try { await tools.fail(); } catch(e) { fail=e.message; } [winner,again,denied,fail]";
    const actual = try run(code, .{}, .{ .ctx = &host, .names = &.{ "slow", "fast", "denied", "fail" }, .call = RecordHost.call, .admit = RecordHost.admit, .record = &recorder });
    defer actual.deinit(testing.allocator);
    try testing.expect(actual.ok);
    try testing.expectEqualStrings("[\"fast\",\"fast\",\"denied: admission denied\",\"fail: worker denied\"]", actual.text);
    try testing.expectEqual(@as(usize, 4), host.calls.load(.monotonic));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(replay.Entry) = .empty;
    var lines = std.mem.splitScalar(u8, recorder.buffer.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var row = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        if (row.object.contains("meta")) continue;
        if (row.object.get("result")) |value| if (value == .object) {
            _ = row.object.swapRemove("result");
            try row.object.put(a, "same_as", value.object.get("same_as").?);
        };
        var entry = try std.json.parseFromValueLeaky(replay.Entry, a, row, .{ .ignore_unknown_fields = true });
        if (entry.same_as) |hash| {
            for (entries.items) |prev| if (prev.ok == entry.ok and std.mem.eql(u8, prev.sha256, hash)) {
                entry.result = prev.result;
                entry.@"error" = prev.@"error";
                break;
            };
        }
        try entries.append(a, entry);
    }
    try testing.expectEqual(@as(usize, 5), entries.items.len);
    try testing.expectEqual(@as(usize, 1), entries.items[0].index);
    try testing.expectEqual(@as(usize, 0), entries.items[1].index);
    for (entries.items[2..], 2..) |entry, index| try testing.expectEqual(index, entry.index);
    for (entries.items, 0..) |entry, seq| try testing.expectEqual(seq, entry.seq);
    const repeated = try replay.execute(testing.allocator, testing.io, code, entries.items, recorder.start_ms_epoch, .ok, false);
    defer repeated.deinit(testing.allocator);
    try testing.expect(repeated.divergence == null);
    try testing.expectEqualStrings(actual.text, repeated.outcome.text);
}

test "eval exit records missing creations on errors but settled errors stay complete" {
    const Case = struct { code: []const u8, incomplete: bool, delivered: usize };
    for ([_]Case{
        .{ .code = "tools.bash(); throw new Error('pending')", .incomplete = true, .delivered = 0 },
        .{ .code = "await tools.bash(); tools.bash(); throw new Error('tail pending')", .incomplete = true, .delivered = 1 },
        .{ .code = "await Promise.all([tools.read(), tools.fetch()])", .incomplete = true, .delivered = 1 },
        .{ .code = "await tools.bash(); throw new Error('settled')", .incomplete = false, .delivered = 1 },
        .{ .code = "await tools.fetch()", .incomplete = false, .delivered = 1 },
        .{ .code = "throw new Error('zero calls')", .incomplete = false, .delivered = 0 },
    }) |case| {
        var recorder = Recorder.init(testing.allocator, testing.io, "unused-record-test-path", true);
        defer recorder.deinit();
        recorder.begin(1, 0);
        var host: TimingHost = .{ .fail_fetch = true };
        const result = try run(case.code, .{}, .{ .ctx = &host, .names = &.{ "bash", "read", "fetch" }, .call = TimingHost.call, .record = &recorder });
        defer result.deinit(testing.allocator);
        try testing.expect(!result.ok);
        try testing.expectEqual(case.incomplete, recorder.incomplete);
        try testing.expectEqual(case.delivered, recorder.seq);
    }
}
