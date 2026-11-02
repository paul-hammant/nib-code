const std = @import("std");
const secrets = @import("secrets.zig");

pub const Result = struct {
    term: std.process.Child.Term,
    output: []u8,
    stop: ?Stop = null,
};

const Stop = error{ Canceled, TimedOut };

pub const Options = struct {
    spawn: std.process.SpawnOptions,
    cancel: *const std.atomic.Value(bool),
    timeout_ms: i64,
    input: ?[]const u8 = null,
    termination_grace_ms: u32 = 0,
    max_output_bytes: usize = 8 * 1024 * 1024,
};

const Group = struct {
    pid: std.posix.pid_t,
    io: std.Io,
    grace_ms: u32,
    stopped: bool = false,

    fn kill(group: *Group) void {
        if (group.stopped) return;
        group.stopped = true;
        if (group.grace_ms > 0) {
            std.posix.kill(-group.pid, .TERM) catch {};
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(group.grace_ms), .clock = .awake }, group.io) catch {};
        }
        std.posix.kill(-group.pid, .KILL) catch {};
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, options: Options) !Result {
    var opts = options.spawn;
    var env = if (opts.environ_map) |map| try map.clone(gpa) else try inheritedEnvironment(gpa);
    defer env.deinit();
    secrets.removeFrom(&env);
    opts.environ_map = &env;
    if (options.input != null) opts.stdin = .pipe;
    opts.pgid = 0;
    var child = try std.process.spawn(io, opts);
    const pid = child.id.?;
    defer child.kill(io);
    var group: Group = .{ .pid = pid, .io = io, .grace_ms = options.termination_grace_ms };
    defer group.kill();
    const Input = struct {
        fn write(file: std.Io.File, i: std.Io, bytes: []const u8) anyerror!void {
            defer file.close(i);
            var writer = file.writer(i, &.{});
            try writer.interface.writeAll(bytes);
            try writer.interface.flush();
        }
    };
    var feeder: ?std.Io.Future(anyerror!void) = null;
    defer if (feeder) |*f| {
        group.kill();
        _ = f.cancel(io) catch {};
    };
    if (options.input) |input| {
        const file = child.stdin.?;
        child.stdin = null;
        feeder = io.concurrent(Input.write, .{ file, io, input }) catch |err| {
            file.close(io);
            return err;
        };
    }

    var streams: std.Io.File.MultiReader.Buffer(1) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, streams.toStreams(), &.{child.stdout.?});
    defer mr.deinit();
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromMilliseconds(options.timeout_ms), .clock = .awake });
    var stop: ?Stop = null;
    while (true) {
        if (stop == null) check(io, options.cancel, deadline) catch |err| {
            stop = err;
            group.kill();
        };
        mr.fill(4096, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {},
            else => return err,
        };
        if (mr.reader(0).buffered().len > options.max_output_bytes) return error.OutputLimit;
    }
    try mr.checkAnyError();
    const Wait = struct {
        fn work(c: *std.process.Child, i: std.Io, done: *std.Io.Event) !std.process.Child.Term {
            defer done.set(i);
            return c.wait(i);
        }
    };
    var done: std.Io.Event = .unset;
    var waiter = try io.concurrent(Wait.work, .{ &child, io, &done });
    defer _ = waiter.await(io) catch {};
    while (!done.isSet()) {
        if (stop == null) check(io, options.cancel, deadline) catch |err| {
            stop = err;
            group.kill();
        };
        done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            else => {
                group.kill();
                return err;
            },
        };
    }
    const term = try waiter.await(io);
    group.grace_ms = 0;
    if (feeder) |*f| {
        f.cancel(io) catch |err| {
            if (stop == null) return err;
        };
        feeder = null;
    }
    return .{ .term = term, .output = try mr.toOwnedSlice(0), .stop = stop };
}

fn check(io: std.Io, cancel: *const std.atomic.Value(bool), deadline: std.Io.Clock.Timestamp) Stop!void {
    if (cancel.load(.acquire)) return error.Canceled;
    if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return error.TimedOut;
}

fn inheritedEnvironment(gpa: std.mem.Allocator) !std.process.Environ.Map {
    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    return environ.createMap(gpa);
}

test "process strips credentials and preserves ordinary environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    for (secrets.environment_names) |name| try env.put(name, "fictional-secret");
    try env.put("NIB_TEST_ORDINARY", "kept");
    var cancel: std.atomic.Value(bool) = .init(false);
    const result = try run(std.testing.allocator, std.testing.io, .{
        .spawn = .{ .argv = &.{"env"}, .environ_map = &env, .stdout = .pipe, .stderr = .ignore },
        .cancel = &cancel,
        .timeout_ms = 1000,
    });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.term.success());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "fictional-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NIB_TEST_ORDINARY=kept") != null);
    try std.testing.expect(env.contains("NIB_API_KEY"));
}

const testing = std.testing;

test "process deadline covers a blocked stdin writer" {
    const input = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(input);
    @memset(input, 'x');
    var cancel: std.atomic.Value(bool) = .init(false);
    const start = std.Io.Clock.awake.now(testing.io);
    const result = try run(testing.allocator, testing.io, .{
        .spawn = .{ .argv = &.{ "bash", "-c", "sleep 5" }, .stdout = .pipe, .stderr = .ignore },
        .input = input,
        .cancel = &cancel,
        .timeout_ms = 50,
    });
    defer testing.allocator.free(result.output);
    try testing.expectEqual(error.TimedOut, result.stop.?);
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() < 1000);
}
