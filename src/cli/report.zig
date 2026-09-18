const std = @import("std");
const adapters = @import("../distribute/adapters.zig");
const generate = @import("../distribute/generate.zig");
const json = @import("../json.zig");
const context = @import("context.zig");
const version_mod = @import("version.zig");

pub fn applyReportJson(arena: std.mem.Allocator, report: generate.ApplyReport) error{OutOfMemory}!json.J {
    var tool_values = std.ArrayListUnmanaged(json.J).empty;
    for (report.tools) |tool| try tool_values.append(arena, .{ .string = tool.name() });
    var file_values = std.ArrayListUnmanaged(json.J).empty;
    for (report.files) |file| try file_values.append(arena, .{ .string = file });
    var removed_values = std.ArrayListUnmanaged(json.J).empty;
    for (report.removed) |file| try removed_values.append(arena, .{ .string = file });
    const fields = try arena.dupe(json.Field, &[_]json.Field{
        .{ .key = "tools", .value = .{ .array = tool_values.items } },
        .{ .key = "files", .value = .{ .array = file_values.items } },
        .{ .key = "removed", .value = .{ .array = removed_values.items } },
        .{ .key = "ruleWritten", .value = .{ .boolean = report.rule_written } },
    });
    return .{ .object = fields };
}

pub fn printApplyReport(ctx: *context.Context, label: []const u8, report: generate.ApplyReport) !void {
    var tools: std.Io.Writer.Allocating = .init(ctx.arena);
    for (report.tools, 0..) |tool, index| {
        if (index > 0) try tools.writer.writeAll(", ");
        try tools.writer.writeAll(tool.name());
    }
    var counts: std.Io.Writer.Allocating = .init(ctx.arena);
    try counts.writer.print("{d} files", .{report.files.len});
    if (report.removed.len > 0) try counts.writer.print(", removed {d}", .{report.removed.len});
    try ctx.out.print(try std.fmt.allocPrint(
        ctx.arena,
        "{s} specrail {s} for {s} ({s}).",
        .{ label, version_mod.packageVersion(), tools.written(), counts.written() },
    ));
    if (report.rule_written) try ctx.out.print("Rule block written to AGENTS.md.");
}

pub const Tool = adapters.Tool;
