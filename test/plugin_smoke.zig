const std = @import("std");
const plugin_dir = @import("plugin_opts").plugin_dir;
const skills_dir = @import("plugin_opts").skills_dir;

fn readAll(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 26));
}

fn expectMagic(arena: std.mem.Allocator, io: std.Io, name: []const u8, expected: []const u8) !void {
    const path = try std.fs.path.join(arena, &.{ plugin_dir, "libexec", name });
    const bytes = readAll(arena, io, path) catch |err| {
        std.debug.print("missing binary {s}: {t}\n", .{ name, err });
        return err;
    };
    try std.testing.expect(bytes.len > 4);
    try std.testing.expectEqualSlices(u8, expected, bytes[0..expected.len]);
}

fn compareTrees(
    arena: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    destination: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const source_child = try std.fs.path.join(arena, &.{ source, entry.name });
        const destination_child = try std.fs.path.join(arena, &.{ destination, entry.name });
        if (entry.kind == .directory) {
            try compareTrees(arena, io, source_child, destination_child);
        } else {
            const expected = readAll(arena, io, source_child) catch |err| {
                std.debug.print("source unreadable {s}: {t}\n", .{ source_child, err });
                return err;
            };
            const actual = readAll(arena, io, destination_child) catch |err| {
                std.debug.print("plugin copy missing {s}: {t}\n", .{ destination_child, err });
                return err;
            };
            if (!std.mem.eql(u8, expected, actual)) {
                std.debug.print("plugin copy differs: {s}\n", .{destination_child});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "assembled plugin tree passes the smoke checks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // runtime.json describes the zig runtime and all six targets.
    const runtime_text = try readAll(arena, io, try std.fs.path.join(arena, &.{ plugin_dir, "runtime.json" }));
    const runtime = (try std.json.parseFromSlice(std.json.Value, arena, runtime_text, .{})).value;
    try std.testing.expectEqualStrings("zig", runtime.object.get("runtime").?.string);
    try std.testing.expect(runtime.object.get("version").?.string.len > 0);
    const targets = runtime.object.get("targets").?.array;
    try std.testing.expectEqual(@as(usize, 6), targets.items.len);

    try expectMagic(arena, io, "specrail-darwin-arm64", &.{ 0xCF, 0xFA, 0xED, 0xFE });
    try expectMagic(arena, io, "specrail-darwin-x64", &.{ 0xCF, 0xFA, 0xED, 0xFE });
    try expectMagic(arena, io, "specrail-linux-arm64", &.{ 0x7F, 'E', 'L', 'F' });
    try expectMagic(arena, io, "specrail-linux-x64", &.{ 0x7F, 'E', 'L', 'F' });
    try expectMagic(arena, io, "specrail-windows-arm64.exe", &.{ 'M', 'Z' });
    try expectMagic(arena, io, "specrail-windows-x64.exe", &.{ 'M', 'Z' });

    // Skills are shipped byte-for-byte.
    try compareTrees(
        arena,
        io,
        try std.fs.path.join(arena, &.{ skills_dir, "specrail-shipping-a-pr" }),
        try std.fs.path.join(arena, &.{ plugin_dir, "skills", "specrail-shipping-a-pr" }),
    );

    // No development-only files leak into the plugin.
    for ([_][]const u8{ "src", "node_modules", "package.json", "bun.lock", "build.zig" }) |forbidden| {
        const path = try std.fs.path.join(arena, &.{ plugin_dir, forbidden });
        try std.testing.expect((std.Io.Dir.cwd().statFile(io, path, .{}) catch null) == null);
    }

    // Top-level shape is exactly the distributable set.
    var top_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var top_dir = try std.Io.Dir.cwd().openDir(io, plugin_dir, .{ .iterate = true });
    defer top_dir.close(io);
    var top_iterator = top_dir.iterate();
    while (try top_iterator.next(io)) |entry| try top_names.append(arena, try arena.dupe(u8, entry.name));
    std.mem.sort([]const u8, top_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    const expected_top = [_][]const u8{
        ".claude-plugin", ".qoder-plugin", "LICENSE", "NOTICE", "README.md",
        "bin",            "libexec",        "licenses", "runtime.json", "skills",
    };
    try std.testing.expectEqual(expected_top.len, top_names.items.len);
    for (expected_top, top_names.items) |wanted, actual| {
        try std.testing.expectEqualStrings(wanted, actual);
    }

    // Manifests carry the app version and a self-referential marketplace.
    const plugin_manifest_text = try readAll(arena, io, try std.fs.path.join(arena, &.{ plugin_dir, ".qoder-plugin", "plugin.json" }));
    const plugin_manifest = (try std.json.parseFromSlice(std.json.Value, arena, plugin_manifest_text, .{})).value;
    try std.testing.expectEqualStrings("0.1.0", plugin_manifest.object.get("version").?.string);
    const marketplace_text = try readAll(arena, io, try std.fs.path.join(arena, &.{ plugin_dir, ".claude-plugin", "marketplace.json" }));
    const marketplace = (try std.json.parseFromSlice(std.json.Value, arena, marketplace_text, .{})).value;
    try std.testing.expectEqualStrings("./", marketplace.object.get("plugins").?.array.items[0].object.get("source").?.string);

    // The shell launcher runs the host binary with no node/bun on PATH.
    var environ = std.process.Environ.Map.init(arena);
    try environ.put("PATH", "/usr/bin:/bin");
    const launcher = try std.fs.path.join(arena, &.{ plugin_dir, "bin", "specrail" });
    const result = try std.process.run(arena, io, .{ .argv = &.{ launcher, "--version" }, .environ_map = &environ });
    try std.testing.expectEqual(@as(i32, 0), result.term.exited);
    try std.testing.expectEqualStrings("0.1.0\n", result.stdout);
}
