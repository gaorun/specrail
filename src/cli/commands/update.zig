const std = @import("std");
const parse = @import("../../core/parse.zig");
const store = @import("../../core/store.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const json = @import("../../json.zig");

const command_specs = [_]args_mod.Spec{
    .{ .name = "set", .multiple = true },
    .{ .name = "remove", .multiple = true },
    .{ .name = "add-list", .multiple = true },
    .{ .name = "remove-list", .multiple = true },
};

fn splitAssignment(ctx: *context.Context, raw: []const u8, flag: []const u8) args_mod.Error!struct { key: []const u8, value: []const u8 } {
    const at = std.mem.indexOfScalar(u8, raw, '=');
    if (at == null or at.? == 0) {
        return args_mod.usageError(ctx.arena, "--{s} expects K=V, got \"{s}\"", .{ flag, raw });
    }
    return .{ .key = raw[0..at.?], .value = raw[at.? + 1 ..] };
}

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &command_specs);
    const id = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else
        return args_mod.usageError(ctx.arena, "update requires an id argument.", .{});
    if (parsed.positionals.items.len > 1) {
        return args_mod.usageError(
            ctx.arena,
            "update takes only an id argument; edit frontmatter with --set K=V, --remove K, --add-list K=V, or --remove-list K=V.",
            .{},
        );
    }

    // set: same-key later value wins, first-seen key keeps its position.
    var set_entries = std.ArrayListUnmanaged(parse.Entry).empty;
    for (parsed.listOf("set")) |raw| {
        const assignment = try splitAssignment(ctx, raw, "set");
        var replaced = false;
        for (set_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, assignment.key)) {
                entry.value = .{ .scalar = assignment.value };
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try set_entries.append(ctx.arena, .{ .key = assignment.key, .value = .{ .scalar = assignment.value } });
        }
    }

    var remove_entries = std.ArrayListUnmanaged([]const u8).empty;
    for (parsed.listOf("remove")) |raw| try remove_entries.append(ctx.arena, raw);

    var add_list_entries = std.ArrayListUnmanaged(parse.Entry).empty;
    for (parsed.listOf("add-list")) |raw| {
        const assignment = try splitAssignment(ctx, raw, "add-list");
        const field = findListField(assignment.key) orelse
            return args_mod.usageError(ctx.arena, "--add-list supports only: depends-on, references, implements, covers, tags", .{});
        try appendListValue(ctx.arena, &add_list_entries, field, assignment.value);
    }

    var remove_list_entries = std.ArrayListUnmanaged(parse.Entry).empty;
    for (parsed.listOf("remove-list")) |raw| {
        const assignment = try splitAssignment(ctx, raw, "remove-list");
        const field = findListField(assignment.key) orelse
            return args_mod.usageError(ctx.arena, "--remove-list supports only: depends-on, references, implements, covers, tags", .{});
        try appendListValue(ctx.arena, &remove_list_entries, field, assignment.value);
    }

    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    var index = store.SpecIndex.init(ctx.arena, ctx.io, root);
    const record = (try index.recordForId(id)) orelse {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "No spec with id \"{s}\".", .{id}));
        return 2;
    };

    const result = try parse.updateFrontmatterText(ctx.arena, record.content, .{
        .set = set_entries.items,
        .remove = remove_entries.items,
        .add_list = add_list_entries.items,
        .remove_list = remove_list_entries.items,
    });
    const content = switch (result) {
        .err => |message| {
            try ctx.out.err(message);
            return 2;
        },
        .content => |value| value,
    };

    var file = std.Io.Dir.cwd().createFile(ctx.io, record.abs, .{ .truncate = true }) catch |err| {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "Failed to write {s}: {s}", .{ record.rel, @errorName(err) }));
        return 2;
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, content) catch |err| {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "Failed to write {s}: {s}", .{ record.rel, @errorName(err) }));
        return 2;
    };

    if (parsed.boolOf("json")) {
        const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
            .{ .key = "id", .value = .{ .string = id } },
            .{ .key = "path", .value = .{ .string = record.rel } },
        });
        try ctx.out.print(try json.stringify(ctx.arena, .{ .object = fields }));
    } else {
        try ctx.out.print(try std.fmt.allocPrint(ctx.arena, "Updated frontmatter of {s} (id: {s}).", .{ record.rel, id }));
    }
    return 0;
}

fn findListField(key: []const u8) ?[]const u8 {
    for (parse.LIST_FIELDS) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return candidate;
    }
    return null;
}

fn appendListValue(
    arena: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(parse.Entry),
    field: []const u8,
    value: []const u8,
) error{OutOfMemory}!void {
    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.key, field)) {
            const existing = entry.value.list;
            var items = std.ArrayListUnmanaged([]const u8).empty;
            try items.appendSlice(arena, existing);
            try items.append(arena, value);
            entry.value = .{ .list = items.items };
            return;
        }
    }
    var items = std.ArrayListUnmanaged([]const u8).empty;
    try items.append(arena, value);
    try entries.append(arena, .{ .key = field, .value = .{ .list = items.items } });
}
