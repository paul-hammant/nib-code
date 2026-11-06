const std = @import("std");
const App = @import("../tui.zig").App;
const Turn = @import("turn.zig").Turn;
const reflect = @import("reflect.zig");
const config = @import("../config.zig");
const ChangeText = @import("transcript.zig").ChangeText;
const provider = @import("../provider.zig");

pub const Command = enum { help, new, @"resume", compact, undo, effort, copy, reflect, js, tasks, stop, status, skills };

pub const Choices = enum { none, efforts, sessions, tasks };

pub const Group = enum { send, view, session };

pub const Spec = struct {
    group: Group = .session,
    args: []const u8 = "",
    help: []const u8,
    /// Usable while a Turn is running.
    while_busy: bool = false,
    choices: Choices = .none,
    /// Accepting the bare command waits for an argument instead of running.
    needs_arg: bool = false,
};

pub const specs = std.enums.EnumArray(Command, Spec).init(.{
    .skills = .{ .group = .view, .args = "[on|off <name>]", .help = "list or enable skills for new sessions" },
    .status = .{ .group = .view, .help = "timing and cache details", .while_busy = true },
    .tasks = .{ .group = .view, .help = "background tasks", .while_busy = true },
    .stop = .{ .args = "<id>", .help = "stop a task; changes may remain", .while_busy = true, .choices = .tasks, .needs_arg = true },
    .help = .{ .group = .view, .help = "commands and keys", .while_busy = true },
    .new = .{ .help = "new session" },
    .@"resume" = .{ .args = "<id>", .help = "resume a session", .choices = .sessions, .needs_arg = true },
    .undo = .{ .help = "undo last edited Turn; edit/write only", .while_busy = true },
    .compact = .{ .help = "compact earlier history" },
    .effort = .{ .group = .send, .args = "[level]", .help = "reasoning effort", .choices = .efforts },
    .copy = .{ .group = .view, .help = "copy last answer", .while_busy = true },
    .reflect = .{ .args = "[focus]", .help = "publish issue drafts: yyydddkkk/nib-code" },
    .js = .{ .group = .send, .args = "<code>", .help = "run JavaScript", .needs_arg = true },
});

pub const keys = "Enter send · Shift+Enter newline · Esc cancel\nCtrl+O details · PgUp/PgDn scroll · ↑ input history · Ctrl+C quit";

const slash_names = blk: {
    var names: [std.enums.values(Command).len][]const u8 = undefined;
    for (std.enums.values(Command), &names) |c, *n| n.* = "/" ++ @tagName(c);
    const final = names;
    break :blk final;
};

pub fn slashName(c: Command) []const u8 {
    return slash_names[@backingInt(c)];
}

pub const Parsed = union(enum) {
    known: struct { command: Command, arg: []const u8 },
    unknown: []const u8,
};

/// null for ordinary messages, including ones that start with a path like `/etc/hosts`.
pub fn parse(line: []const u8) ?Parsed {
    if (line.len < 2 or line[0] != '/') return null;
    const end = std.mem.indexOfAny(u8, line, " \t\n") orelse line.len;
    const name = line[1..end];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
    const command = std.meta.stringToEnum(Command, name) orelse return .{ .unknown = name };
    return .{ .known = .{ .command = command, .arg = std.mem.trim(u8, line[end..], " \t\n") } };
}

pub fn allowedWhileBusy(line: []const u8) bool {
    const parsed = parse(line) orelse return false;
    return switch (parsed) {
        .known => |c| specs.get(c.command).while_busy,
        .unknown => false,
    };
}

pub const Choice = struct {
    value: []const u8,
    label: []const u8,
    detail: []const u8,
};

pub const Candidate = struct {
    command: Command,
    /// Set when this is an argument choice rather than the command itself.
    value: ?[]const u8 = null,
    label: []const u8,
    detail: []const u8,

    pub fn group(c: Candidate) ?Group {
        return if (c.value == null) specs.get(c.command).group else null;
    }

    /// What accepting it with Tab leaves in the input.
    pub fn completion(c: Candidate, gpa: std.mem.Allocator) ![]u8 {
        if (c.value) |v| return std.fmt.allocPrint(gpa, "{s} {s}", .{ slashName(c.command), v });
        const spec = specs.get(c.command);
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ slashName(c.command), if (spec.args.len > 0) " " else "" });
    }

    /// Whether Enter on it runs the command now instead of waiting for an argument.
    pub fn runs(c: Candidate) bool {
        return c.value != null or !specs.get(c.command).needs_arg;
    }

    /// The line Enter submits when `runs()`.
    pub fn line(c: Candidate, gpa: std.mem.Allocator) ![]u8 {
        if (c.value) |v| return std.fmt.allocPrint(gpa, "{s} {s}", .{ slashName(c.command), v });
        return gpa.dupe(u8, slashName(c.command));
    }
};

pub const effort_choices = blk: {
    var choices: [provider.Config.effort_values.len]Choice = undefined;
    for (provider.Config.effort_values, &choices) |v, *c| c.* = .{ .value = v, .label = v, .detail = "" };
    const final = choices;
    break :blk final;
};

/// Prefix matches for `input`: command names before the first space,
/// then argument choices for commands that have them.
pub fn candidates(input: []const u8, sessions: []const Choice, tasks: []const Choice, out: []Candidate) []Candidate {
    if (input.len == 0 or input[0] != '/' or std.mem.indexOfScalar(u8, input, '\n') != null) return out[0..0];
    var n: usize = 0;
    const space = std.mem.indexOfScalar(u8, input, ' ') orelse {
        const prefix = input[1..];
        for (std.enums.values(Group)) |group| {
            for (std.enums.values(Command)) |c| {
                if (n == out.len) return out[0..n];
                if (specs.get(c).group != group) continue;
                if (!std.mem.startsWith(u8, @tagName(c), prefix)) continue;
                const spec = specs.get(c);
                out[n] = .{ .command = c, .label = slashName(c), .detail = spec.help };
                n += 1;
            }
        }
        return out[0..n];
    };
    const command = std.meta.stringToEnum(Command, input[1..space]) orelse return out[0..0];
    const arg = std.mem.trimStart(u8, input[space + 1 ..], " ");
    const choices: []const Choice = switch (specs.get(command).choices) {
        .none => return out[0..0],
        .efforts => &effort_choices,
        .sessions => sessions,
        .tasks => tasks,
    };
    for (choices) |choice| {
        if (n == out.len) break;
        if (!std.mem.startsWith(u8, choice.value, arg)) continue;
        out[n] = .{ .command = command, .value = choice.value, .label = choice.label, .detail = choice.detail };
        n += 1;
    }
    return out[0..n];
}

pub fn groupName(group: Group) []const u8 {
    return switch (group) {
        .send => "Send",
        .view => "View",
        .session => "Session",
    };
}

pub fn reflectHelp(buf: []u8, repo: ?[]const u8) []const u8 {
    return if (repo) |r| std.fmt.bufPrint(buf, "publish issue drafts: {s}", .{r}) catch "publish issue drafts (see /help)" else "review session · issue publishing off";
}

pub fn helpText(gpa: std.mem.Allocator, issue_repo: ?[]const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var reflect_buf: [512]u8 = undefined;
    for (std.enums.values(Group)) |group| {
        try text.print(gpa, "{s}\n", .{groupName(group)});
        for (std.enums.values(Command)) |c| {
            const spec = specs.get(c);
            if (spec.group != group) continue;
            try text.print(gpa, "  {s}{s}{s} · {s}\n", .{ slashName(c), if (spec.args.len > 0) " " else "", spec.args, if (c == .reflect) reflectHelp(&reflect_buf, issue_repo) else spec.help });
        }
        try text.append(gpa, '\n');
    }
    try text.appendSlice(gpa, keys);
    return text.toOwnedSlice(gpa);
}

const testing = std.testing;

pub fn execute(app: *App, c: Command, arg: []const u8, line: []const u8) !void {
    const gpa = app.gpa;
    const session = app.session;
    switch (c) {
        .status => {
            const skills = session.log.skills;
            var suffix: std.ArrayList(u8) = .empty;
            defer suffix.deinit(gpa);
            if (skills.skipped.len > 0) try suffix.print(gpa, " · {d} invalid/skipped", .{skills.skipped.len});
            if (skills.missing > 0) try suffix.print(gpa, " · {d} missing", .{skills.missing});
            try app.report(.info, "Skills: {d} on · {d} found{s}", .{ skills.count, skills.found, suffix.items });
            var text: @import("bill.zig").Text = .{};
            try app.report(.info, "{s} · effort {s} · context {d}%\n{s}", .{ app.cfg.model, app.cfg.effectiveEffort(), app.context * 100 / @max(app.cfg.context_window, 1), if (app.last_summary) |summary| text.details(summary) else "No completed turn yet." });
        },
        .skills => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const module = @import("../session/skills.zig");
            const cwd = try std.process.currentPathAlloc(app.io, a);
            const root = try @import("../session/instructions.zig").projectRoot(app.io, a, cwd);
            const found = try module.load(app.io, a, session.options.home, session.options.user_home, root);
            const settings = try config.loadSkills(a, app.io, session.options.home);
            if (arg.len > 0) {
                var words = std.mem.tokenizeAny(u8, arg, " \t");
                const action = words.next().?;
                const name = words.next() orelse return app.transcript.add(gpa, .err, "usage: /skills [on|off <name>]");
                if (words.next() != null or (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off"))) return app.transcript.add(gpa, .err, "usage: /skills [on|off <name>]");
                const enabled = std.mem.eql(u8, action, "on");
                const skill = for (found.skills) |skill| {
                    if (std.mem.eql(u8, skill.name, name)) break skill;
                } else null;
                if (enabled and skill == null) return app.report(.err, "skill not found: {s}", .{name});
                if (enabled and skill.?.disabled) return app.report(.err, "skill disables model invocation: {s}", .{name});
                config.saveSkill(gpa, app.io, session.options.home, name, enabled) catch |err| return app.report(.err, "could not save skills: {s}", .{@errorName(err)});
                return app.report(.info, "{s}: {s} · Applies to new sessions.", .{ name, action });
            }
            var text: std.ArrayList(u8) = .empty;
            for (found.skills) |skill| {
                const source = try module.source(a, skill.location, session.options.home, session.options.user_home, root);
                const on = !skill.disabled and config.skillEnabled(settings, skill.name);
                try text.print(a, "{s} · {s} · {s}\n  ", .{ skill.name, source, if (on) @as([]const u8, "on") else "off" });
                const description = try a.dupe(u8, skill.description);
                for (description) |*byte| if (std.ascii.isWhitespace(byte.*)) {
                    byte.* = ' ';
                };
                const preview = @import("format.zig").fit(description, 48);
                try text.print(a, "{s}{s}", .{ preview.text, preview.suffix });
                try text.append(a, '\n');
            }
            if (found.skills.len == 0) try text.appendSlice(a, "No skills found.\n");
            for (settings) |setting| {
                if (!setting.enabled) continue;
                const exists = for (found.skills) |skill| {
                    if (std.mem.eql(u8, setting.name, skill.name)) break true;
                } else false;
                if (!exists) try text.print(a, "{s} · missing · on\n", .{setting.name});
            }
            try text.appendSlice(a, "Applies to new sessions.");
            try app.transcript.add(gpa, .info, text.items);
        },
        .tasks => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const list = try session.tools.background.snapshot(arena.allocator(), app.io);
            const text = try @import("tasks.zig").format(arena.allocator(), list, @import("../sandbox/timing.zig").Execution.now(app.io));
            try app.transcript.add(gpa, .info, text);
        },
        .stop => {
            if (arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\n") != null) return app.transcript.add(gpa, .err, "usage: /stop <id>");
            if (app.turn != null) {
                try session.tools.background.requestStop(gpa, app.io, arg);
                try app.report(.info, "{s}: user stop requested", .{arg});
            } else {
                const text = try @import("../tools/stop.zig").userStop(&session.tools, gpa, arg);
                defer gpa.free(text);
                try app.transcript.add(gpa, .info, text);
            }
        },
        .undo => {
            if (app.turn != null) return app.transcript.add(gpa, .err, "Press Esc to stop the Turn before /undo.");
            if (arg.len != 0) return app.transcript.add(gpa, .err, "usage: /undo");
            const text = session.undo() catch |err| return app.report(.err, "undo failed: {s}; re-read files before continuing", .{@errorName(err)});
            defer gpa.free(text);
            app.context = session.context_tokens;
            try app.transcript.add(gpa, .info, text);
        },
        .help => {
            const text = try helpText(gpa, reflect.issueRepo(app));
            defer gpa.free(text);
            try app.transcript.add(gpa, .info, text);
        },
        .new, .@"resume" => {
            const id = if (c == .new) null else app.menu.resolveSession(app.io, session, arg) catch |err| {
                return app.transcript.add(gpa, .err, switch (err) {
                    error.MissingSessionId => "usage: /resume <id> · type /resume and a space to pick one",
                    error.UnknownSession => "no session here starts with that id",
                    error.AmbiguousSession => "several sessions start with that id; type more of it",
                    else => @errorName(err),
                });
            };
            if (id != null and std.mem.eql(u8, id.?, session.id)) return app.transcript.add(gpa, .info, "already in this session");
            session.reopen(id) catch |err| return app.report(.err, "could not open session: {s}", .{@errorName(err)});
            session.tools.recovery.enabled = true;
            app.transcript.clear(gpa);
            app.background_count = 0;
            try app.transcript.addHistory(gpa, session.history.items);
            app.usage = .{};
            app.steps = 0;
            app.last_summary = null;
            app.context = session.context_tokens;
            try app.report(.info, "{s} session {s}", .{ if (c == .new) "new" else "resumed", session.id[0..8] });
        },
        .copy => {
            const answer = app.transcript.lastAnswer() orelse return app.transcript.add(gpa, .err, "no answer to copy yet");
            try app.vx.copyToSystemClipboard(app.w, answer, gpa);
            try app.report(.info, "copied {d} bytes (needs a terminal with OSC 52 clipboard support)", .{answer.len});
        },
        .effort => {
            if (arg.len > 0) {
                app.cfg.setEffort(arg) catch return app.transcript.add(gpa, .err, "usage: /effort [default|off|none|minimal|low|medium|high|xhigh|max]");
                session.cfg.thinking = app.cfg.thinking;
                session.cfg.reasoning_effort = app.cfg.reasoning_effort;
                session.tools.cfg = session.cfg;
                config.saveEffort(gpa, app.io, session.options.home, arg) catch |err| {
                    try app.report(.err, "effort applied, but could not save {s}/config.toml: {s}", .{ session.options.home, @errorName(err) });
                    return;
                };
                try app.report(.info, "effort: {s} · saved to {s}/config.toml (environment and --effort override saved preferences)", .{ app.cfg.effectiveEffort(), session.options.home });
                return;
            }
            try app.report(.info, "effort: {s} · thinking: {s} · configured: {s} (model support varies)", .{
                app.cfg.effectiveEffort(),
                if (app.cfg.thinking) |on| (if (on) "on" else "off") else "default",
                app.cfg.reasoning_effort orelse "default",
            });
        },
        .js => {
            if (arg.len == 0) return app.transcript.add(gpa, .err, "usage: /js <code>");
            try app.transcript.add(gpa, .user, line);
            defer app.transcript.next_run = session.tools.run_id;
            const ran = try session.run(arg, null);
            const r = ran.outcome;
            app.usage = session.usage;
            defer r.deinit(gpa);
            if (r.logs.len > 0) try app.transcript.add(gpa, .info, std.mem.trimEnd(u8, r.logs, "\n"));
            try app.transcript.add(gpa, if (r.ok) .info else .err, r.text);
            var changes: ChangeText = try .init(gpa, ran.changes);
            defer changes.deinit(gpa);
            if (changes.diff.len > 0) try app.transcript.add(gpa, .info, std.mem.trimEnd(u8, changes.diff, "\n"));
        },
        .compact => {
            app.turn = try Turn.spawn(gpa, session, app.loop, try gpa.dupe(u8, line), true);
            app.live_steps = 0;
            app.turn_runs = 0;
            app.activity = .start(app.io, .compacting);
        },
        .reflect => {
            if (app.cfg.missingKey()) return app.transcript.add(gpa, .err, "no API key");
            const log_path = try std.fmt.allocPrint(gpa, "{s}/sessions/{s}.jsonl", .{ session.options.home, session.id });
            defer gpa.free(log_path);
            const text = try reflect.prompt(gpa, session.id, log_path, reflect.issueRepo(app) orelse reflect.Issues.default_repo, arg);
            errdefer gpa.free(text);
            const focus = try gpa.dupe(u8, arg);
            errdefer gpa.free(focus);
            try app.transcript.add(gpa, .user, line);
            app.turn = try Turn.spawn(gpa, session, app.loop, text, false);
            app.live_steps = 0;
            app.turn_runs = 0;
            app.activity = .start(app.io, .thinking);
            app.reflecting = focus;
        },
    }
}

test "parse tells commands from paths and messages" {
    try testing.expect(parse("hello") == null);
    try testing.expect(parse("/etc/hosts 是什么") == null);
    try testing.expectEqual(Command.effort, parse("/effort high").?.known.command);
    try testing.expectEqualStrings("high", parse("/effort  high ").?.known.arg);
    try testing.expectEqualStrings("nope", parse("/nope x").?.unknown);
    try testing.expectEqual(Command.undo, parse("/undo").?.known.command);
    try testing.expect(allowedWhileBusy("/undo"));
}

test "candidates complete command names, then argument choices" {
    var buf: [16]Candidate = undefined;
    try testing.expectEqual(@as(usize, std.enums.values(Command).len), candidates("/", &.{}, &.{}, &buf).len);
    const co = candidates("/co", &.{}, &.{}, &buf);
    try testing.expectEqual(@as(usize, 2), co.len);
    try testing.expectEqualStrings("/copy", co[0].label);
    try testing.expectEqualStrings("/compact", co[1].label);
    try testing.expectEqual(@as(usize, 0), candidates("/js 1 + 1", &.{}, &.{}, &buf).len);
    try testing.expectEqual(@as(usize, 0), candidates("hi /co", &.{}, &.{}, &buf).len);

    const efforts = candidates("/effort h", &.{}, &.{}, &buf);
    try testing.expectEqual(@as(usize, 1), efforts.len);
    try testing.expectEqualStrings("high", efforts[0].value.?);
    const line = try efforts[0].line(testing.allocator);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("/effort high", line);

    const sessions = [_]Choice{ .{ .value = "abc123", .label = "abc1", .detail = "now" }, .{ .value = "def456", .label = "def4", .detail = "1h" } };
    const picked = candidates("/resume d", &sessions, &.{}, &buf);
    try testing.expectEqual(@as(usize, 1), picked.len);
    try testing.expectEqualStrings("def456", picked[0].value.?);
}

test "accepting a command waits for required arguments only" {
    var buf: [8]Candidate = undefined;
    const js = candidates("/j", &.{}, &.{}, &buf)[0];
    try testing.expect(!js.runs());
    const tab = try js.completion(testing.allocator);
    defer testing.allocator.free(tab);
    try testing.expectEqualStrings("/js ", tab);
    const effort = candidates("/ef", &.{}, &.{}, &buf)[0];
    try testing.expect(effort.runs());
    const help = try helpText(testing.allocator, reflect.Issues.default_repo);
    defer testing.allocator.free(help);
    try testing.expect(std.mem.indexOf(u8, help, "/resume <id>") != null);
}

test "task commands run while busy and stop completes current task ids" {
    try testing.expect(allowedWhileBusy("/tasks"));
    try testing.expect(allowedWhileBusy("/stop r3"));
    var buf: [16]Candidate = undefined;
    const tasks = [_]Choice{.{ .value = "r3", .label = "r3", .detail = "Run" }};
    const selected = candidates("/stop r", &.{}, &tasks, &buf);
    try testing.expectEqual(@as(usize, 1), selected.len);
    try testing.expectEqualStrings("r3", selected[0].value.?);
    try testing.expect(selected[0].runs());
    try testing.expect(!candidates("/stop", &.{}, &tasks, &buf)[0].runs());
}

test "help groups commands and states the real issue destination or disabled state" {
    const a = testing.allocator;
    const on = try helpText(a, "owner/repo");
    defer a.free(on);
    try testing.expect(std.mem.indexOf(u8, on, "Send\n").? < std.mem.indexOf(u8, on, "View\n").?);
    try testing.expect(std.mem.indexOf(u8, on, "publish issue drafts: owner/repo") != null);
    const off = try helpText(a, null);
    defer a.free(off);
    try testing.expect(std.mem.indexOf(u8, off, "issue publishing off") != null);
    try testing.expect(std.mem.indexOf(u8, off, reflect.Issues.default_repo) == null);
}
