const std = @import("std");
const openai = @import("provider/openai.zig");

pub const Event = union(enum) {
    /// Slices are valid only during the callback.
    delta: struct { kind: openai.Kind, text: []const u8 },
    run_start: []const u8,
    run_end: struct { ok: bool, output: []const u8 },
    retry: struct { attempt: u32, delay_ms: u64, reason: []const u8 },
    notice: []const u8,
};

pub const JsonEvent = union(enum) {
    start: struct { session_id: []const u8 },
    event: Event,
    end: End,
    @"error": struct { message: []const u8 },

    pub const End = struct { text: []const u8, usage: openai.Usage, steps: u32 };

    pub fn jsonStringify(value: JsonEvent, writer: *std.json.Stringify) !void {
        switch (value) {
            .event => |event| try writer.write(event),
            inline else => |payload, tag| {
                try writer.beginObject();
                try writer.objectField(@tagName(tag));
                try writer.write(payload);
                try writer.endObject();
            },
        }
    }

    pub fn write(value: JsonEvent, writer: *std.Io.Writer) !void {
        try writer.print("{f}\n", .{std.json.fmt(value, .{})});
        try writer.flush();
    }
};
