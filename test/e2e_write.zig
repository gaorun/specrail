const std = @import("std");
const cli_exe = @import("cli_exe").cli_exe;
const fixture = @import("cli_exe").fixture;

const golden = @embedFile("golden/cli.json");

fn findCase(array: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (array.items) |item| {
        const object = item.object;
        if (std.mem.eql(u8, object.get("name").?.string, name)) return object;
    }
    return null;
}

const Runner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    array: std.json.Array,

    fn runCase(self: *Runner, name: []const u8) !void {
        const object = findCase(self.array, name) orelse {
            std.debug.print("golden case missing: {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        const argv_json = object.get("argv").?.array;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(self.allocator, cli_exe);
        if (argv_json.items.len > 0) try argv.append(self.allocator, argv_json.items[0].string);
        try argv.append(self.allocator, "--root");
        try argv.append(self.allocator, self.root);
        if (argv_json.items.len > 1) {
            for (argv_json.items[1..]) |item| try argv.append(self.allocator, item.string);
        }
        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv.items });
        try std.testing.expectEqualStrings(object.get("stdout").?.string, result.stdout);
        try std.testing.expectEqualStrings(object.get("stderr").?.string, result.stderr);
        const expected_exit = object.get("exit").?.integer;
        switch (result.term) {
            .exited => |code| try std.testing.expectEqual(expected_exit, @as(i64, code)),
            else => return error.TestUnexpectedResult,
        }
    }

    fn expectFile(self: *Runner, name: []const u8, rel: []const u8) !void {
        const object = findCase(self.array, name) orelse return error.TestUnexpectedResult;
        const path = try std.fs.path.join(self.allocator, &.{ self.root, rel });
        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1 << 20));
        try std.testing.expectEqualStrings(object.get("stdout").?.string, content);
    }
};

test "golden replay: mutating commands against a fixture copy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mktemp_result = try std.process.run(arena, io, .{ .argv = &.{ "mktemp", "-d" } });
    const temp_root = std.mem.trim(u8, mktemp_result.stdout, "\n");
    defer {
        var cleanup: std.ArrayListUnmanaged([]const u8) = .empty;
        cleanup.append(arena, "rm") catch {};
        cleanup.append(arena, "-rf") catch {};
        cleanup.append(arena, temp_root) catch {};
        _ = std.process.run(arena, io, .{ .argv = cleanup.items }) catch {};
    }
    const copy = try std.process.run(arena, io, .{ .argv = &.{ "cp", "-R", fixture, temp_root } });
    if (copy.term != .exited or copy.term.exited != 0) return error.TestUnexpectedResult;
    const project_root = try std.fs.path.join(arena, &.{ temp_root, "cli-fixture" });

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, golden, .{});
    var runner = Runner{ .allocator = arena, .io = io, .root = project_root, .array = parsed.value.array };

    try runner.runCase("create");
    try runner.expectFile("create-result-file", "specs/new-spec.md");
    try runner.runCase("create-duplicate-id");
    try runner.runCase("update");
    try runner.expectFile("update-result-file", "specs/module-x.md");
    try runner.runCase("delete");
    try runner.runCase("delete-non-interactive");
}
