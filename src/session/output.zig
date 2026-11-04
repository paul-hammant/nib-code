const std = @import("std");
const sandbox = @import("../sandbox.zig");

pub const max_bytes = 16 * 1024;

const Entry = struct {
    first: usize,
    last: usize,
    kind: enum { console, result, @"error" },
    text: []const u8,
    bytes: usize,
    tail: []const u8 = "",
    keep: ?usize = null,

    fn heading(e: Entry, w: *std.Io.Writer, total: usize) !void {
        if (e.first == e.last) {
            try w.print("[entry {d} of {d} ({s})]\n", .{ e.first, total, @tagName(e.kind) });
        } else {
            try w.print("[entries {d}-{d} of {d} ({s})]\n", .{ e.first, e.last, total, @tagName(e.kind) });
        }
    }

    fn omitted(e: Entry, w: *std.Io.Writer, bytes: usize) !void {
        try w.print("[{d} of {d} bytes omitted]\n", .{ bytes, e.bytes });
    }
};

pub fn format(gpa: std.mem.Allocator, o: sandbox.Outcome) ![]u8 {
    if (o.stopped.len == 0) return renderLimit(gpa, o, max_bytes);
    const body = try renderLimit(gpa, o, max_bytes - o.stopped.len - 1);
    defer gpa.free(body);
    return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ body, o.stopped });
}

pub fn stepLimitOutput(a: std.mem.Allocator, output: []const u8, remaining_steps: ?usize) ![]const u8 {
    const remaining = remaining_steps orelse return output;
    if (remaining > 3) return output;
    return std.fmt.allocPrint(a, "{s}\n[{d} Steps left in this Turn]", .{ output, remaining });
}

pub fn formatMessage(gpa: std.mem.Allocator, prefix: []const u8, json: []const u8) ![]u8 {
    const payload = try renderLimit(gpa, .{ .ok = false, .text = @constCast(json), .logs = @constCast("") }, max_bytes - prefix.len);
    defer gpa.free(payload);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, payload });
}

fn renderLimit(gpa: std.mem.Allocator, o: sandbox.Outcome, limit: usize) ![]u8 {
    const logs = std.mem.trimEnd(u8, o.logs, "\n");
    const value: []const u8 = if (o.ok and std.mem.eql(u8, o.text, "undefined")) "" else o.text;
    const sep: []const u8 = if (logs.len > 0 and value.len > 0) "\n" else "";
    const label: []const u8 = if (o.ok and value.len > 0) "result: " else "";
    if (!o.log_truncated and logs.len + value.len + sep.len + label.len <= limit) {
        if (logs.len == 0 and value.len == 0) return gpa.dupe(u8, "(no output)");
        return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ logs, sep, label, value });
    }

    var storage: [sandbox.max_log_entries + 2]Entry = undefined;
    var count: usize = 0;
    var total: usize = 0;
    const tail_bytes = if (o.log_entries.len > 0) o.logs.len - o.log_tail_start else 0;
    const tail_offset = o.log_bytes - tail_bytes;
    for (o.log_entries) |log| {
        const head = o.logs[@min(log.start, o.log_head_bytes)..@min(log.end, o.log_head_bytes)];
        const tail = o.logs[o.log_tail_start + (log.start -| tail_offset) .. o.log_tail_start + (log.end -| tail_offset)];
        const bytes = log.end - log.start;
        storage[count] = .{
            .first = log.first,
            .last = log.last,
            .kind = .console,
            .text = if (tail.len == bytes) tail else head,
            .tail = if (tail.len == bytes) "" else tail,
            .bytes = bytes,
        };
        total = log.last;
        count += 1;
    }
    if (count == 0 and logs.len > 0) {
        total = 1;
        storage[count] = .{ .first = 1, .last = 1, .kind = .console, .text = logs, .bytes = logs.len };
        count += 1;
    }
    if (value.len > 0) {
        total += 1;
        storage[count] = .{ .first = total, .last = total, .kind = if (o.ok) .result else .@"error", .text = value, .bytes = value.len };
        count += 1;
    }
    const entries = storage[0..count];

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var available: usize = limit;
    for (entries) |e| {
        const before = out.written().len;
        try e.heading(&out.writer, total);
        try e.omitted(&out.writer, e.bytes);
        available -= out.written().len - before + 2;
    }
    out.clearRetainingCapacity();

    var remaining = entries.len;
    while (remaining > 0) {
        const share = available / remaining;
        var progress = false;
        for (entries) |*e| {
            if (e.keep == null and e.text.len + e.tail.len <= share) {
                e.keep = e.text.len + e.tail.len;
                available -= e.text.len + e.tail.len;
                remaining -= 1;
                progress = true;
            }
        }
        if (!progress) {
            for (entries) |*e| if (e.keep == null) {
                e.keep = share;
            };
            break;
        }
    }

    for (entries) |e| {
        try e.heading(&out.writer, total);
        const keep = e.keep.?;
        if (keep == e.bytes) {
            try out.writer.writeAll(e.text);
            try out.writer.writeAll(e.tail);
        } else {
            const complete = e.text.len == e.bytes;
            const head_keep = if (complete) (keep + 1) / 2 else @min(e.text.len, keep - @min(e.tail.len, keep / 2));
            const tail_keep = if (complete) keep / 2 else @min(e.tail.len, keep - head_keep);
            const head = trimEnd(e.text[0..head_keep]);
            const suffix = if (complete) e.text else e.tail;
            const tail = trimStart(suffix[suffix.len - tail_keep ..]);
            try out.writer.writeAll(head);
            if (head.len > 0 and head[head.len - 1] != '\n') try out.writer.writeByte('\n');
            try e.omitted(&out.writer, e.bytes - head.len - tail.len);
            try out.writer.writeAll(tail);
        }
        if (out.written().len > 0 and out.written()[out.written().len - 1] != '\n') try out.writer.writeByte('\n');
    }
    std.debug.assert(out.written().len <= limit);
    return out.toOwnedSlice();
}

const trimEnd = @import("../sandbox/console.zig").trimEnd;
const trimStart = @import("../sandbox/console.zig").trimStart;

const testing = std.testing;

fn evaluate(code: []const u8, limits: sandbox.Limits) !sandbox.Outcome {
    return sandbox.eval(testing.allocator, testing.io, code, limits, null, null);
}

test "three console entries retain labels and exact omission bytes" {
    const o = try evaluate("console.log('first'); console.log('middle:' + 'z'.repeat(40000) + ':middle-end'); console.log('last');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try testing.expectEqual(@as(usize, 3), o.log_entries.len);
    try testing.expect(std.mem.startsWith(u8, out, "[entry 1 of 3 (console)]\nfirst\n"));
    try testing.expect(std.mem.indexOf(u8, out, "[entry 2 of 3 (console)]\nmiddle:") != null);
    try testing.expect(std.mem.endsWith(u8, out, ":middle-end\n[entry 3 of 3 (console)]\nlast\n"));
    const shown = std.mem.count(u8, out, "z") + "middle::middle-end\n".len;
    const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of {d} bytes omitted]", .{ (o.log_entries[1].end - o.log_entries[1].start) - shown, (o.log_entries[1].end - o.log_entries[1].start) });
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, out, marker) != null);
}

test "console capture limit preserves later entries and exact omission counts" {
    const o = try evaluate("console.log('first'); console.log('middle:' + 'z'.repeat(90000)); console.log('last');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try testing.expect(o.log_truncated);
    try testing.expectEqual(@as(usize, 90008), (o.log_entries[1].end - o.log_entries[1].start));
    const shown = std.mem.count(u8, out, "z") + "middle:\n".len;
    const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of 90008 bytes omitted]", .{90008 - shown});
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, out, marker) != null);
    try testing.expect(std.mem.endsWith(u8, out, "[entry 3 of 3 (console)]\nlast\n"));
    try testing.expect(std.mem.indexOf(u8, out, "[console output truncated]") == null);
}

test "many console entries have bounded metadata and a numbered omission range" {
    const o = try evaluate("for (let i = 0; i < 10000; i++) console.log('x');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try testing.expectEqual(sandbox.max_log_entries + 1, o.log_entries.len);
    try testing.expect(std.mem.indexOf(u8, out, "[entries 33-9968 of 10000 (console)]") != null);
    try testing.expect(std.mem.endsWith(u8, out, "[entry 10000 of 10000 (console)]\nx\n"));
}

test "small outputs remain unchanged even with more than 64 console calls" {
    const o = try evaluate("for (let i = 0; i < 100; i++) console.log('x');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(std.mem.trimEnd(u8, o.logs, "\n"), out);
}

test "UTF-8 cuts count all omitted bytes including capture loss" {
    for ([_]usize{ 65536, 16385, 1, 0 }) |capture| {
        const o = try evaluate("console.log('你'.repeat(30000));", .{ .max_log_bytes = capture });
        defer o.deinit(testing.allocator);
        const out = try format(testing.allocator, o);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        const shown = std.mem.count(u8, out, "你") * 3 + @intFromBool(capture >= 2);
        const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of 90001 bytes omitted", .{90001 - shown});
        defer testing.allocator.free(marker);
        try testing.expect(std.mem.indexOf(u8, out, marker) != null);
    }
}

test "completion and errors have their own entry and cannot be crowded out by logs" {
    const codes = [_][]const u8{
        "console.log('z'.repeat(40000)); 'result-' + 'y'.repeat(40000) + '-end'",
        "console.log('z'.repeat(90000)); throw new Error('failure-marker');",
        "'result-' + 'y'.repeat(40000) + '-end'",
        "throw new Error('failure-' + 'y'.repeat(40000));",
    };
    for (codes, 0..) |code, i| {
        const o = try evaluate(code, .{});
        defer o.deinit(testing.allocator);
        const out = try format(testing.allocator, o);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.mem.indexOf(u8, out, if (o.ok) "(result)" else "(error)") != null);
        try testing.expect(std.mem.indexOf(u8, out, if (o.ok) "result-" else "failure-") != null);
        if (i == 1) try testing.expect(std.mem.indexOf(u8, out, "Error: failure-marker") != null);
        if (o.ok) try testing.expect(std.mem.indexOf(u8, out, "-end\"") != null);
    }
}

test "UTF-8 cut points" {
    try testing.expectEqualStrings("ab", trimEnd("ab\xe4\xbd"));
    try testing.expectEqualStrings("ab你", trimEnd("ab你"));
    try testing.expectEqualStrings("cd", trimStart("\xbd\xa0cd"));
    try testing.expectEqualStrings("", trimEnd("\xbd\xa0"));
}

test "exact output budget boundaries for console and completion" {
    inline for (.{ "console.log('z'.repeat({d}));", "'z'.repeat({d});" }, 0..) |pattern, kind| {
        for ([_]usize{ max_bytes - 1, max_bytes, max_bytes + 1 }) |size| {
            const n = if (kind == 0) size else size - "result: \"\"".len;
            const source = try std.fmt.allocPrint(testing.allocator, pattern, .{n});
            defer testing.allocator.free(source);
            const o = try evaluate(source, .{});
            defer o.deinit(testing.allocator);
            const out = try format(testing.allocator, o);
            defer testing.allocator.free(out);
            try testing.expect(out.len <= max_bytes);
            if (size <= max_bytes) {
                try testing.expectEqual(size, out.len);
                try testing.expect(std.mem.indexOf(u8, out, "bytes omitted") == null);
            } else {
                try testing.expect(std.mem.indexOf(u8, out, "bytes omitted") != null);
            }
        }
    }
}

test "four-byte UTF-8 capture boundaries" {
    for (0..8) |capture| {
        const o = try evaluate("console.log('😀'.repeat(30000));", .{ .max_log_bytes = capture });
        defer o.deinit(testing.allocator);
        const out = try format(testing.allocator, o);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        const shown = std.mem.count(u8, out, "😀") * 4 + @intFromBool(capture >= 2);
        const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of 120001 bytes omitted", .{120001 - shown});
        defer testing.allocator.free(marker);
        try testing.expect(std.mem.indexOf(u8, out, marker) != null);
    }
}

test "console entry boundaries are calls rather than arguments or lines" {
    const o = try evaluate("console.log('left', {n: 1}, 'a\\nb'); console.warn('z'.repeat(40000)); console.error('right');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "[entry 1 of 3 (console)]\nleft {\"n\":1} a\nb\n[entry 2 of 3 (console)]\n"));
    try testing.expect(std.mem.endsWith(u8, out, "[entry 3 of 3 (console)]\nright\n"));
}

test "oversized single call and cumulative calls preserve real head and tail" {
    const codes = [_][]const u8{
        "console.log('BEGIN-' + '你😀'.repeat(30000) + '-FINAL-SENTINEL');",
        "console.log('BEGIN-'); for (let i = 0; i < 10000; i++) console.log('你😀'.repeat(10)); console.log('-FINAL-SENTINEL');",
    };
    for (codes) |code| {
        const o = try evaluate(code, .{});
        defer o.deinit(testing.allocator);
        try testing.expect(o.log_truncated);
        try testing.expect(std.unicode.utf8ValidateSlice(o.logs));
        try testing.expect(std.mem.startsWith(u8, o.logs, "BEGIN-"));
        try testing.expect(std.mem.endsWith(u8, o.logs, "-FINAL-SENTINEL\n"));
        try testing.expect(o.log_head_bytes + o.logs.len - o.log_tail_start <= 65536);
        try testing.expect(o.log_entries.len <= sandbox.max_log_entries + 1);
        const out = try format(testing.allocator, o);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        try testing.expect(std.mem.indexOf(u8, out, "BEGIN-") != null);
        try testing.expect(std.mem.indexOf(u8, out, "bytes omitted]") != null);
        try testing.expect(std.mem.endsWith(u8, out, "-FINAL-SENTINEL\n"));
    }
}

test "bounded call metadata plus completion preserves original numbering" {
    for ([_]usize{ 64, 65, 66 }) |calls| {
        const code = try std.fmt.allocPrint(testing.allocator, "for (let i = 0; i < {d}; i++) console.log('call-' + i + ':' + '😀'.repeat(600 + i)); 'RESULT-SENTINEL'", .{calls});
        defer testing.allocator.free(code);
        const o = try evaluate(code, .{});
        defer o.deinit(testing.allocator);
        const out = try format(testing.allocator, o);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        try testing.expect(std.mem.indexOf(u8, out, "call-0:") != null);
        const last = try std.fmt.allocPrint(testing.allocator, "call-{d}:", .{calls - 1});
        defer testing.allocator.free(last);
        try testing.expect(std.mem.indexOf(u8, out, last) != null);
        const result = try std.fmt.allocPrint(testing.allocator, "[entry {d} of {d} (result)]\n\"RESULT-SENTINEL\"\n", .{ calls + 1, calls + 1 });
        defer testing.allocator.free(result);
        try testing.expect(std.mem.endsWith(u8, out, result));
    }
}

test "stopped line follows small output without changing the body" {
    const stopped = "[stopped before completion: bash #0, agent #2]";
    const cases = .{
        .{ "", "(no output)" },
        .{ "console.log('hello');", "hello" },
        .{ "console.log('hello'); 42", "hello\nresult: 42" },
        .{ "throw 'failure'", "failure" },
    };
    inline for (cases) |case| {
        const original = try evaluate(case[0], .{});
        defer original.deinit(testing.allocator);
        var o = original;
        o.stopped = stopped;
        const out = try format(testing.allocator, o);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(case[1] ++ "\n" ++ stopped, out);
    }
}

test "stopped line reserves budget at exact body boundaries" {
    const stopped = "[stopped before completion: bash #0, agent #2]";
    const budget = max_bytes - stopped.len - 1;
    for ([_]usize{ budget - 1, budget, budget + 1 }) |size| {
        const logs = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(logs);
        @memset(logs, 'x');
        const out = try format(testing.allocator, .{
            .ok = true,
            .text = @constCast("undefined"),
            .logs = logs,
            .stopped = stopped,
        });
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.mem.endsWith(u8, out, "\n" ++ stopped));
        if (size <= budget) {
            try testing.expectEqual(size + 1 + stopped.len, out.len);
            try testing.expectEqualStrings(logs, out[0..size]);
        } else {
            try testing.expect(std.mem.indexOf(u8, out, "bytes omitted") != null);
        }
    }
}

test "maximum stopped line survives huge console errors and many entries" {
    var stopped: [sandbox.max_stopped_bytes]u8 = undefined;
    @memset(&stopped, 'x');
    const prefix = "[stopped before completion: ";
    const suffix = ", ..., 9000 more]";
    @memcpy(stopped[0..prefix.len], prefix);
    @memcpy(stopped[stopped.len - suffix.len ..], suffix);
    const codes = [_][]const u8{
        "console.log('你😀'.repeat(30000));",
        "throw new Error('failure-' + '你😀'.repeat(30000));",
        "for (let i = 0; i < 10000; i++) console.log('你😀'.repeat(10)); throw new Error('failure-' + '你😀'.repeat(30000));",
    };
    for (codes) |code| {
        const original = try evaluate(code, .{});
        defer original.deinit(testing.allocator);
        var o = original;
        o.stopped = &stopped;
        const out = try format(testing.allocator, o);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.mem.endsWith(u8, out, &stopped));
        try testing.expectEqual(@as(u8, '\n'), out[out.len - stopped.len - 1]);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        try testing.expect(std.mem.indexOf(u8, out, "bytes omitted") != null);
        try testing.expect(std.mem.indexOf(u8, out, if (o.ok) "(console)" else "(error)") != null);
    }
}

test "Step budget metadata leaves unlimited output unchanged and appends after the output budget" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("output", try stepLimitOutput(a, "output", null));
    try t.expectEqualStrings("output", try stepLimitOutput(a, "output", 4));
    try t.expectEqualStrings("output\n[3 Steps left in this Turn]", try stepLimitOutput(a, "output", 3));
    try t.expectEqualStrings("output\n[0 Steps left in this Turn]", try stepLimitOutput(a, "output", 0));
    const full = try a.alloc(u8, 16 * 1024);
    @memset(full, 'x');
    const output = try stepLimitOutput(a, full, 2);
    try t.expectEqualStrings(full, output[0..full.len]);
    try t.expectEqualStrings("\n[2 Steps left in this Turn]", output[full.len..]);
}

test "formatOutcome" {
    const gpa = std.testing.allocator;
    var logs = "a\nb\n".*;
    var text = "1".*;
    const ok = try format(gpa, .{ .ok = true, .text = &text, .logs = &logs });
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("a\nb\nresult: 1", ok);
    var err = "Error: x".*;
    var none = "".*;
    const bad = try format(gpa, .{ .ok = false, .text = &err, .logs = &none });
    defer gpa.free(bad);
    try std.testing.expectEqualStrings("Error: x", bad);
    var undef = "undefined".*;
    const logged = try format(gpa, .{ .ok = true, .text = &undef, .logs = &logs });
    defer gpa.free(logged);
    try std.testing.expectEqualStrings("a\nb", logged);
    const silent = try format(gpa, .{ .ok = true, .text = &undef, .logs = &none });
    defer gpa.free(silent);
    try std.testing.expectEqualStrings("(no output)", silent);
}
