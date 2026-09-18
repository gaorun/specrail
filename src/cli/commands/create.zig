const std = @import("std");
const graph_mod = @import("../../core/graph.zig");
const parse = @import("../../core/parse.zig");
const store = @import("../../core/store.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const json = @import("../../json.zig");

const command_specs = [_]args_mod.Spec{
    .{ .name = "id" },
    .{ .name = "type" },
    .{ .name = "title" },
    .{ .name = "status" },
    .{ .name = "parent" },
    .{ .name = "depends-on", .multiple = true },
    .{ .name = "references", .multiple = true },
    .{ .name = "implements", .multiple = true },
    .{ .name = "covers", .multiple = true },
    .{ .name = "tags", .multiple = true },
};

fn scaffoldBody(arena: std.mem.Allocator, spec_type: []const u8) anyerror![]const u8 {
    const headings: []const []const u8 = if (std.mem.eql(u8, spec_type, "module-design") or std.mem.eql(u8, spec_type, "submodule-design"))
        &.{ "Responsibility", "Boundary" }
    else if (std.mem.eql(u8, spec_type, "architecture-design"))
        &.{ "Drivers", "Decisions", "Invariants", "Out of scope" }
    else if (std.mem.eql(u8, spec_type, "goal-and-requirements"))
        &.{ "Goal", "Scope" }
    else
        &.{ "Purpose", "Open items" };
    var out: std.Io.Writer.Allocating = .init(arena);
    for (headings, 0..) |heading, index| {
        if (index > 0) try out.writer.writeByte('\n');
        try out.writer.print("## {s}\n", .{heading});
    }
    return out.written();
}

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &command_specs);
    const path = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else
        return args_mod.usageError(ctx.arena, "create requires a path argument.", .{});
    const id = parsed.stringOf("id") orelse return args_mod.usageError(ctx.arena, "--id is required.", .{});
    var spec_type: ?[]const u8 = null;
    if (parsed.stringOf("type")) |wanted| {
        for (parse.SPEC_TYPES) |candidate| {
            if (std.mem.eql(u8, candidate, wanted)) spec_type = candidate;
        }
    }
    const resolved_type = spec_type orelse
        return args_mod.usageError(ctx.arena, "--type must be one of: goal-and-requirements, architecture-design, module-design, submodule-design, task-spec", .{});
    const title = parsed.stringOf("title") orelse return args_mod.usageError(ctx.arena, "--title is required.", .{});
    var status: ?[]const u8 = null;
    if (parsed.stringOf("status")) |wanted| {
        for (parse.SPEC_STATUSES) |candidate| {
            if (std.mem.eql(u8, candidate, wanted)) status = candidate;
        }
        if (status == null) {
            return args_mod.usageError(ctx.arena, "--status must be one of: draft, active, stale, done, deprecated", .{});
        }
    }

    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    const resolution = try store.resolveSpecPath(ctx.arena, ctx.io, root, path);
    const resolved = switch (resolution) {
        .err => |message| {
            try ctx.out.err(message);
            return 2;
        },
        .resolved => |value| value,
    };
    if (std.Io.Dir.cwd().statFile(ctx.io, resolved.abs, .{}) catch null) |_| {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "File already exists: {s}", .{resolved.rel}));
        return 2;
    }
    var index = store.SpecIndex.init(ctx.arena, ctx.io, root);
    if ((try index.graph()).nodes.contains(id)) {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "Spec id \"{s}\" is already in use.", .{id}));
        return 2;
    }

    var entries = std.ArrayListUnmanaged(parse.Entry).empty;
    try entries.append(ctx.arena, .{ .key = parse.ID, .value = .{ .scalar = id } });
    try entries.append(ctx.arena, .{ .key = parse.TYPE, .value = .{ .scalar = resolved_type } });
    if (status) |status_value| {
        try entries.append(ctx.arena, .{ .key = parse.STATUS, .value = .{ .scalar = status_value } });
    }
    try entries.append(ctx.arena, .{ .key = parse.TITLE, .value = .{ .scalar = title } });
    if (parsed.stringOf("parent")) |parent| {
        try entries.append(ctx.arena, .{ .key = parse.PARENT, .value = .{ .scalar = parent } });
    }
    inline for ([_][]const u8{ "depends-on", "references", "implements", "covers", "tags" }) |field| {
        const items = parsed.listOf(field);
        if (items.len > 0) {
            try entries.append(ctx.arena, .{ .key = field, .value = .{ .list = items } });
        }
    }
    const frontmatter = parse.Frontmatter{ .entries = entries.items };

    const content = try std.fmt.allocPrint(ctx.arena, "{s}\n{s}", .{
        try parse.serializeFrontmatter(ctx.arena, frontmatter),
        try scaffoldBody(ctx.arena, resolved_type),
    });
    const written = try parse.parseFile(ctx.arena, content);
    if (!parse.isSpec(written.frontmatter)) {
        try ctx.out.err(try std.fmt.allocPrint(
            ctx.arena,
            "Refusing to write {s}: the frontmatter would not be a spec (id and type must be non-empty).",
            .{resolved.rel},
        ));
        return 2;
    }

    if (std.fs.path.dirname(resolved.abs)) |parent_dir| {
        std.Io.Dir.cwd().createDirPath(ctx.io, parent_dir) catch {};
    }
    var file = std.Io.Dir.cwd().createFile(ctx.io, resolved.abs, .{ .exclusive = true }) catch |err| {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "Failed to write {s}: {s}", .{ resolved.rel, @errorName(err) }));
        return 2;
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, content) catch |err| {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "Failed to write {s}: {s}", .{ resolved.rel, @errorName(err) }));
        return 2;
    };

    if (parsed.boolOf("json")) {
        const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
            .{ .key = "path", .value = .{ .string = resolved.rel } },
            .{ .key = "id", .value = .{ .string = id } },
        });
        try ctx.out.print(try json.stringify(ctx.arena, .{ .object = fields }));
    } else {
        try ctx.out.print(try std.fmt.allocPrint(ctx.arena, "Created {s} (id: {s}).", .{ resolved.rel, id }));
    }
    return 0;
}
