const std = @import("std");
const store = @import("../../core/store.zig");
const validate_mod = @import("../../core/validate.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const json = @import("../../json.zig");

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &.{});
    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    var index = store.SpecIndex.init(ctx.arena, ctx.io, root);
    const report = try validate_mod.validateGraph(ctx.arena, (try index.graph()).*);
    const valid = validate_mod.isValid(report);

    if (parsed.boolOf("json")) {
        var dangling_items = std.ArrayListUnmanaged(json.J).empty;
        for (report.dangling_links) |link| {
            const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
                .{ .key = "from", .value = .{ .string = link.from } },
                .{ .key = "fromPath", .value = .{ .string = link.from_path } },
                .{ .key = "kind", .value = .{ .string = link.kind.name() } },
                .{ .key = "target", .value = .{ .string = link.target } },
});
            try dangling_items.append(ctx.arena, .{ .object = fields });
        }
        var duplicate_items = std.ArrayListUnmanaged(json.J).empty;
        for (report.duplicate_ids) |duplicate| {
            var path_items = std.ArrayListUnmanaged(json.J).empty;
            for (duplicate.paths) |path| try path_items.append(ctx.arena, .{ .string = path });
            const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
                .{ .key = "id", .value = .{ .string = duplicate.id } },
                .{ .key = "paths", .value = .{ .array = path_items.items } },
});
            try duplicate_items.append(ctx.arena, .{ .object = fields });
        }
        var cycle_items = std.ArrayListUnmanaged(json.J).empty;
        for (report.parent_cycles) |cycle| {
            var id_items = std.ArrayListUnmanaged(json.J).empty;
            for (cycle.ids) |cycle_id| try id_items.append(ctx.arena, .{ .string = cycle_id });
            const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
                .{ .key = "ids", .value = .{ .array = id_items.items } },
});
            try cycle_items.append(ctx.arena, .{ .object = fields });
        }
        const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
            .{ .key = "danglingLinks", .value = .{ .array = dangling_items.items } },
            .{ .key = "duplicateIds", .value = .{ .array = duplicate_items.items } },
            .{ .key = "parentCycles", .value = .{ .array = cycle_items.items } },
});
        try ctx.out.print(try json.stringify(ctx.arena, .{ .object = fields }));
        return if (valid) 0 else 1;
    }

    if (valid) {
        try ctx.out.print("Spec-graph is valid: no issues found.");
        return 0;
    }

    var output: std.Io.Writer.Allocating = .init(ctx.arena);
    const writer = &output.writer;
    var section_count: usize = 0;
    if (report.duplicate_ids.len > 0) {
        if (section_count > 0) try writer.writeAll("\n\n");
        section_count += 1;
        try writer.print("Duplicate ids ({d}):", .{report.duplicate_ids.len});
        for (report.duplicate_ids) |duplicate| {
            try writer.print("\n  {s}: ", .{duplicate.id});
            for (duplicate.paths, 0..) |path, path_index| {
                if (path_index > 0) try writer.writeAll(", ");
                try writer.writeAll(path);
            }
        }
    }
    if (report.dangling_links.len > 0) {
        if (section_count > 0) try writer.writeAll("\n\n");
        section_count += 1;
        try writer.print("Dangling links ({d}):", .{report.dangling_links.len});
        for (report.dangling_links) |link| {
            try writer.print("\n  {s} ({s}) --{s}--> {s} [missing]", .{ link.from, link.from_path, link.kind.name(), link.target });
        }
    }
    if (report.parent_cycles.len > 0) {
        if (section_count > 0) try writer.writeAll("\n\n");
        section_count += 1;
        try writer.print("Parent cycles ({d}):", .{report.parent_cycles.len});
        for (report.parent_cycles) |cycle| {
            try writer.writeAll("\n  ");
            for (cycle.ids) |cycle_id| try writer.print("{s} -> ", .{cycle_id});
            try writer.writeAll(cycle.ids[0]);
        }
    }
    try ctx.out.print(output.written());
    return 1;
}
