const std = @import("std");
const sandbox = @import("../sandbox.zig");

pub const max_bytes = 16 * 1024;

const Entry = struct {
    first: usize,
    last: usize,
    kind: enum { console, result, @"error" },
    text: []const u8,
    bytes: usize,
    keep: ?usize = null,

    fn heading(e: Entry, w: *std.Io.Writer, total: usize) !void {
        if (e.first == e.last) {
            try w.print("[entry {d} of {d} ({s})]\n", .{ e.first, total, @tagName(e.kind) });
        } else {
            try w.print("[entries {d}-{d} of {d} ({s})]\n", .{ e.first, e.last, total, @tagName(e.kind) });
        }
    }

    fn omitted(e: Entry, w: *std.Io.Writer, bytes: usize) !void {
        try w.print("[{d} of {d} bytes omitted{s}]\n", .{ bytes, e.bytes, if (e.text.len < e.bytes and bytes < e.bytes) "; only prefix captured" else "" });
    }
};

pub fn format(gpa: std.mem.Allocator, o: sandbox.Outcome) ![]u8 {
    const logs = std.mem.trimEnd(u8, o.logs, "\n");
    const value: []const u8 = if (o.ok and std.mem.eql(u8, o.text, "undefined")) "" else o.text;
    const sep: []const u8 = if (logs.len > 0 and value.len > 0) "\n" else "";
    const label: []const u8 = if (o.ok and value.len > 0) "result: " else "";
    if (!o.log_truncated and logs.len + value.len + sep.len + label.len <= max_bytes) {
        if (logs.len == 0 and value.len == 0) return gpa.dupe(u8, "(no output)");
        return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ logs, sep, label, value });
    }

    var storage: [sandbox.max_log_entries + 2]Entry = undefined;
    var count: usize = 0;
    var total: usize = 0;
    for (o.log_entries) |log| {
        total += 1;
        storage[count] = .{ .first = total, .last = total, .kind = .console, .text = o.logs[log.start..log.end], .bytes = log.bytes };
        count += 1;
    }
    if (o.omitted_logs.count > 0) {
        storage[count] = .{ .first = total + 1, .last = total + o.omitted_logs.count, .kind = .console, .text = "", .bytes = o.omitted_logs.bytes };
        total += o.omitted_logs.count;
        count += 1;
    } else if (count == 0 and logs.len > 0) {
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
    var available: usize = max_bytes;
    for (entries) |e| {
        const before = out.written().len;
        try e.heading(&out.writer, total);
        try e.omitted(&out.writer, e.bytes);
        if (e.text.len < e.bytes) try out.writer.writeAll("; only prefix captured");
        available -= out.written().len - before + 2;
    }
    out.clearRetainingCapacity();

    var remaining = entries.len;
    while (remaining > 0) {
        const share = available / remaining;
        var progress = false;
        for (entries) |*e| {
            if (e.keep == null and e.text.len <= share) {
                e.keep = e.text.len;
                available -= e.text.len;
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
        } else {
            const complete = e.text.len == e.bytes;
            const head = trimEnd(e.text[0..if (complete) (keep + 1) / 2 else keep]);
            const tail = if (complete) trimStart(e.text[e.text.len - keep / 2 ..]) else "";
            try out.writer.writeAll(head);
            if (head.len > 0 and head[head.len - 1] != '\n') try out.writer.writeByte('\n');
            try e.omitted(&out.writer, e.bytes - head.len - tail.len);
            try out.writer.writeAll(tail);
        }
        if (out.written().len > 0 and out.written()[out.written().len - 1] != '\n') try out.writer.writeByte('\n');
    }
    std.debug.assert(out.written().len <= max_bytes);
    return out.toOwnedSlice();
}

fn trimEnd(s: []const u8) []const u8 {
    var j = s.len;
    while (j > 0 and s.len - j < 3 and (s[j - 1] & 0xC0) == 0x80) j -= 1;
    if (j == 0) return s[0..0];
    const lead = j - 1;
    const len = std.unicode.utf8ByteSequenceLength(s[lead]) catch return s[0..lead];
    return if (lead + len <= s.len) s else s[0..lead];
}

fn trimStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and i < 3 and (s[i] & 0xC0) == 0x80) i += 1;
    return s[i..];
}

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
    const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of {d} bytes omitted]", .{ o.log_entries[1].bytes - shown, o.log_entries[1].bytes });
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, out, marker) != null);
}

test "console capture limit reports partial and wholly omitted entries" {
    const o = try evaluate("console.log('first'); console.log('middle:' + 'z'.repeat(90000)); console.log('last');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try testing.expect(o.log_truncated);
    try testing.expectEqual(@as(usize, 90008), o.log_entries[1].bytes);
    const shown = std.mem.count(u8, out, "z") + "middle:".len;
    const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of 90008 bytes omitted; only prefix captured]", .{90008 - shown});
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, out, marker) != null);
    try testing.expect(std.mem.endsWith(u8, out, "[entry 3 of 3 (console)]\n[5 of 5 bytes omitted]\n"));
    try testing.expect(std.mem.indexOf(u8, out, "[console output truncated]") == null);
}

test "many console entries have bounded metadata and a numbered omission range" {
    const o = try evaluate("for (let i = 0; i < 10000; i++) console.log('x');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try testing.expectEqual(sandbox.max_log_entries, o.log_entries.len);
    try testing.expectEqual(@as(usize, 9936), o.omitted_logs.count);
    try testing.expect(std.mem.endsWith(u8, out, "[entries 65-10000 of 10000 (console)]\n[19872 of 19872 bytes omitted]\n"));
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
        const shown = std.mem.count(u8, out, "你") * 3;
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
        const shown = std.mem.count(u8, out, "😀") * 4;
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
