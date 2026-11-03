const std = @import("std");
const provider = @import("../provider.zig");

pub const Command = enum { help, new, @"resume", compact, effort, copy, reflect, js };

pub const Choices = enum { none, efforts, sessions };

pub const Spec = struct {
    args: []const u8 = "",
    help: []const u8,
    /// Usable while a Turn is running.
    while_busy: bool = false,
    choices: Choices = .none,
    /// Accepting the bare command waits for an argument instead of running.
    needs_arg: bool = false,
};

pub const specs = std.enums.EnumArray(Command, Spec).init(.{
    .help = .{ .help = "list commands and keys", .while_busy = true },
    .new = .{ .help = "start a new session in this directory" },
    .@"resume" = .{ .args = "<id>", .help = "switch to an earlier session in this directory", .choices = .sessions, .needs_arg = true },
    .compact = .{ .help = "summarize earlier history now" },
    .effort = .{ .args = "[level]", .help = "show or set reasoning effort", .choices = .efforts },
    .copy = .{ .help = "copy the last answer to the clipboard", .while_busy = true },
    .reflect = .{ .args = "[focus]", .help = "review this session for harness problems; saved to reflections.md" },
    .js = .{ .args = "<code>", .help = "run JavaScript in the sandbox", .needs_arg = true },
});

pub const keys = "enter send · shift+enter newline · esc cancel · ctrl+o expand runs · PgUp/PgDn, shift+↑↓ or wheel scroll · ↑ input history · ctrl+c quit";

const slash_names = blk: {
    var names: [std.enums.values(Command).len][]const u8 = undefined;
    for (std.enums.values(Command), &names) |c, *n| n.* = "/" ++ @tagName(c);
    const final = names;
    break :blk final;
};

pub fn slashName(c: Command) []const u8 {
    return slash_names[@intFromEnum(c)];
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
pub fn candidates(input: []const u8, sessions: []const Choice, out: []Candidate) []Candidate {
    if (input.len == 0 or input[0] != '/' or std.mem.indexOfScalar(u8, input, '\n') != null) return out[0..0];
    var n: usize = 0;
    const space = std.mem.indexOfScalar(u8, input, ' ') orelse {
        const prefix = input[1..];
        for (std.enums.values(Command)) |c| {
            if (n == out.len) break;
            if (!std.mem.startsWith(u8, @tagName(c), prefix)) continue;
            const spec = specs.get(c);
            out[n] = .{ .command = c, .label = slashName(c), .detail = spec.help };
            n += 1;
        }
        return out[0..n];
    };
    const command = std.meta.stringToEnum(Command, input[1..space]) orelse return out[0..0];
    const arg = std.mem.trimStart(u8, input[space + 1 ..], " ");
    const choices: []const Choice = switch (specs.get(command).choices) {
        .none => return out[0..0],
        .efforts => &effort_choices,
        .sessions => sessions,
    };
    for (choices) |choice| {
        if (n == out.len) break;
        if (!std.mem.startsWith(u8, choice.value, arg)) continue;
        out[n] = .{ .command = command, .value = choice.value, .label = choice.label, .detail = choice.detail };
        n += 1;
    }
    return out[0..n];
}

pub fn helpText(gpa: std.mem.Allocator) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (std.enums.values(Command)) |c| {
        const spec = specs.get(c);
        try text.print(gpa, "{s}{s}{s} — {s}{s}\n", .{ slashName(c), if (spec.args.len > 0) " " else "", spec.args, spec.help, if (spec.while_busy) " (also while working)" else "" });
    }
    try text.appendSlice(gpa, keys);
    return text.toOwnedSlice(gpa);
}

const testing = std.testing;

test "parse tells commands from paths and messages" {
    try testing.expect(parse("hello") == null);
    try testing.expect(parse("/etc/hosts 是什么") == null);
    try testing.expectEqual(Command.effort, parse("/effort high").?.known.command);
    try testing.expectEqualStrings("high", parse("/effort  high ").?.known.arg);
    try testing.expectEqualStrings("nope", parse("/nope x").?.unknown);
}

test "candidates complete command names, then argument choices" {
    var buf: [16]Candidate = undefined;
    try testing.expectEqual(@as(usize, std.enums.values(Command).len), candidates("/", &.{}, &buf).len);
    const co = candidates("/co", &.{}, &buf);
    try testing.expectEqual(@as(usize, 2), co.len);
    try testing.expectEqualStrings("/compact", co[0].label);
    try testing.expectEqualStrings("/copy", co[1].label);
    try testing.expectEqual(@as(usize, 0), candidates("/js 1 + 1", &.{}, &buf).len);
    try testing.expectEqual(@as(usize, 0), candidates("hi /co", &.{}, &buf).len);

    const efforts = candidates("/effort h", &.{}, &buf);
    try testing.expectEqual(@as(usize, 1), efforts.len);
    try testing.expectEqualStrings("high", efforts[0].value.?);
    const line = try efforts[0].line(testing.allocator);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("/effort high", line);

    const sessions = [_]Choice{ .{ .value = "abc123", .label = "abc1", .detail = "now" }, .{ .value = "def456", .label = "def4", .detail = "1h" } };
    const picked = candidates("/resume d", &sessions, &buf);
    try testing.expectEqual(@as(usize, 1), picked.len);
    try testing.expectEqualStrings("def456", picked[0].value.?);
}

test "accepting a command waits for required arguments only" {
    var buf: [8]Candidate = undefined;
    const js = candidates("/j", &.{}, &buf)[0];
    try testing.expect(!js.runs());
    const tab = try js.completion(testing.allocator);
    defer testing.allocator.free(tab);
    try testing.expectEqualStrings("/js ", tab);
    const effort = candidates("/ef", &.{}, &buf)[0];
    try testing.expect(effort.runs());
    const help = try helpText(testing.allocator);
    defer testing.allocator.free(help);
    try testing.expect(std.mem.indexOf(u8, help, "/resume <id>") != null);
}
