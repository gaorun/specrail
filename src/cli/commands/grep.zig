const std = @import("std");
const query = @import("../../core/query.zig");
const store = @import("../../core/store.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const json = @import("../../json.zig");

const command_specs = [_]args_mod.Spec{
    .{ .name = "regex", .kind = .boolean },
    .{ .name = "ignore-case", .kind = .boolean },
    .{ .name = "type" },
    .{ .name = "tag" },
    .{ .name = "parent" },
    .{ .name = "depends-on" },
    .{ .name = "limit" },
};

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &command_specs);
    const pattern = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else
        return args_mod.usageError(ctx.arena, "grep requires a pattern argument.", .{});
    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    const limit = try args_mod.numberFrom(ctx.arena, parsed.stringOf("limit"), "limit");

    var index = store.SpecIndex.init(ctx.arena, ctx.io, root);
    const result = query.grepSpecs(ctx.arena, try index.contentEntries(), .{
        .pattern = pattern,
        .regex = parsed.boolOf("regex"),
        // Mirrors the TS default: ignore-case is on unless... it is always on.
        .ignore_case = true,
        .limit = limit,
        .filters = .{
            .node_type = parsed.stringOf("type"),
            .tag = parsed.stringOf("tag"),
            .parent = parsed.stringOf("parent"),
            .depends_on = parsed.stringOf("depends-on"),
        },
    }) catch |err| switch (err) {
        error.InvalidPattern => {
            try ctx.out.err(try std.fmt.allocPrint(
                ctx.arena,
                "Invalid search pattern: Invalid regular expression: malformed or unsupported pattern",
                .{},
            ));
            return 2;
        },
        else => return err,
    };

    if (parsed.boolOf("json")) {
        var match_items = std.ArrayListUnmanaged(json.J).empty;
        for (result.matches) |match| {
            const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
                .{ .key = "path", .value = .{ .string = match.path } },
                .{ .key = "line", .value = .{ .number = @floatFromInt(match.line) } },
                .{ .key = "snippet", .value = .{ .string = match.snippet } },
});
            try match_items.append(ctx.arena, .{ .object = fields });
        }
        const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
            .{ .key = "matches", .value = .{ .array = match_items.items } },
            .{ .key = "truncated", .value = .{ .boolean = result.truncated } },
});
        try ctx.out.print(try json.stringify(ctx.arena, .{ .object = fields }));
        return 0;
    }

    var output: std.Io.Writer.Allocating = .init(ctx.arena);
    const writer = &output.writer;
    if (result.matches.len == 0) {
        try writer.writeAll("No matches.");
    } else {
        if (result.truncated) {
            try writer.print("{d} match(es) (truncated):", .{result.matches.len});
        } else {
            try writer.print("{d} match(es):", .{result.matches.len});
        }
        for (result.matches) |match| {
            try writer.print("\n{s}:{d}: {s}", .{ match.path, match.line, match.snippet });
        }
    }
    try ctx.out.print(std.mem.trimEnd(u8, output.written(), " \t\r\n"));
    return 0;
}
