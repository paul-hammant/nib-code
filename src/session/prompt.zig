const std = @import("std");
const tools = @import("../tools.zig");
const sandbox = @import("../sandbox.zig");

pub const tools_json =
    \\[{"type":"function","function":{"name":"run",
    \\"description":"Run JavaScript in a fresh sandbox. The `tools` API it can call is described in the system prompt.",
    \\"parameters":{"type":"object","properties":{"code":{"type":"string",
    \\"description":"JavaScript source. Top-level await is allowed; the last expression's value is returned."},
    \\"effort":{"type":"string","enum":["low","medium","high","default"],
    \\"description":"Reasoning effort for only the next model request after this Run; default restores the user setting."}},
    \\"required":["code"]}}}]
;

/// Prompt lines that compensate for current models instead of stating facts. Each id is registered in
/// docs/compromises.md; NIB_PATCHES_OFF=<id,...|all> drops them so their effect can be measured.
pub const patches = [_]struct { id: []const u8, text: []const u8 }{
    .{
        .id = "json-escape",
        .text =
        \\For file/shell text with backticks, ${ or backslashes, use JSON-escaped double-quoted strings, not template literals, e.g. content: "` ${x} \\path \"quoted\"\n"
        ,
    },
    .{ .id = "no-shell-search", .text = "Search with tools.grep/tools.glob, not shell rg/find/grep." },
};

pub fn patchLines(a: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ![]const u8 {
    const off = if (environ) |e| e.get("NIB_PATCHES_OFF") orelse "" else "";
    var out: std.ArrayList(u8) = .empty;
    for (patches) |patch| {
        if (patchDisabled(off, patch.id)) continue;
        try out.print(a, "- {s}\n", .{patch.text});
    }
    return out.toOwnedSlice(a);
}

fn patchDisabled(off: []const u8, id: []const u8) bool {
    var ids = std.mem.splitScalar(u8, off, ',');
    while (ids.next()) |raw| {
        const item = std.mem.trim(u8, raw, " ");
        if (std.mem.eql(u8, item, "all") or std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

pub fn disabledPatches(a: std.mem.Allocator, environ: ?*const std.process.Environ.Map) !?[]const []const u8 {
    const off = if (environ) |e| e.get("NIB_PATCHES_OFF") orelse "" else "";
    var ids: std.ArrayList([]const u8) = .empty;
    for (patches) |patch| {
        if (patchDisabled(off, patch.id)) try ids.append(a, patch.id);
    }
    if (ids.items.len == 0) return null;
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return try ids.toOwnedSlice(a);
}

pub fn systemSha(base: []const u8) [12]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(base, &digest, .{});
    return std.fmt.bytesToHex(digest[0..6].*, .lower);
}

pub const system_template =
    \\You are nib, a coding agent working in {s}.
    \\
    \\You act by calling the `run` tool with JavaScript. Each call runs in a fresh sandbox: no variables survive between calls, so write anything you need later to a file. The script can affect the outside world only through these functions:
    \\
    \\```js
    \\{s}```
    \\
    \\Writing scripts:
    \\- Top-level `await` works. Each Step is a full model round trip, usually 10 s or more; one Run can read several files, make all independent edits, then build and test, returning only what you need (such as failures).
    \\- The last expression and console.log output share 16 KiB per Run, truncated by console call and final result with markers; filter in JS first; tool results inside JS remain complete.
    \\- run's effort sets reasoning for only the next model request; lower effort answers faster but reasons less.
    \\{s}
    \\When the task is done, answer the user directly without calling the tool.
;

pub fn turnBudgetText(a: std.mem.Allocator, system: []const u8, max_steps: ?usize, user_text: []const u8) ![]const u8 {
    const marker = "This Turn may use at most ";
    if (max_steps) |limit| {
        const fact = try stepLimitPrompt(a, "", limit);
        if (std.mem.indexOf(u8, system, fact[1..]) == null)
            return std.fmt.allocPrint(a, "[Current Turn budget; configuration changed since the system prompt was recorded]{s}\n\n{s}", .{ fact, user_text });
    } else if (std.mem.indexOf(u8, system, marker) != null) {
        return std.fmt.allocPrint(a, "[Current Turn budget: no Step limit; configuration changed since the system prompt was recorded]\n\n{s}", .{user_text});
    }
    return a.dupe(u8, user_text);
}

pub fn stepLimitPrompt(a: std.mem.Allocator, base: []const u8, max_steps: ?usize) ![]const u8 {
    const limit = max_steps orelse return base;
    return std.fmt.allocPrint(a, "{s}\nThis Turn may use at most {d} Steps; when they run out, the Turn stops without another model request.", .{ base, limit });
}

test "system prompt documents every tool in JavaScript" {
    const gpa = std.testing.allocator;
    var host: tools.Tools = .{ .io = std.testing.io, .home = "/unused", .cfg = .{ .provider = .codex, .base_url = "", .api_key = "", .model = @import("../provider/codex.zig").default_model } };
    const docs = try host.documentation(gpa);
    defer gpa.free(docs);
    const lines = try patchLines(gpa, null);
    defer gpa.free(lines);
    const prompt = try std.fmt.allocPrint(gpa, system_template, .{ "/work", docs, lines });
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "```js\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "{{llm_options}}") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TypeScript") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "backticks, ${ or backslashes") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "last expression and console.log output share 16 KiB per Run") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "tool results inside JS remain complete") != null);
    for (tools.names) |name| {
        const call = try std.fmt.allocPrint(gpa, "async {s}(", .{name});
        defer gpa.free(call);
        try std.testing.expect(std.mem.indexOf(u8, prompt, call) != null);
    }
}

test "prompt patches can be disabled individually or all at once" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const all_on = try patchLines(gpa, &env);
    defer gpa.free(all_on);
    for (patches) |patch| try std.testing.expect(std.mem.indexOf(u8, all_on, patch.text) != null);
    try env.put("NIB_PATCHES_OFF", "json-escape");
    const one_off = try patchLines(gpa, &env);
    defer gpa.free(one_off);
    try std.testing.expect(std.mem.indexOf(u8, one_off, "backticks") == null);
    try std.testing.expect(std.mem.indexOf(u8, one_off, "rg/find/grep") != null);
    try env.put("NIB_PATCHES_OFF", "no-shell-search, all");
    const none = try patchLines(gpa, &env);
    defer gpa.free(none);
    try std.testing.expectEqualStrings("", none);
}

test "experiment labels hash exact base text and normalize actual disabled patches" {
    const t = std.testing;
    try t.expectEqualStrings("cae662172fd4", &systemSha("base"));
    try t.expect(!std.mem.eql(u8, &systemSha("base"), &systemSha("base changed")));
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    try t.expectEqual(null, try disabledPatches(a, &env));
    try env.put("NIB_PATCHES_OFF", "unknown, no-shell-search, json-escape, json-escape");
    const normalized = (try disabledPatches(a, &env)).?;
    try t.expectEqual(@as(usize, 2), normalized.len);
    try t.expectEqualStrings("json-escape", normalized[0]);
    try t.expectEqualStrings("no-shell-search", normalized[1]);
    try env.put("NIB_PATCHES_OFF", "all");
    const all = (try disabledPatches(a, &env)).?;
    try t.expectEqual(patches.len, all.len);
    for (patches) |patch| {
        var found = false;
        for (all) |id| found = found or std.mem.eql(u8, id, patch.id);
        try t.expect(found);
    }
    try env.put("NIB_PATCHES_OFF", "unknown");
    try t.expectEqual(null, try disabledPatches(a, &env));
}

test "json-escape patch example survives JS parsing verbatim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const marker = "e.g. content: ";
    const text = patches[0].text;
    const example = text[std.mem.indexOf(u8, text, marker).? + marker.len ..];
    const code = try std.fmt.allocPrint(std.testing.allocator, "await tools.write({{path: '.zig-cache/tmp/{s}/f', content: {s}}})", .{ tmp.sub_path, example });
    defer std.testing.allocator.free(code);
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(home);
    var t: tools.Tools = .{ .io = std.testing.io, .home = home };
    defer t.file_state.deinit(std.testing.allocator);
    const result = try sandbox.eval(std.testing.allocator, std.testing.io, code, .{}, t.host(), null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok);
    const content = try tmp.dir.readFileAlloc(std.testing.io, "f", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("` ${x} \\path \"quoted\"\n", content);
}

test "run schema exposes optional one-shot effort enum" {
    const t = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, tools_json, .{});
    defer parsed.deinit();
    const parameters = parsed.value.array.items[0].object.get("function").?.object.get("parameters").?;
    const required = parameters.object.get("required").?.array.items;
    try t.expectEqual(@as(usize, 1), required.len);
    try t.expectEqualStrings("code", required[0].string);
    const values = parameters.object.get("properties").?.object.get("effort").?.object.get("enum").?.array.items;
    try t.expectEqual(@as(usize, 4), values.len);
    inline for (.{ "low", "medium", "high", "default" }, 0..) |value, index| try t.expectEqualStrings(value, values[index].string);
}

test "Step budget facts leave unlimited prompts unchanged" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "unchanged system prompt";
    const unlimited = try stepLimitPrompt(a, base, null);
    try t.expectEqual(base.ptr, unlimited.ptr);
    try t.expectEqualStrings(&systemSha(base), &systemSha(unlimited));
    const limited = try stepLimitPrompt(a, base, 5);
    try t.expectEqualStrings("unchanged system prompt\nThis Turn may use at most 5 Steps; when they run out, the Turn stops without another model request.", limited);
}

test "resumed Turns expose budget changes without rewriting the original system" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const system = try stepLimitPrompt(a, "base", 5);
    try t.expectEqualStrings("prompt", try turnBudgetText(a, system, 5, "prompt"));
    try t.expectEqualStrings("prompt", try turnBudgetText(a, "base", null, "prompt"));
    const enabled = try turnBudgetText(a, "base", 1, "prompt");
    try t.expect(std.mem.indexOf(u8, enabled, "at most 1 Steps") != null);
    const changed = try turnBudgetText(a, system, 7, "prompt");
    try t.expect(std.mem.indexOf(u8, changed, "at most 7 Steps") != null);
    const disabled = try turnBudgetText(a, system, null, "prompt");
    try t.expect(std.mem.indexOf(u8, disabled, "no Step limit") != null);
    try t.expect(std.mem.endsWith(u8, disabled, "\n\nprompt"));
}
