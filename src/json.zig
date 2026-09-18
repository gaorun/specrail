const std = @import("std");

/// Replicates JSON.stringify(value, null, 2): two-space indent, `": "`
/// separators, insertion-ordered keys, `{}`/`[]` for empty containers,
/// C0 controls escaped as \u00XX, undefined fields omitted.
pub const J = union(enum) {
    null_value,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const J,
    object: []const Field,
    undefined_value,
};

pub const Field = struct {
    key: []const u8,
    value: J,
};

pub fn stringify(allocator: std.mem.Allocator, value: J) error{OutOfMemory}![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    try write(allocator, &out, value, 0);
    return out.items;
}

fn write(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: J, depth: usize) error{OutOfMemory}!void {
    switch (value) {
        .null_value, .undefined_value => try out.appendSlice(allocator, "null"),
        .boolean => |flag| try out.appendSlice(allocator, if (flag) "true" else "false"),
        .number => |number| {
            var buffer: [48]u8 = undefined;
            if (@floor(number) == number and @abs(number) < 9.007199254740992e15) {
                try out.appendSlice(allocator, std.fmt.bufPrint(&buffer, "{d}", .{@as(i64, @intFromFloat(number))}) catch unreachable);
            } else {
                try out.appendSlice(allocator, std.fmt.bufPrint(&buffer, "{d}", .{number}) catch unreachable);
            }
        },
        .string => |text| try writeString(allocator, out, text),
        .array => |items| {
            if (items.len == 0) {
                try out.appendSlice(allocator, "[]");
                return;
            }
            try out.append(allocator, '[');
            for (items, 0..) |item, index| {
                if (index > 0) try out.append(allocator, ',');
                try out.append(allocator, '\n');
                try writeIndent(allocator, out, depth + 1);
                try write(allocator, out, item, depth + 1);
            }
            try out.append(allocator, '\n');
            try writeIndent(allocator, out, depth);
            try out.append(allocator, ']');
        },
        .object => |fields| {
            var defined: usize = 0;
            for (fields) |field| {
                if (field.value != .undefined_value) defined += 1;
            }
            if (defined == 0) {
                try out.appendSlice(allocator, "{}");
                return;
            }
            try out.append(allocator, '{');
            var first = true;
            for (fields) |field| {
                if (field.value == .undefined_value) continue;
                if (!first) try out.append(allocator, ',');
                first = false;
                try out.append(allocator, '\n');
                try writeIndent(allocator, out, depth + 1);
                try writeString(allocator, out, field.key);
                try out.appendSlice(allocator, ": ");
                try write(allocator, out, field.value, depth + 1);
            }
            try out.append(allocator, '\n');
            try writeIndent(allocator, out, depth);
            try out.append(allocator, '}');
        },
    }
}

fn writeIndent(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), depth: usize) error{OutOfMemory}!void {
    var index: usize = 0;
    while (index < depth * 2) : (index += 1) try out.append(allocator, ' ');
}

fn writeString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) error{OutOfMemory}!void {
    try out.append(allocator, '"');
    for (text) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            8 => try out.appendSlice(allocator, "\\b"),
            12 => try out.appendSlice(allocator, "\\f"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (byte < 0x20) {
                    var buffer: [8]u8 = undefined;
                    try out.appendSlice(allocator, std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{byte}) catch unreachable);
                } else {
                    try out.append(allocator, byte);
                }
            },
        }
    }
    try out.append(allocator, '"');
}
