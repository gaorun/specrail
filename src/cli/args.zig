const std = @import("std");
const errors = @import("../errors.zig");

pub const Error = errors.Error;

pub const Kind = enum { string, boolean };

pub const Spec = struct {
    name: []const u8,
    short: ?u8 = null,
    kind: Kind = .string,
    multiple: bool = false,
};

pub const GLOBAL_SPECS = [_]Spec{
    .{ .name = "root" },
    .{ .name = "json", .kind = .boolean },
    .{ .name = "help", .kind = .boolean, .short = 'h' },
    .{ .name = "version", .kind = .boolean, .short = 'v' },
};

pub const Value = union(enum) {
    boolean: bool,
    string: []const u8,
    list: std.ArrayListUnmanaged([]const u8),
};

pub const Parsed = struct {
    values: std.StringHashMapUnmanaged(Value) = .empty,
    positionals: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn boolOf(self: *const Parsed, name: []const u8) bool {
        const value = self.values.get(name) orelse return false;
        return switch (value) {
            .boolean => |flag| flag,
            else => false,
        };
    }

    pub fn stringOf(self: *const Parsed, name: []const u8) ?[]const u8 {
        const value = self.values.get(name) orelse return null;
        return switch (value) {
            .string => |text| text,
            else => null,
        };
    }

    pub fn listOf(self: *const Parsed, name: []const u8) []const []const u8 {
        const value = self.values.get(name) orelse return &.{};
        return switch (value) {
            .list => |items| items.items,
            else => &.{},
        };
    }
};

/// Mirrors node:util parseArgs in strict mode with allowPositionals: true,
/// including its error message text.
pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    command_specs: []const Spec,
) errors.Error!Parsed {
    var parsed: Parsed = .{};
    var index: usize = 0;
    var only_positional = false;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (only_positional) {
            parsed.positionals.append(allocator, token) catch return error.OutOfMemory;
            continue;
        }
        if (std.mem.eql(u8, token, "--")) {
            only_positional = true;
            continue;
        }
        if (std.mem.startsWith(u8, token, "--")) {
            index = try handleLong(allocator, &parsed, argv, index, command_specs);
        } else if (token.len > 1 and token[0] == '-') {
            index = try handleShort(allocator, &parsed, argv, index, command_specs);
        } else {
            parsed.positionals.append(allocator, token) catch return error.OutOfMemory;
        }
    }
    if (parsed.boolOf("help")) return error.HelpRequested;
    if (parsed.boolOf("version")) return error.VersionRequested;
    return parsed;
}

fn findSpec(command_specs: []const Spec, name: []const u8) ?Spec {
    for (command_specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    for (GLOBAL_SPECS) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

fn findShort(command_specs: []const Spec, short: u8) ?Spec {
    for (command_specs) |spec| {
        if (spec.short) |c| if (c == short) return spec;
    }
    for (GLOBAL_SPECS) |spec| {
        if (spec.short) |c| if (c == short) return spec;
    }
    return null;
}

fn handleLong(
    allocator: std.mem.Allocator,
    parsed: *Parsed,
    argv: []const []const u8,
    index: usize,
    command_specs: []const Spec,
) errors.Error!usize {
    const token = argv[index];
    const body = token[2..];
    var name = body;
    var inline_value: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, body, '=')) |equals| {
        name = body[0..equals];
        inline_value = body[equals + 1 ..];
    }
    const spec = findSpec(command_specs, name) orelse return usage(
        allocator,
        "Unknown option '{s}'. To specify a positional argument starting with a '-', place it at the end of the command after '--', as in '-- \"{s}\"",
        .{ token, token },
    );
    switch (spec.kind) {
        .boolean => {
            if (inline_value != null) return usage(allocator, "Option '--{s}' does not take an argument", .{name});
            try setBoolean(allocator, parsed, spec.name);
            return index;
        },
        .string => {
            if (inline_value) |value| {
                try setString(allocator, parsed, spec, value);
                return index;
            }
            if (index + 1 >= argv.len) return usage(allocator, "Option '--{s} <value>' argument missing", .{name});
            const next = argv[index + 1];
            if (next.len > 0 and next[0] == '-') return usage(
                allocator,
                "Option '--{s}' argument is ambiguous.\nDid you forget to specify the option argument for '--{s}'?\nTo specify an option argument starting with a dash use '--{s}=-XYZ'.",
                .{ name, name, name },
            );
            try setString(allocator, parsed, spec, next);
            return index + 1;
        },
    }
}

fn handleShort(
    allocator: std.mem.Allocator,
    parsed: *Parsed,
    argv: []const []const u8,
    index: usize,
    command_specs: []const Spec,
) errors.Error!usize {
    const token = argv[index];
    var position: usize = 1;
    while (position < token.len) : (position += 1) {
        const character = token[position];
        const spec = findShort(command_specs, character) orelse return usage(
            allocator,
            "Unknown option '-{c}'. To specify a positional argument starting with a '-', place it at the end of the command after '--', as in '-- \"-{c}\"",
            .{ character, character },
        );
        switch (spec.kind) {
            .boolean => try setBoolean(allocator, parsed, spec.name),
            .string => {
                const rest = token[position + 1 ..];
                if (rest.len > 0) {
                    const value = if (rest[0] == '=') rest[1..] else rest;
                    try setString(allocator, parsed, spec, value);
                    return index;
                }
                if (index + 1 >= argv.len) return usage(allocator, "Option '-{c} <value>' argument missing", .{character});
                try setString(allocator, parsed, spec, argv[index + 1]);
                return index + 1;
            },
        }
    }
    return index;
}

fn setBoolean(allocator: std.mem.Allocator, parsed: *Parsed, name: []const u8) errors.Error!void {
    parsed.values.put(allocator, name, .{ .boolean = true }) catch return error.OutOfMemory;
}

fn setString(allocator: std.mem.Allocator, parsed: *Parsed, spec: Spec, value: []const u8) errors.Error!void {
    if (!spec.multiple) {
        parsed.values.put(allocator, spec.name, .{ .string = value }) catch return error.OutOfMemory;
        return;
    }
    const entry = parsed.values.getOrPut(allocator, spec.name) catch return error.OutOfMemory;
    if (!entry.found_existing) entry.value_ptr.* = .{ .list = .empty };
    switch (entry.value_ptr.*) {
        .list => |*items| items.append(allocator, value) catch return error.OutOfMemory,
        else => unreachable,
    }
}

pub fn usageError(allocator: std.mem.Allocator, comptime format: []const u8, fmt_args: anytype) errors.Error {
    errors.message = std.fmt.allocPrint(allocator, format, fmt_args) catch return error.OutOfMemory;
    return error.Usage;
}

const usage = usageError;

/// Mirrors JS Number() coercion closely enough for the CLI's numeric flags.
pub fn numberFrom(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
    flag: []const u8,
) errors.Error!?f64 {
    const raw = value orelse return null;
    const number = parseJsNumber(raw) orelse return usage(
        allocator,
        "--{s} must be a number, got \"{s}\"",
        .{ flag, raw },
    );
    if (!std.math.isFinite(number)) return usage(
        allocator,
        "--{s} must be a number, got \"{s}\"",
        .{ flag, raw },
    );
    return number;
}

fn parseJsNumber(raw: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    if (trimmed.len == 0) return 0;
    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        return @floatFromInt(std.fmt.parseInt(u64, trimmed[2..], 16) catch return null);
    }
    if (std.mem.startsWith(u8, trimmed, "0b") or std.mem.startsWith(u8, trimmed, "0B")) {
        return @floatFromInt(std.fmt.parseInt(u64, trimmed[2..], 2) catch return null);
    }
    if (std.mem.startsWith(u8, trimmed, "0o") or std.mem.startsWith(u8, trimmed, "0O")) {
        return @floatFromInt(std.fmt.parseInt(u64, trimmed[2..], 8) catch return null);
    }
    return std.fmt.parseFloat(f64, trimmed) catch null;
}

pub fn rootFrom(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: ?[]const u8,
) (errors.Error || anyerror)![]const u8 {
    const path = root orelse try std.process.currentPathAlloc(io, allocator);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        return usage(allocator, "Root directory does not exist: {s}", .{path});
    };
    if (stat.kind != .directory) {
        return usage(allocator, "Root is not a directory: {s}", .{path});
    }
    return path;
}
