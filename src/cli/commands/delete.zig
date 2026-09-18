const std = @import("std");
const store = @import("../../core/store.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const json = @import("../../json.zig");

const command_specs = [_]args_mod.Spec{
    .{ .name = "yes", .kind = .boolean },
};

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &command_specs);
    const id = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else
        return args_mod.usageError(ctx.arena, "delete requires an id argument.", .{});
    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    var index = store.SpecIndex.init(ctx.arena, ctx.io, root);
    const path = (try index.pathForId(id)) orelse {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "No spec with id \"{s}\".", .{id}));
        return 2;
    };

    if (!parsed.boolOf("yes")) {
        const stdin = std.Io.File.stdin();
        const is_tty = stdin.isTty(ctx.io) catch false;
        if (!is_tty) {
            try ctx.out.err("Refusing to delete without --yes (non-interactive).");
            return 2;
        }
        try ctx.out.printRaw(try std.fmt.allocPrint(ctx.arena, "Delete {s} (id: {s})? [y/N] ", .{ path, id }));
        try ctx.out.flush();
        var stdin_buffer: [256]u8 = undefined;
        var reader = stdin.readerStreaming(ctx.io, &stdin_buffer);
        const answer = reader.interface.takeDelimiter('\n') catch null;
        const accepted = if (answer) |line| blk: {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len != 1) break :blk false;
            break :blk std.ascii.toLower(trimmed[0]) == 'y';
        } else false;
        if (!accepted) return 0;
    }

    const abs = try index.absPath(path);
    std.Io.Dir.cwd().deleteFile(ctx.io, abs) catch |err| {
        try ctx.out.err(try std.fmt.allocPrint(ctx.arena, "Failed to delete {s}: {s}", .{ path, @errorName(err) }));
        return 2;
    };

    if (parsed.boolOf("json")) {
        const fields = try ctx.arena.dupe(json.Field, &[_]json.Field{
            .{ .key = "id", .value = .{ .string = id } },
            .{ .key = "path", .value = .{ .string = path } },
        });
        try ctx.out.print(try json.stringify(ctx.arena, .{ .object = fields }));
    } else {
        try ctx.out.print(try std.fmt.allocPrint(ctx.arena, "Deleted {s} (id: {s}).", .{ path, id }));
    }
    return 0;
}
