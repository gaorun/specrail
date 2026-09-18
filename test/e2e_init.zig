const std = @import("std");
const cli_exe = @import("cli_exe").cli_exe;

const golden = @embedFile("golden/init.json");

fn collectFiles(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    prefix: []const u8,
    out: *std.StringArrayHashMapUnmanaged([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (names.items) |name| {
        const abs = try std.fs.path.join(arena, &.{ dir_path, name });
        const rel = if (prefix.len == 0) name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
        const stat = try std.Io.Dir.cwd().statFile(io, abs, .{});
        if (stat.kind == .directory) {
            try collectFiles(arena, io, abs, rel, out);
        } else {
            const content = try std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(1 << 22));
            try out.put(arena, rel, content);
        }
    }
}

test "golden replay: init generates the captured tree, sync is idempotent" {
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

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, golden, .{});
    const golden_argv = parsed.value.object.get("argv").?.array;
    const golden_files = parsed.value.object.get("files").?.object;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, cli_exe);
    for (golden_argv.items) |item| try argv.append(arena, item.string);
    try argv.append(arena, "--root");
    try argv.append(arena, temp_root);
    const init_result = try std.process.run(arena, io, .{ .argv = argv.items });
    try std.testing.expectEqual(@as(i32, 0), init_result.term.exited);
    try std.testing.expectEqualStrings(
        "Initialized specrail 0.1.0 for qoder, claude, pi, codex (91 files).\nRule block written to AGENTS.md.\n",
        init_result.stdout,
    );
    try std.testing.expectEqualStrings("", init_result.stderr);

    var generated: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try collectFiles(arena, io, temp_root, "", &generated);
    try std.testing.expectEqual(golden_files.count(), generated.count());
    var iterator = golden_files.iterator();
    while (iterator.next()) |kv| {
        const expected = kv.value_ptr.string;
        const actual = generated.get(kv.key_ptr.*) orelse {
            std.debug.print("missing generated file: {s}\n", .{kv.key_ptr.*});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("file content mismatch: {s}\n", .{kv.key_ptr.*});
            return error.TestUnexpectedResult;
        }
    }

    var sync_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try sync_argv.append(arena, cli_exe);
    try sync_argv.append(arena, "sync");
    try sync_argv.append(arena, "--rule");
    try sync_argv.append(arena, "--root");
    try sync_argv.append(arena, temp_root);
    const sync_result = try std.process.run(arena, io, .{ .argv = sync_argv.items });
    try std.testing.expectEqual(@as(i32, 0), sync_result.term.exited);
    try std.testing.expectEqualStrings(
        "Synced specrail 0.1.0 for qoder, claude, pi, codex (91 files).\nRule block written to AGENTS.md.\n",
        sync_result.stdout,
    );

    var regenerated: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try collectFiles(arena, io, temp_root, "", &regenerated);
    try std.testing.expectEqual(generated.count(), regenerated.count());
    var regenerated_iterator = regenerated.iterator();
    while (regenerated_iterator.next()) |kv| {
        const before = generated.get(kv.key_ptr.*) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(before, kv.value_ptr.*);
    }
}
