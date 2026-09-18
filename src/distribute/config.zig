const std = @import("std");
const json = @import("../json.zig");
const adapters = @import("adapters.zig");
const errors = @import("../errors.zig");

pub const CONFIG_DIR = ".specrail";
pub const CONFIG_PATH = ".specrail/config.json";

pub const DistributeConfig = struct {
    version: []const u8,
    tools: []const adapters.Tool,
    files: []const []const u8,
};

fn distributeError(arena: std.mem.Allocator, comptime format: []const u8, fmt_args: anytype) errors.Error {
    errors.message = std.fmt.allocPrint(arena, format, fmt_args) catch return error.OutOfMemory;
    return error.Distribute;
}

pub fn readConfig(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) errors.Error!?DistributeConfig {
    const path = try std.fs.path.join(arena, &.{ root, CONFIG_PATH });
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return distributeError(arena, "Unable to read {s}: {s}", .{ CONFIG_PATH, @errorName(err) }),
    };
    const parsed = std.json.parseFromSlice(std.json.Value, arena, content, .{}) catch |err| {
        return distributeError(arena, "Unable to read {s}: {s}", .{ CONFIG_PATH, @errorName(err) });
    };
    return try configFrom(arena, parsed.value);
}

pub fn writeConfig(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    config: DistributeConfig,
) errors.Error!void {
    const path = try std.fs.path.join(arena, &.{ root, CONFIG_PATH });
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            return distributeError(arena, "Unable to write {s}: {s}", .{ CONFIG_PATH, @errorName(err) });
        };
    }
    var tool_values = std.ArrayListUnmanaged(json.J).empty;
    for (config.tools) |tool| try tool_values.append(arena, .{ .string = tool.name() });
    var file_values = std.ArrayListUnmanaged(json.J).empty;
    for (config.files) |file| try file_values.append(arena, .{ .string = file });
    const fields = try arena.dupe(json.Field, &[_]json.Field{
        .{ .key = "version", .value = .{ .string = config.version } },
        .{ .key = "tools", .value = .{ .array = tool_values.items } },
        .{ .key = "files", .value = .{ .array = file_values.items } },
    });
    const text = try std.fmt.allocPrint(arena, "{s}\n", .{try json.stringify(arena, .{ .object = fields })});

    var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch |err| {
        return distributeError(arena, "Unable to write {s}: {s}", .{ CONFIG_PATH, @errorName(err) });
    };
    defer file.close(io);
    file.writeStreamingAll(io, text) catch |err| {
        return distributeError(arena, "Unable to write {s}: {s}", .{ CONFIG_PATH, @errorName(err) });
    };
}

fn configFrom(arena: std.mem.Allocator, parsed: std.json.Value) errors.Error!DistributeConfig {
    if (parsed != .object) return distributeError(arena, "{s} must be a JSON object", .{CONFIG_PATH});
    const object = parsed.object;

    const version_value = object.get("version") orelse
        return distributeError(arena, "{s} must declare a specrail version", .{CONFIG_PATH});
    if (version_value != .string or version_value.string.len == 0) {
        return distributeError(arena, "{s} must declare a specrail version", .{CONFIG_PATH});
    }

    const tools_value = object.get("tools") orelse
        return distributeError(arena, "{s} tools must come from: qoder, claude, codex, pi", .{CONFIG_PATH});
    if (tools_value != .array) {
        return distributeError(arena, "{s} tools must come from: qoder, claude, codex, pi", .{CONFIG_PATH});
    }
    var tools = std.ArrayListUnmanaged(adapters.Tool).empty;
    for (tools_value.array.items) |item| {
        if (item != .string) {
            return distributeError(arena, "{s} tools must come from: qoder, claude, codex, pi", .{CONFIG_PATH});
        }
        const tool = adapters.Tool.fromName(item.string) orelse
            return distributeError(arena, "{s} tools must come from: qoder, claude, codex, pi", .{CONFIG_PATH});
        try tools.append(arena, tool);
    }

    const files_value = object.get("files") orelse
        return distributeError(arena, "{s} files must be root-relative paths", .{CONFIG_PATH});
    if (files_value != .array) {
        return distributeError(arena, "{s} files must be root-relative paths", .{CONFIG_PATH});
    }
    var files = std.ArrayListUnmanaged([]const u8).empty;
    for (files_value.array.items) |item| {
        if (item != .string or !isManifestPath(item.string)) {
            return distributeError(arena, "{s} files must be root-relative paths", .{CONFIG_PATH});
        }
        try files.append(arena, item.string);
    }

    return .{ .version = version_value.string, .tools = tools.items, .files = files.items };
}

fn isManifestPath(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return false;
    var iterator = std.mem.splitScalar(u8, value, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}
