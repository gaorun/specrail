const std = @import("std");
const context = @import("context.zig");
const errors = @import("../errors.zig");
const out_mod = @import("out.zig");
const version = @import("version.zig");

const commands = struct {
    const create = @import("commands/create.zig");
    const delete = @import("commands/delete.zig");
    const graph = @import("commands/graph.zig");
    const grep = @import("commands/grep.zig");
    const init = @import("commands/init.zig");
    const list = @import("commands/list.zig");
    const show = @import("commands/show.zig");
    const sync = @import("commands/sync.zig");
    const update = @import("commands/update.zig");
    const validate = @import("commands/validate.zig");
};

const Command = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (*context.Context) anyerror!u8,
};

fn notImplemented(ctx: *context.Context) anyerror!u8 {
    _ = ctx;
    return error.NotImplemented;
}

const COMMANDS = [_]Command{
    .{ .name = "init", .summary = "install skills and commands into assistant config (--tools, --rule)", .run = commands.init.run },
    .{ .name = "sync", .summary = "refresh generated files and remove deselected tool outputs", .run = commands.sync.run },
    .{ .name = "list", .summary = "list spec nodes (--type, --tag, --json)", .run = commands.list.run },
    .{ .name = "show", .summary = "show one spec by id (--json)", .run = commands.show.run },
    .{ .name = "grep", .summary = "search specs (--regex, --ignore-case, --type, --tag, --parent, --depends-on, --limit)", .run = commands.grep.run },
    .{ .name = "graph", .summary = "walk a graph slice (--direction, --depth, --edge)", .run = commands.graph.run },
    .{ .name = "create", .summary = "create a spec file", .run = commands.create.run },
    .{ .name = "update", .summary = "edit a spec's frontmatter", .run = commands.update.run },
    .{ .name = "delete", .summary = "delete a spec file (--yes)", .run = commands.delete.run },
    .{ .name = "validate", .summary = "validate the spec graph (--json)", .run = commands.validate.run },
};

pub fn run(init: std.process.Init) u8 {
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [8192]u8 = undefined;
    var out = out_mod.Out.init(init.io, &stdout_buffer, &stderr_buffer);
    const code = dispatch(init, &out) catch |err| {
        if (err == error.BrokenPipe) return 0;
        return 1;
    };
    out.flush() catch |err| {
        if (err == error.BrokenPipe) return 0;
        return 1;
    };
    return code;
}

fn dispatch(init: std.process.Init, out: *out_mod.Out) !u8 {
    const arena = init.arena.allocator();
    // Process-lifetime data lives in the arena: the CLI is short-lived and the
    // arena is released automatically on exit.
    var arg_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer arg_iterator.deinit();
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    while (arg_iterator.next()) |arg| try argv_list.append(arena, arg);
    const argv = argv_list.items;
    const rest: []const []const u8 = if (argv.len > 0) argv[1..] else argv;
    const command: ?[]const u8 = if (rest.len > 0) rest[0] else null;

    if (command == null or std.mem.eql(u8, command.?, "--help") or std.mem.eql(u8, command.?, "-h")) {
        try printHelp(out);
        return 0;
    }
    if (std.mem.eql(u8, command.?, "--version") or std.mem.eql(u8, command.?, "-v")) {
        try out.print(version.packageVersion());
        return 0;
    }
    const entry = findCommand(command.?) orelse {
        const message = try std.fmt.allocPrint(init.arena.allocator(), "Unknown command: {s}", .{command.?});
        try out.err(message);
        return 2;
    };
    var ctx = context.Context{
        .io = init.io,
        .arena = arena,
        .out = out,
        .argv = rest[1..],
    };
    return entry.run(&ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(out);
            return 0;
        },
        error.VersionRequested => {
            try out.print(version.packageVersion());
            return 0;
        },
        error.Usage, error.Distribute => {
            try out.err(errors.message);
            return 2;
        },
        else => return err,
    };
}

fn findCommand(name: []const u8) ?Command {
    for (COMMANDS) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

fn printHelp(out: *out_mod.Out) !void {
    var title_buffer: [256]u8 = undefined;
    const title = try std.fmt.bufPrint(
        &title_buffer,
        "specrail {s} — spec-graph CLI with cross-assistant workflow skills",
        .{version.packageVersion()},
    );
    try out.print(title);
    for (COMMANDS) |command| {
        var line_buffer: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "  {s: <9} {s}",
            .{ command.name, command.summary },
        );
        try out.print(line);
    }
}
