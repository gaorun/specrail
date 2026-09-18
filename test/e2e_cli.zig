const std = @import("std");
const cli_exe = @import("cli_exe").cli_exe;
const fixture = @import("cli_exe").fixture;

const golden = @embedFile("golden/cli.json");

const CasePlan = struct {
    name: []const u8,
    use_fixture: bool = true,
    /// Deviation cases: the captured detail text comes from V8/Node internals
    /// that we deliberately do not reproduce; compare the stable prefix only.
    stderr_prefix: ?[]const u8 = null,
};

const plans = [_]CasePlan{
    .{ .name = "version", .use_fixture = false },
    .{ .name = "help", .use_fixture = false },
    .{ .name = "no-args-help", .use_fixture = false },
    .{ .name = "unknown-command", .use_fixture = false },
    .{ .name = "unknown-flag" },
    .{ .name = "list" },
    .{ .name = "list-json" },
    .{ .name = "list-type" },
    .{ .name = "list-tag" },
    .{ .name = "show" },
    .{ .name = "show-json" },
    .{ .name = "show-missing" },
    .{ .name = "grep" },
    .{ .name = "grep-json" },
    .{ .name = "grep-regex" },
    .{ .name = "grep-type" },
    .{ .name = "grep-limit" },
    .{ .name = "grep-bad-regex", .stderr_prefix = "Invalid search pattern: " },
    .{ .name = "grep-limit-bad" },
    .{ .name = "graph-subtree" },
    .{ .name = "graph-ancestors-json" },
    .{ .name = "graph-neighbors" },
    .{ .name = "graph-missing-id" },
    .{ .name = "validate" },
    .{ .name = "validate-json" },
    .{ .name = "sync-no-config" },
    .{ .name = "root-missing", .use_fixture = false },
    .{ .name = "root-not-dir", .use_fixture = false },
};

fn findCase(array: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (array.items) |item| {
        const object = item.object;
        if (std.mem.eql(u8, object.get("name").?.string, name)) return object;
    }
    return null;
}

fn replay(io: std.Io, allocator: std.mem.Allocator, plan: CasePlan, object: std.json.ObjectMap) !void {
    const argv_json = object.get("argv").?.array;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(allocator, cli_exe);
    if (argv_json.items.len > 0) try argv.append(allocator, argv_json.items[0].string);
    if (plan.use_fixture) {
        try argv.append(allocator, "--root");
        try argv.append(allocator, fixture);
    }
    if (argv_json.items.len > 1) {
        for (argv_json.items[1..]) |item| try argv.append(allocator, item.string);
    }

    const result = try std.process.run(allocator, io, .{ .argv = argv.items });
    try std.testing.expectEqualStrings(object.get("stdout").?.string, result.stdout);
    if (plan.stderr_prefix) |prefix| {
        try std.testing.expect(std.mem.startsWith(u8, result.stderr, prefix));
    } else {
        try std.testing.expectEqualStrings(object.get("stderr").?.string, result.stderr);
    }
    const expected_exit = object.get("exit").?.integer;
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(expected_exit, @as(i64, code)),
        else => return error.TestUnexpectedResult,
    }
}

test "golden replay: captured CLI behavior" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, golden, .{});
    const array = parsed.value.array;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (plans) |plan| {
        const object = findCase(array, plan.name) orelse {
            std.debug.print("golden case missing: {s}\n", .{plan.name});
            return error.TestUnexpectedResult;
        };
        replay(io, arena, plan, object) catch |err| {
            std.debug.print("golden case failed: {s} ({t})\n", .{ plan.name, err });
            return err;
        };
    }
}
