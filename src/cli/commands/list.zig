const std = @import("std");
const graph_mod = @import("../../core/graph.zig");
const parse = @import("../../core/parse.zig");
const store = @import("../../core/store.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const json = @import("../../json.zig");

const command_specs = [_]args_mod.Spec{
    .{ .name = "type" },
    .{ .name = "tag" },
};

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &command_specs);
    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    var index = store.SpecIndex.init(ctx.arena, ctx.io, root);
    const graph = try index.graph();

    var nodes = std.ArrayListUnmanaged(*const graph_mod.SpecNode).empty;
    var iterator = graph.nodes.iterator();
    while (iterator.next()) |kv| {
        const node = kv.value_ptr;
        if (parsed.stringOf("type")) |wanted| {
            if (!std.mem.eql(u8, node.type, wanted)) continue;
        }
        if (parsed.stringOf("tag")) |wanted| {
            var scratch: [1][]const u8 = undefined;
            var found = false;
            for (parse.listField(node.frontmatter, parse.TAGS, &scratch)) |tag| {
                if (std.mem.eql(u8, tag, wanted)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        }
        try nodes.append(ctx.arena, node);
    }
    std.mem.sort(*const graph_mod.SpecNode, nodes.items, {}, struct {
        fn lessThan(_: void, a: *const graph_mod.SpecNode, b: *const graph_mod.SpecNode) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    if (parsed.boolOf("json")) {
        var items = std.ArrayListUnmanaged(json.J).empty;
        for (nodes.items) |node| {
            var fields = std.ArrayListUnmanaged(json.Field).empty;
            try fields.append(ctx.arena, .{ .key = "id", .value = .{ .string = node.id } });
            try fields.append(ctx.arena, .{ .key = "type", .value = .{ .string = node.type } });
            try fields.append(ctx.arena, .{
                .key = "title",
                .value = if (node.title) |title| .{ .string = title } else .undefined_value,
            });
            try fields.append(ctx.arena, .{ .key = "path", .value = .{ .string = node.path } });
            try items.append(ctx.arena, .{ .object = fields.items });
        }
        try ctx.out.print(try json.stringify(ctx.arena, .{ .array = items.items }));
        return 0;
    }

    for (nodes.items) |node| {
        if (node.title) |title| {
            try ctx.out.print(try std.fmt.allocPrint(ctx.arena, "{s} [{s}] — {s} ({s})", .{ node.id, node.type, title, node.path }));
        } else {
            try ctx.out.print(try std.fmt.allocPrint(ctx.arena, "{s} [{s}] ({s})", .{ node.id, node.type, node.path }));
        }
    }
    return 0;
}
