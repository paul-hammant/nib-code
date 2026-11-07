//! State behind `/provider`: masked key entry, the add-endpoint form and the
//! background sign-in and model-listing jobs. No terminal or Session code here.

const std = @import("std");
const provider = @import("../provider.zig");
const config = @import("../config.zig");
const auth = @import("../auth.zig");

pub const default_window: u64 = 128_000;
const Env = std.process.Environ.Map;

pub const Step = enum { name, base_url, key, protocol, model, window };

pub const Outcome = union(enum) {
    next,
    invalid: []const u8,
    /// Connection details are complete; list the endpoint's models next.
    list_models,
    ready,
};

pub fn parseProtocol(text: []const u8) ?provider.Protocol {
    const t = std.mem.trim(u8, text, " \t");
    inline for (.{
        .{ provider.Protocol.chat_completions, .{ "", "1", "chat", "chat_completions", "openai" } },
        .{ provider.Protocol.responses, .{ "2", "responses" } },
        .{ provider.Protocol.anthropic_messages, .{ "3", "anthropic", "anthropic_messages", "messages" } },
    }) |row| inline for (row[1]) |name| {
        if (std.ascii.eqlIgnoreCase(t, name)) return row[0];
    };
    return null;
}

/// The add-endpoint form: name, base URL, key, protocol, then model and context window.
pub const Form = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Service ids already in use, borrowed.
    existing: []const []const u8,
    step: Step = .name,
    id: []const u8 = "",
    base_url: []const u8 = "",
    key: []u8 = &.{},
    protocol: provider.Protocol = .chat_completions,
    model: []const u8 = "",
    window: ?u64 = null,

    pub fn init(gpa: std.mem.Allocator, existing: []const []const u8) Form {
        return .{ .gpa = gpa, .arena = .init(gpa), .existing = existing };
    }

    pub fn deinit(f: *Form) void {
        std.crypto.secureZero(u8, f.key);
        f.gpa.free(f.key);
        f.arena.deinit();
    }

    pub fn masked(f: Form) bool {
        return f.step == .key;
    }

    pub fn hint(f: Form) []const u8 {
        return switch (f.step) {
            .name => "Add endpoint 1/4 · Name",
            .base_url => "Add endpoint 2/4 · Base URL",
            .key => "Add endpoint 3/4 · API key, empty for none",
            .protocol => "Add endpoint 4/4 · Protocol",
            .model => "Add endpoint · Model id",
            .window => "Add endpoint · Context window · default 128000",
        };
    }

    pub fn submit(f: *Form, raw: []const u8) !Outcome {
        const a = f.arena.allocator();
        const text = std.mem.trim(u8, raw, " \t\r\n");
        switch (f.step) {
            .name => {
                if (config.endpointIdProblem(text, f.existing)) |problem| return .{ .invalid = problem };
                f.id = try a.dupe(u8, text);
                f.step = .base_url;
            },
            .base_url => {
                if (!std.mem.startsWith(u8, text, "http://") and !std.mem.startsWith(u8, text, "https://")) return .{ .invalid = "Base URL must start with http:// or https://" };
                const trimmed = std.mem.trimEnd(u8, text, "/");
                const scheme_end = std.mem.indexOf(u8, trimmed, "://") orelse return .{ .invalid = "Base URL needs a host" };
                if (scheme_end + 3 >= trimmed.len) return .{ .invalid = "Base URL needs a host" };
                f.base_url = try a.dupe(u8, trimmed);
                f.step = .key;
            },
            .key => {
                std.crypto.secureZero(u8, f.key);
                f.gpa.free(f.key);
                f.key = try f.gpa.dupe(u8, text);
                f.step = .protocol;
            },
            .protocol => {
                f.protocol = parseProtocol(text) orelse return .{ .invalid = "Choose 1, 2 or 3" };
                return .list_models;
            },
            .model => {
                if (text.len == 0) return .{ .invalid = "Model id cannot be empty" };
                f.model = try a.dupe(u8, text);
                return f.afterModel();
            },
            .window => {
                if (text.len == 0) {
                    f.window = default_window;
                } else {
                    const n = std.fmt.parseInt(u64, text, 10) catch return .{ .invalid = "Context window must be a positive integer" };
                    if (n == 0) return .{ .invalid = "Context window must be a positive integer" };
                    f.window = n;
                }
                return .ready;
            },
        }
        return .next;
    }

    fn afterModel(f: *Form) Outcome {
        if (f.window != null) return .ready;
        f.step = .window;
        return .next;
    }

    /// A model chosen from the listing, with the listed window when there is one.
    pub fn pick(f: *Form, entry: auth.models.Listed) !Outcome {
        f.model = try f.arena.allocator().dupe(u8, entry.id);
        f.window = entry.context_window;
        return f.afterModel();
    }

    /// Listing failed or came back empty: ask for the id as text.
    pub fn typeModel(f: *Form) void {
        f.step = .model;
    }

    pub fn endpoint(f: Form) config.Endpoint {
        return .{ .id = f.id, .protocol = f.protocol, .base_url = f.base_url, .model = f.model, .context_window = f.window orelse default_window };
    }
};

/// One reply from a background job; allocated with the Flow's allocator.
pub const Result = union(enum) {
    prompt: struct { url: []u8, code: []u8 },
    login: struct { ok: bool, canceled: bool, message: []u8 },
    models: struct { ok: bool, list: []auth.models.Listed },

    pub fn deinit(r: *Result, gpa: std.mem.Allocator) void {
        switch (r.*) {
            .prompt => |p| {
                gpa.free(p.url);
                gpa.free(p.code);
            },
            .login => |l| gpa.free(l.message),
            .models => |m| {
                for (m.list) |item| gpa.free(item.id);
                gpa.free(m.list);
            },
        }
    }
};

pub const Post = struct { ctx: *anyopaque, call: *const fn (ctx: *anyopaque, result: *Result) void };

/// A sign-in or model listing on its own thread. Heap allocated; `finish` joins and frees.
pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const Env,
    home: []u8,
    post: Post,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    job: Job,

    pub const Job = union(enum) {
        login: struct { device_only: bool },
        models: struct { base_url: []u8, protocol: provider.Protocol, key: []u8 },
    };

    pub fn start(gpa: std.mem.Allocator, io: std.Io, environ: *const Env, home: []const u8, post: Post, job: Job) !*Worker {
        const w = try gpa.create(Worker);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .io = io, .environ = environ, .home = try gpa.dupe(u8, home), .post = post, .job = job };
        errdefer gpa.free(w.home);
        w.thread = try std.Thread.spawn(.{}, run, .{w});
        return w;
    }

    pub fn finish(w: *Worker) void {
        w.cancel.store(true, .release);
        if (w.thread) |t| t.join();
        const gpa = w.gpa;
        gpa.free(w.home);
        switch (w.job) {
            .login => {},
            .models => |m| {
                gpa.free(m.base_url);
                std.crypto.secureZero(u8, m.key);
                gpa.free(m.key);
            },
        }
        gpa.destroy(w);
    }

    fn send(w: *Worker, result: Result) void {
        const boxed = w.gpa.create(Result) catch {
            var owned = result;
            owned.deinit(w.gpa);
            return;
        };
        boxed.* = result;
        w.post.call(w.post.ctx, boxed);
    }

    fn devicePrompt(ctx: *anyopaque, url: []const u8, code: []const u8) void {
        const w: *Worker = @ptrCast(@alignCast(ctx));
        const u = w.gpa.dupe(u8, url) catch return;
        const c = w.gpa.dupe(u8, code) catch {
            w.gpa.free(u);
            return;
        };
        w.send(.{ .prompt = .{ .url = u, .code = c } });
    }

    fn run(w: *Worker) void {
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var client: std.http.Client = .{ .allocator = w.gpa, .io = w.io };
        defer client.deinit();
        client.initDefaultProxies(a, w.environ) catch {};
        switch (w.job) {
            .login => |job| w.send(w.runLogin(a, &client, job.device_only)),
            .models => |job| w.send(w.runModels(a, &client, job.base_url, job.protocol, job.key)),
        }
    }

    fn runLogin(w: *Worker, a: std.mem.Allocator, client: *std.http.Client, device_only: bool) Result {
        const done = auth.login.run(a, .{
            .io = w.io,
            .client = client,
            .environ = w.environ,
            .nib_home = w.home,
            .cancel = &w.cancel,
            .prompt = .{ .ctx = w, .device = devicePrompt },
            .device_only = device_only,
        });
        if (done) |result| {
            var buf: [64]u8 = undefined;
            const text = w.gpa.dupe(u8, auth.oauth.planLabel(&buf, result.plan)) catch return failure(w.gpa, false, "out of memory");
            return .{ .login = .{ .ok = true, .canceled = false, .message = text } };
        } else |err| return failure(w.gpa, err == error.Canceled, loginError(err));
    }

    fn runModels(w: *Worker, a: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, protocol: provider.Protocol, key: []const u8) Result {
        const fetched = auth.models.fetch(a, client, base_url, protocol, key) catch return .{ .models = .{ .ok = false, .list = &.{} } };
        const list = w.gpa.alloc(auth.models.Listed, fetched.len) catch return .{ .models = .{ .ok = false, .list = &.{} } };
        var made: usize = 0;
        for (fetched) |item| {
            const id = w.gpa.dupe(u8, item.id) catch break;
            list[made] = .{ .id = id, .context_window = item.context_window };
            made += 1;
        }
        if (made != fetched.len) {
            for (list[0..made]) |item| w.gpa.free(item.id);
            w.gpa.free(list);
            return .{ .models = .{ .ok = false, .list = &.{} } };
        }
        return .{ .models = .{ .ok = true, .list = list } };
    }
};

fn failure(gpa: std.mem.Allocator, canceled: bool, message: []const u8) Result {
    return .{ .login = .{ .ok = false, .canceled = canceled, .message = gpa.dupe(u8, message) catch &.{} } };
}

pub fn loginError(err: anyerror) []const u8 {
    return switch (err) {
        error.Canceled => "Sign-in canceled",
        error.LoginDenied => "Sign-in was denied",
        error.LoginTimedOut => "Sign-in timed out",
        error.DeviceCodeUnavailable => "Device sign-in is not available",
        error.DeviceCodeRejected, error.InvalidDeviceCodeResponse => "Device sign-in failed",
        error.TokenExchangeRejected, error.InvalidTokenResponse => "ChatGPT rejected the sign-in",
        error.MissingAccountId => "Sign-in response had no account id",
        else => "Sign-in failed; check the network",
    };
}

pub const Kind = enum { none, key, form, protocol, pick, waiting };
pub const Waiting = enum { login, listing };

/// What the TUI is doing for `/provider` besides ordinary editing.
pub const Flow = struct {
    gpa: std.mem.Allocator,
    kind: Kind = .none,
    waiting: Waiting = .login,
    /// Service whose key is being entered.
    service_id: []u8 = &.{},
    service_name: []u8 = &.{},
    /// The current entry; a secret while `masked()`.
    text: std.ArrayList(u8) = .empty,
    form: ?Form = null,
    worker: ?*Worker = null,
    /// Models listed for the form, owned.
    listed: []auth.models.Listed = &.{},
    /// Service ids the form checks names against.
    ids: ?std.heap.ArenaAllocator = null,

    pub fn deinit(f: *Flow) void {
        f.reset();
        f.text.deinit(f.gpa);
    }

    pub fn active(f: Flow) bool {
        return f.kind != .none;
    }

    pub fn takesText(f: Flow) bool {
        return f.kind == .key or f.kind == .form;
    }

    pub fn masked(f: Flow) bool {
        if (f.kind == .key) return true;
        return if (f.form) |form| f.kind == .form and form.masked() else false;
    }

    pub fn reset(f: *Flow) void {
        if (f.worker) |w| {
            w.finish();
            f.worker = null;
        }
        f.wipe();
        f.gpa.free(f.service_id);
        f.gpa.free(f.service_name);
        f.service_id = &.{};
        f.service_name = &.{};
        if (f.form) |*form| form.deinit();
        f.form = null;
        if (f.ids) |*arena| arena.deinit();
        f.ids = null;
        for (f.listed) |item| f.gpa.free(item.id);
        f.gpa.free(f.listed);
        f.listed = &.{};
        f.kind = .none;
    }

    /// Zeroes the entry buffer so a key never lingers in freed memory.
    pub fn wipe(f: *Flow) void {
        std.crypto.secureZero(u8, f.text.items.ptr[0..f.text.capacity]);
        f.text.clearRetainingCapacity();
    }

    pub fn startKey(f: *Flow, id: []const u8, name: []const u8) !void {
        f.reset();
        f.service_id = try f.gpa.dupe(u8, id);
        f.service_name = try f.gpa.dupe(u8, name);
        f.kind = .key;
    }

    pub fn startForm(f: *Flow, existing: []const []const u8) !void {
        f.reset();
        var arena: std.heap.ArenaAllocator = .init(f.gpa);
        errdefer arena.deinit();
        const copy = try arena.allocator().alloc([]const u8, existing.len);
        for (existing, copy) |id, *out| out.* = try arena.allocator().dupe(u8, id);
        f.ids = arena;
        f.form = .init(f.gpa, copy);
        f.kind = .form;
    }

    pub fn insert(f: *Flow, s: []const u8) !void {
        for (s) |c| if (c == '\n' or c == '\r') return;
        try f.text.appendSlice(f.gpa, s);
    }

    pub fn backspace(f: *Flow) void {
        if (f.text.items.len == 0) return;
        var n = f.text.items.len - 1;
        while (n > 0 and (f.text.items[n] & 0xC0) == 0x80) n -= 1;
        std.crypto.secureZero(u8, f.text.items[n..]);
        f.text.shrinkRetainingCapacity(n);
    }

    /// Characters shown in the input: dots for secrets.
    pub fn display(f: Flow, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        out.clearRetainingCapacity();
        if (!f.masked()) return out.appendSlice(gpa, f.text.items);
        const count = std.unicode.utf8CountCodepoints(f.text.items) catch f.text.items.len;
        for (0..count) |_| try out.appendSlice(gpa, "•");
    }

    pub fn hint(f: Flow, buf: []u8) []const u8 {
        return switch (f.kind) {
            .none => "",
            .key => std.fmt.bufPrint(buf, "{s} API key", .{f.service_name}) catch "API key",
            .form => f.form.?.hint(),
            .protocol => "Add endpoint 4/4 · Protocol",
            .pick => "Choose a model",
            .waiting => if (f.waiting == .login) "Waiting for ChatGPT sign-in" else "Listing models",
        };
    }
};

const testing = std.testing;

test "form walks name, URL, key, protocol and model with validation" {
    var form: Form = .init(testing.allocator, &.{"taken"});
    defer form.deinit();
    try testing.expectEqualStrings("Name is already used", (try form.submit("taken")).invalid);
    try testing.expectEqualStrings("Use letters, digits, _ and - only", (try form.submit("a b")).invalid);
    try testing.expect(try form.submit("  my-site ") == .next);
    try testing.expectEqual(Step.base_url, form.step);
    try testing.expect((try form.submit("ftp://x")).invalid.len > 0);
    try testing.expect((try form.submit("http://")).invalid.len > 0);
    try testing.expect(try form.submit("https://models.example.com/v1/") == .next);
    try testing.expectEqualStrings("https://models.example.com/v1", form.base_url);
    try testing.expect(form.masked());
    try testing.expect(try form.submit("fake-secret") == .next);
    try testing.expectEqualStrings("fake-secret", form.key);
    try testing.expectEqualStrings("Choose 1, 2 or 3", (try form.submit("9")).invalid);
    try testing.expect(try form.submit("2") == .list_models);
    try testing.expectEqual(provider.Protocol.responses, form.protocol);
    // A listing with a window finishes at once; one without asks for it.
    var other: Form = .init(testing.allocator, &.{});
    defer other.deinit();
    form.step = .protocol;
    try testing.expect(try form.pick(.{ .id = "m1", .context_window = 32000 }) == .ready);
    const endpoint = form.endpoint();
    try testing.expectEqualStrings("my-site", endpoint.id);
    try testing.expectEqual(@as(u64, 32000), endpoint.context_window);
    try testing.expect(try other.pick(.{ .id = "m2" }) == .next);
    try testing.expectEqual(Step.window, other.step);
    try testing.expect((try other.submit("0")).invalid.len > 0);
    try testing.expect((try other.submit("many")).invalid.len > 0);
    try testing.expect(try other.submit("") == .ready);
    try testing.expectEqual(default_window, other.endpoint().context_window);
}

test "failed listing asks for the model id and a typed window" {
    var form: Form = .init(testing.allocator, &.{});
    defer form.deinit();
    form.typeModel();
    try testing.expectEqualStrings("Model id cannot be empty", (try form.submit("  ")).invalid);
    try testing.expect(try form.submit("local-model") == .next);
    try testing.expectEqual(Step.window, form.step);
    try testing.expect(try form.submit("8192") == .ready);
    try testing.expectEqual(@as(u64, 8192), form.endpoint().context_window);
    try testing.expectEqualStrings("local-model", form.endpoint().model);
}

test "protocol names" {
    try testing.expectEqual(provider.Protocol.chat_completions, parseProtocol("").?);
    try testing.expectEqual(provider.Protocol.chat_completions, parseProtocol("OpenAI").?);
    try testing.expectEqual(provider.Protocol.responses, parseProtocol("responses").?);
    try testing.expectEqual(provider.Protocol.anthropic_messages, parseProtocol("3").?);
    try testing.expect(parseProtocol("grpc") == null);
}

test "secret entry is masked, wiped and kept out of the display" {
    var flow: Flow = .{ .gpa = testing.allocator };
    defer flow.deinit();
    try flow.startKey("anthropic", "Anthropic");
    try testing.expect(flow.masked() and flow.takesText());
    try flow.insert("sk-é1");
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(testing.allocator);
    try flow.display(&shown, testing.allocator);
    try testing.expectEqualStrings("•••••", shown.items);
    flow.backspace();
    flow.backspace();
    try testing.expectEqualStrings("sk-", flow.text.items);
    try flow.insert("\nignored");
    try testing.expectEqualStrings("sk-", flow.text.items);
    var hint: [128]u8 = undefined;
    try testing.expectEqualStrings("Anthropic API key", flow.hint(&hint));
    flow.wipe();
    try testing.expectEqual(@as(usize, 0), flow.text.items.len);
    flow.reset();
    try testing.expect(!flow.active());
}

test "form steps mask only the key and show plain text elsewhere" {
    var flow: Flow = .{ .gpa = testing.allocator };
    defer flow.deinit();
    try flow.startForm(&.{});
    try testing.expect(!flow.masked());
    _ = try flow.form.?.submit("site");
    _ = try flow.form.?.submit("http://h");
    try testing.expect(flow.masked());
    try flow.insert("secret");
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(testing.allocator);
    try flow.display(&shown, testing.allocator);
    try testing.expect(std.mem.indexOf(u8, shown.items, "secret") == null);
}
