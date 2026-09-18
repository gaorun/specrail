const std = @import("std");
const errors = @import("../errors.zig");

pub const RULE_BEGIN = "<!-- specrail:rule:begin -->";
pub const RULE_END = "<!-- specrail:rule:end -->";

pub const RULE_TEXT =
    "At the start of a new piece of work, read the specrail-choosing-a-workflow skill for project onboarding or any PR lifecycle work.\n" ++
    "For other new changes, read it only when product scope, user-visible behavior, or architecture remains to decide.\n" ++
    "Continue work already routed to a workflow without routing it again; otherwise proceed directly without loading or announcing one.";

fn distributeError(arena: std.mem.Allocator, comptime format: []const u8, fmt_args: anytype) errors.Error {
    errors.message = std.fmt.allocPrint(arena, format, fmt_args) catch return error.OutOfMemory;
    return error.Distribute;
}

fn readAgents(arena: std.mem.Allocator, io: std.Io, agents_path: []const u8) errors.Error!?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, agents_path, arena, .limited(1 << 22)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => distributeError(arena, "Unable to read {s}: {s}", .{ agents_path, @errorName(err) }),
    };
}

fn writeAgents(arena: std.mem.Allocator, io: std.Io, agents_path: []const u8, content: []const u8) errors.Error!void {
    if (std.fs.path.dirname(agents_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            return distributeError(arena, "Unable to write {s}: {s}", .{ agents_path, @errorName(err) });
        };
    }
    var file = std.Io.Dir.cwd().createFile(io, agents_path, .{ .truncate = true }) catch |err| {
        return distributeError(arena, "Unable to write {s}: {s}", .{ agents_path, @errorName(err) });
    };
    defer file.close(io);
    file.writeStreamingAll(io, content) catch |err| {
        return distributeError(arena, "Unable to write {s}: {s}", .{ agents_path, @errorName(err) });
    };
}

pub fn hasRuleBlock(arena: std.mem.Allocator, io: std.Io, agents_path: []const u8) errors.Error!bool {
    const content = (try readAgents(arena, io, agents_path)) orelse return false;
    return std.mem.indexOf(u8, content, RULE_BEGIN) != null and std.mem.indexOf(u8, content, RULE_END) != null;
}

pub fn upsertRuleBlock(
    arena: std.mem.Allocator,
    io: std.Io,
    agents_path: []const u8,
    rule_text: []const u8,
) errors.Error!void {
    const block = try std.fmt.allocPrint(arena, "{s}\n{s}\n{s}", .{ RULE_BEGIN, rule_text, RULE_END });
    const existing = (try readAgents(arena, io, agents_path)) orelse {
        try writeAgents(arena, io, agents_path, try std.fmt.allocPrint(arena, "{s}\n", .{block}));
        return;
    };
    const start = std.mem.indexOf(u8, existing, RULE_BEGIN);
    const end = std.mem.indexOf(u8, existing, RULE_END);
    const next = if (start == null or end == null or end.? < start.?)
        try std.fmt.allocPrint(arena, "{s}{s}\n{s}\n", .{
            existing,
            if (std.mem.endsWith(u8, existing, "\n")) "" else "\n",
            block,
        })
    else
        try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
            existing[0..start.?],
            block,
            existing[end.? + RULE_END.len ..],
        });
    try writeAgents(arena, io, agents_path, next);
}
