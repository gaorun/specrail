const std = @import("std");
const graph_mod = @import("../../core/graph.zig");
const query = @import("../../core/query.zig");
const store = @import("../../core/store.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const json = @import("../../json.zig");

const command_specs = [_]args_mod.Spec{
    .{ .name = "direction" },
    .{ .name = "depth" },
    .{ .name = "edge" },
};

fn directionFrom(name: []const u8) ?query.SliceDirection {
    inline for (std.meta.tags(query.SliceDirection)) |direction| {
        if (std.mem.eql(u8, @tagName(direction), name)) return direction;
    }
    return null;
}

fn formatDepth(arena: std.mem.Allocator, depth: ?f64) error{OutOfMemory}![]const u8 {
    const value = depth orelse 1;
    if (@floor(value) == value and @abs(value) < 9.007199254740992e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(value))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

fn nodeJson(arena: std.mem.Allocator, node: *const graph_mod.SpecNode) error{OutOfMemory}!json.J {
    var frontmatter_fields = std.ArrayListUnmanaged(json.Field).empty;
    for (node.frontmatter.entries) |entry| {
        switch (entry.value) {
            .scalar => |text| try frontmatter_fields.append(arena, .{ .key = entry.key, .value = .{ .string = text } }),
            .list => |items| {
                var values = std.ArrayListUnmanaged(json.J).empty;
                for (items) |item| try values.append(arena, .{ .string = item });
                try frontmatter_fields.append(arena, .{ .key = entry.key, .value = .{ .array = values.items } });
            },
        }
    }
    var fields = std.ArrayListUnmanaged(json.Field).empty;
    try fields.append(arena, .{ .key = "id", .value = .{ .string = node.id } });
    try fields.append(arena, .{ .key = "type", .value = .{ .string = node.type } });
    try fields.append(arena, .{ .key = "title", .value = if (node.title) |title| .{ .string = title } else .undefined_value });
    try fields.append(arena, .{ .key = "path", .value = .{ .string = node.path } });
    try fields.append(arena, .{ .key = "frontmatter", .value = .{ .object = frontmatter_fields.items } });
    return .{ .object = fields.items };
}

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &command_specs);
    const id = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else
        return args_mod.usageError(ctx.arena, "graph requires an id argument.", .{});
    const direction = if (parsed.stringOf("direction")) |name|
        directionFrom(name) orelse return args_mod.usageError(ctx.arena, "--direction must be one of: subtree, ancestors, neighbors", .{})
    else
        return args_mod.usageError(ctx.arena, "--direction must be one of: subtree, ancestors, neighbors", .{});
    var edge: ?graph_mod.Kind = null;
    if (parsed.stringOf("edge")) |name| {
        edge = graph_mod.Kind.fromName(name) orelse
            return args_mod.usageError(ctx.arena, "--edge must be one of: parent, depends-on, references, implements", .{});
    }
    const depth = try args_mod.numberFrom(ctx.arena, parsed.stringOf("depth"), "depth");
    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    var index = store.SpecIndex.init(ctx.arena, ctx.io, root);
    const graph = try index.graph();
    if (!graph.nodes.contains(id)) {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "No spec with id \"{s}\".", .{id}));
        return 2;
    }

    const slice = try query.graphSlice(ctx.arena, graph, .{
        .root = id,
        .direction = direction,
        .depth = depth,
        .edge = edge,
    });

    if (parsed.boolOf("json")) {
        var node_items = std.ArrayListUnmanaged(json.J).empty;
        for (slice.nodes) |node| try node_items.append(ctx.arena, try nodeJson(ctx.arena, node));
        var edge_items = std.ArrayListUnmanaged(json.J).empty;
        for (slice.edges) |item| {
            const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
                .{ .key = "from", .value = .{ .string = item.from } },
                .{ .key = "to", .value = .{ .string = item.to } },
                .{ .key = "kind", .value = .{ .string = item.kind.name() } },
});
            try edge_items.append(ctx.arena, .{ .object = fields });
        }
        var missing_items = std.ArrayListUnmanaged(json.J).empty;
        for (slice.missing) |missing| try missing_items.append(ctx.arena, .{ .string = missing });
        const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
            .{ .key = "root", .value = .{ .string = slice.root } },
            .{ .key = "direction", .value = .{ .string = @tagName(slice.direction) } },
            .{ .key = "nodes", .value = .{ .array = node_items.items } },
            .{ .key = "edges", .value = .{ .array = edge_items.items } },
            .{ .key = "missing", .value = .{ .array = missing_items.items } },
});
        try ctx.out.print(try json.stringify(ctx.arena, .{ .object = fields }));
        return 0;
    }

    var output: std.Io.Writer.Allocating = .init(ctx.arena);
    const writer = &output.writer;
    try writer.print("Slice of \"{s}\" ({s}, depth {s}):", .{ id, @tagName(direction), try formatDepth(ctx.arena, depth) });
    try writer.print("\nnodes ({d}):", .{slice.nodes.len});
    for (slice.nodes) |node| {
        if (node.title) |title| {
            try writer.print("\n  {s} [{s}] — {s} ({s})", .{ node.id, node.type, title, node.path });
        } else {
            try writer.print("\n  {s} [{s}] ({s})", .{ node.id, node.type, node.path });
        }
    }
    try writer.print("\nedges ({d}):", .{slice.edges.len});
    for (slice.edges) |item| {
        try writer.print("\n  {s} --{s}--> {s}", .{ item.from, item.kind.name(), item.to });
    }
    if (slice.missing.len > 0) {
        try writer.writeAll("\nmissing targets: ");
        for (slice.missing, 0..) |missing, index_missing| {
            if (index_missing > 0) try writer.writeAll(", ");
            try writer.writeAll(missing);
        }
    }
    try ctx.out.print(output.written());
    return 0;
}
