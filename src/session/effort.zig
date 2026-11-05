const std = @import("std");
const provider = @import("../provider.zig");

pub const Declaration = enum { low, medium, high, default };

pub fn fromCode(a: std.mem.Allocator, code: []const u8) !?Declaration {
    const line = std.mem.trim(u8, code[0 .. std.mem.indexOfScalar(u8, code, '\n') orelse code.len], " \t\r");
    const prefix = "// @run:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const parsed = try std.json.parseFromSlice(struct { effort: ?Declaration = null }, a, line[prefix.len..], .{});
    defer parsed.deinit();
    return parsed.value.effort;
}

test "custom Run effort is an optional strict first-line pragma" {
    const t = std.testing;
    try t.expectEqual(@as(?Declaration, null), try fromCode(t.allocator, "console.log('plain')"));
    try t.expectEqual(@as(?Declaration, null), try fromCode(t.allocator, "// ordinary comment\n// @run: {\"effort\":\"low\"}"));
    inline for (.{ Declaration.low, .medium, .high, .default }) |value| {
        const code = " \t// @run: {\"effort\":\"" ++ @tagName(value) ++ "\"}\r\nconsole.log('ok')";
        try t.expectEqual(@as(?Declaration, value), try fromCode(t.allocator, code));
    }
    try t.expectEqual(@as(?Declaration, null), try fromCode(t.allocator, "// @run: {}\n42"));
    try t.expectError(error.InvalidEnumTag, fromCode(t.allocator, "// @run: {\"effort\":\"max\"}\n42"));
    try t.expectError(error.UnknownField, fromCode(t.allocator, "// @run: {\"unknown\":1}\n42"));
    try t.expectError(error.SyntaxError, fromCode(t.allocator, "// @run: invalid\n42"));
}

pub const Pending = struct {
    effort: Declaration,
    ok: bool,

    pub fn record(pending: *?Pending, effort: ?Declaration, ok: bool) void {
        if (effort) |value| pending.* = .{ .effort = value, .ok = ok };
    }
};

pub const Decision = struct {
    cfg: provider.Config,
    metadata: provider.StepEffort,
    downgraded: bool = false,
};

pub fn decide(user: provider.Config, first: bool, pending: ?Pending) Decision {
    const effective = user.effectiveEffort();
    const baseline = if (std.mem.eql(u8, effective, "server default") or
        std.mem.eql(u8, effective, "on (server default effort)")) "default" else effective;
    var result: Decision = .{ .cfg = user, .metadata = .{ .effort = baseline, .source = .default } };
    if (first) return result;
    const declaration = pending orelse return result;
    if (declaration.effort == .default) return result;
    const requested = @tagName(declaration.effort);
    const ceiling = rank(baseline);
    const requested_rank = rank(requested).?;
    if (!declaration.ok or (if (ceiling) |maximum| requested_rank > maximum else declaration.effort != .low)) {
        result.metadata.source = .guard;
        return result;
    }
    result.cfg.setEffort(requested) catch unreachable;
    result.metadata = .{ .effort = result.cfg.effectiveEffort(), .source = .model };
    result.downgraded = ceiling == null or requested_rank < ceiling.?;
    return result;
}

fn rank(effort: []const u8) ?u8 {
    if (std.mem.eql(u8, effort, "off") or std.mem.eql(u8, effort, "none")) return 0;
    inline for (.{ "minimal", "low", "medium", "high", "xhigh", "max" }, 1..) |name, index| {
        if (std.mem.eql(u8, effort, name)) return index;
    }
    return null;
}

test "user effective effort is default and ceiling" {
    const t = std.testing;
    var user: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    const levels = .{ "off", "none", "minimal", "low", "medium", "high", "xhigh", "max" };
    inline for (levels) |level| {
        try user.setEffort(level);
        inline for (.{ Declaration.low, Declaration.medium, Declaration.high }) |requested| {
            const chosen = decide(user, false, .{ .effort = requested, .ok = true });
            const guarded = rank(@tagName(requested)).? > rank(level).?;
            try t.expectEqual(if (guarded) provider.EffortSource.guard else .model, chosen.metadata.source);
            try t.expectEqualStrings(if (guarded) level else @tagName(requested), chosen.metadata.effort);
            try t.expectEqual(!guarded and rank(@tagName(requested)).? < rank(level).?, chosen.downgraded);
            try t.expectEqualStrings(level, user.effectiveEffort());
        }
    }
}

test "first request, one shot, explicit default and failed Run restore user configuration" {
    const t = std.testing;
    var user: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    try user.setEffort("high");
    const low: Pending = .{ .effort = .low, .ok = true };
    try t.expectEqual(provider.EffortSource.default, decide(user, true, low).metadata.source);
    try t.expectEqualStrings("high", decide(user, true, low).metadata.effort);
    const lowered = decide(user, false, low);
    try t.expectEqualStrings("low", lowered.cfg.reasoning_effort.?);
    try t.expect(lowered.downgraded);
    try t.expectEqualStrings("high", decide(user, false, null).metadata.effort);
    const reset = decide(user, false, .{ .effort = .default, .ok = false });
    try t.expectEqual(provider.EffortSource.default, reset.metadata.source);
    try t.expectEqualStrings("high", reset.metadata.effort);
    const failed = decide(user, false, .{ .effort = .low, .ok = false });
    try t.expectEqual(provider.EffortSource.guard, failed.metadata.source);
    try t.expectEqualStrings("high", failed.metadata.effort);
    try t.expect(!failed.downgraded);
}

test "last declaration wins, undeclared Runs do not overwrite and failure belongs to declaring Run" {
    const t = std.testing;
    var user: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    try user.setEffort("high");
    var pending: ?Pending = null;
    Pending.record(&pending, .low, true);
    Pending.record(&pending, null, false);
    try t.expectEqualStrings("low", decide(user, false, pending).metadata.effort);
    Pending.record(&pending, .medium, false);
    try t.expectEqual(provider.EffortSource.guard, decide(user, false, pending).metadata.source);
    Pending.record(&pending, .medium, true);
    try t.expectEqualStrings("medium", decide(user, false, pending).metadata.effort);
    Pending.record(&pending, .default, true);
    try t.expectEqual(provider.EffortSource.default, decide(user, false, pending).metadata.source);
    try t.expectEqualStrings("high", decide(user, false, pending).metadata.effort);
}

test "server default permits only supported lowering declarations and Codex preserves its floor" {
    const t = std.testing;
    var user: provider.Config = .{ .base_url = "", .api_key = "", .model = "gpt-6.1-sol", .provider = .codex };
    const initial = decide(user, false, null);
    try t.expectEqualStrings("default", initial.metadata.effort);
    try t.expect(initial.cfg.reasoning_effort == null);
    inline for (.{ Declaration.low, Declaration.medium, Declaration.high }) |effort| {
        const chosen = decide(user, false, .{ .effort = effort, .ok = true });
        const accepted = effort == .low;
        try t.expectEqual(if (accepted) provider.EffortSource.model else .guard, chosen.metadata.source);
        try t.expectEqualStrings(if (accepted) @tagName(effort) else "default", chosen.metadata.effort);
        try t.expectEqual(accepted, chosen.downgraded);
    }
    try user.setEffort("off");
    try t.expectEqualStrings("low", decide(user, true, null).metadata.effort);
    const capped = decide(user, false, .{ .effort = .high, .ok = true });
    try t.expectEqualStrings("low", capped.metadata.effort);
    try t.expectEqual(provider.EffortSource.guard, capped.metadata.source);
    try t.expectEqualStrings("low", decide(user, false, .{ .effort = .low, .ok = true }).metadata.effort);
}
