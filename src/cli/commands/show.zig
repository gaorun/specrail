const std = @import("std");
const graph_mod = @import("../../core/graph.zig");
const parse = @import("../../core/parse.zig");
const store = @import("../../core/store.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const json = @import("../../json.zig");

const ResolvedLink = struct {
    kind: graph_mod.Kind,
    target: []const u8,
    path: ?[]const u8,
};

fn frontmatterJson(arena: std.mem.Allocator, fm: parse.Frontmatter) error{OutOfMemory}!json.J {
    var fields = std.ArrayListUnmanaged(json.Field).empty;
    for (fm.entries) |entry| {
        switch (entry.value) {
            .scalar => |text| try fields.append(arena, .{ .key = entry.key, .value = .{ .string = text } }),
            .list => |items| {
                var values = std.ArrayListUnmanaged(json.J).empty;
                for (items) |item| try values.append(arena, .{ .string = item });
                try fields.append(arena, .{ .key = entry.key, .value = .{ .array = values.items } });
            },
        }
    }
    return .{ .object = fields.items };
}

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &.{});
    const id = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else
        return args_mod.usageError(ctx.arena, "show requires an id argument.", .{});
    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    var index = store.SpecIndex.init(ctx.arena, ctx.io, root);
    const graph = try index.graph();
    const node = graph.nodes.get(id) orelse {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "No spec with id \"{s}\".", .{id}));
        return 2;
    };

    var links = std.ArrayListUnmanaged(ResolvedLink).empty;
    inline for (std.meta.tags(graph_mod.Kind)) |kind| {
        var scratch: [1][]const u8 = undefined;
        for (graph_mod.linkTargets(node.frontmatter, kind, &scratch)) |target| {
            try links.append(ctx.arena, .{
                .kind = kind,
                .target = target,
                .path = if (graph.nodes.getPtr(target)) |other| other.path else null,
            });
        }
    }
    var reverse_links = std.ArrayListUnmanaged(ResolvedLink).empty;
    inline for (std.meta.tags(graph_mod.Kind)) |kind| {
        if (graph.reverse[@intFromEnum(kind)].get(id)) |sources| {
            for (sources.items) |source| {
                try reverse_links.append(ctx.arena, .{
                    .kind = kind,
                    .target = source,
                    .path = if (graph.nodes.getPtr(source)) |other| other.path else null,
                });
            }
        }
    }

    if (parsed.boolOf("json")) {
        var link_items = std.ArrayListUnmanaged(json.J).empty;
        for (links.items) |link| {
            try link_items.append(ctx.arena, .{ .object = try linkJson(ctx.arena, link) });
        }
        var reverse_items = std.ArrayListUnmanaged(json.J).empty;
        for (reverse_links.items) |link| {
            try reverse_items.append(ctx.arena, .{ .object = try linkJson(ctx.arena, link) });
        }
        const fields = [_]json.Field{
            .{ .key = "id", .value = .{ .string = node.id } },
            .{ .key = "type", .value = .{ .string = node.type } },
            .{ .key = "title", .value = if (node.title) |title| .{ .string = title } else .undefined_value },
            .{ .key = "path", .value = .{ .string = node.path } },
            .{ .key = "frontmatter", .value = try frontmatterJson(ctx.arena, node.frontmatter) },
            .{ .key = "links", .value = .{ .array = link_items.items } },
            .{ .key = "reverseLinks", .value = .{ .array = reverse_items.items } },
        };
        try ctx.out.print(try json.stringify(ctx.arena, .{ .object = &fields }));
        return 0;
    }

    var lines: std.Io.Writer.Allocating = .init(ctx.arena);
    const writer = &lines.writer;
    if (node.title) |title| {
        try writer.print("{s} [{s}] — {s}", .{ node.id, node.type, title });
    } else {
        try writer.print("{s} [{s}]", .{ node.id, node.type });
    }
    try writer.print("\npath: {s}", .{node.path});
    if (links.items.len > 0) {
        try writer.writeAll("\nlinks:");
        for (links.items) |link| {
            try writer.print("\n  {s} -> {s}", .{ link.kind.name(), link.target });
            if (link.path) |path| {
                try writer.print(" ({s})", .{path});
            } else {
                try writer.writeAll(" (missing)");
            }
        }
    } else {
        try writer.writeAll("\nlinks: (none)");
    }
    if (reverse_links.items.len > 0) {
        try writer.writeAll("\nreferenced by:");
        for (reverse_links.items) |link| {
            try writer.print("\n  {s} -> {s}", .{ link.kind.name(), link.target });
            if (link.path) |path| {
                try writer.print(" ({s})", .{path});
            } else {
                try writer.writeAll(" (missing)");
            }
        }
    } else {
        try writer.writeAll("\nreferenced by: (none)");
    }
    try ctx.out.print(lines.written());
    return 0;
}

fn linkJson(arena: std.mem.Allocator, link: ResolvedLink) error{OutOfMemory}![]const json.Field {
    const fields = try arena.alloc(json.Field, 3);
    fields[0] = .{ .key = "kind", .value = .{ .string = link.kind.name() } };
    fields[1] = .{ .key = "target", .value = .{ .string = link.target } };
    fields[2] = .{ .key = "path", .value = if (link.path) |path| .{ .string = path } else .null_value };
    return fields;
}
