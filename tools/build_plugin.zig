// Build-time assembler: stages the distributable plugin directory (launchers,
// per-platform binaries, skills, manifests, licenses) next to its destination
// and publishes it atomically.
const std = @import("std");
const builtin = @import("builtin");
const specrail = @import("specrail");

const Artifact = struct {
    target: []const u8,
    path: []const u8,
};

const Options = struct {
    root: []const u8 = "",
    destination: []const u8 = "",
    version: []const u8 = "",
    artifacts: []const Artifact = &.{},
};

fn fail(comptime format: []const u8, args: anytype) u8 {
    std.debug.print("build-plugin: " ++ format ++ "\n", args);
    return 1;
}

fn zigVersionString(arena: std.mem.Allocator) ![]const u8 {
    const version = builtin.zig_version;
    return std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
}

fn copyTree(arena: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, source, .{});
    if (stat.kind == .directory) {
        try std.Io.Dir.cwd().createDirPath(io, destination);
        var dir = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
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
            try copyTree(
                arena,
                io,
                try std.fs.path.join(arena, &.{ source, name }),
                try std.fs.path.join(arena, &.{ destination, name }),
            );
        }
        return;
    }
    try copyFileMode(arena, io, source, destination, 0o644);
}

fn copyFileMode(arena: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8, mode: u16) !void {
    if (std.fs.path.dirname(destination)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const absolute_source = if (std.fs.path.isAbsolute(source)) source else blk: {
        const cwd_path = try std.process.currentPathAlloc(io, arena);
        break :blk try std.fs.path.join(arena, &.{ cwd_path, source });
    };
    var source_file = try std.Io.Dir.openFileAbsolute(io, absolute_source, .{});
    defer source_file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = source_file.readerStreaming(io, &read_buffer);
    const bytes = try reader.interface.allocRemaining(arena, .limited(1 << 28));
    var file = try std.Io.Dir.cwd().createFile(io, destination, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.setPermissions(io, std.Io.File.Permissions.fromMode(mode));
}

fn valueToJ(arena: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}!specrail.json.J {
    return switch (value) {
        .null => .null_value,
        .bool => |flag| .{ .boolean = flag },
        .integer => |number| .{ .number = @floatFromInt(number) },
        .float => |number| .{ .number = number },
        .string => |text| .{ .string = text },
        .array => |items| blk: {
            var values = std.ArrayListUnmanaged(specrail.json.J).empty;
            for (items.items) |item| try values.append(arena, try valueToJ(arena, item));
            break :blk .{ .array = values.items };
        },
        .object => |object| blk: {
            var fields = std.ArrayListUnmanaged(specrail.json.Field).empty;
            var iterator = object.iterator();
            while (iterator.next()) |kv| {
                try fields.append(arena, .{ .key = kv.key_ptr.*, .value = try valueToJ(arena, kv.value_ptr.*) });
            }
            break :blk .{ .object = fields.items };
        },
        .number_string => |text| .{ .string = text },
    };
}

fn writeFileText(io: std.Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

fn writeManifest(
    arena: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    destination_path: []const u8,
    version: []const u8,
    marketplace: bool,
) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, source_path, arena, .limited(1 << 20));
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, content, .{});
    const value = try valueToJ(arena, parsed.value);
    if (value != .object) return error.InvalidManifest;
    var fields = value.object;

    if (marketplace) {
        var rebuilt = std.ArrayListUnmanaged(specrail.json.Field).empty;
        for (fields) |field| {
            if (!std.mem.eql(u8, field.key, "plugins") or field.value != .array) {
                try rebuilt.append(arena, field);
                continue;
            }
            var plugins = std.ArrayListUnmanaged(specrail.json.J).empty;
            for (field.value.array) |plugin| {
                if (plugin != .object) {
                    try plugins.append(arena, plugin);
                    continue;
                }
                var plugin_fields = std.ArrayListUnmanaged(specrail.json.Field).empty;
                for (plugin.object) |plugin_field| {
                    if (std.mem.eql(u8, plugin_field.key, "source")) {
                        try plugin_fields.append(arena, .{ .key = "source", .value = .{ .string = "./" } });
                    } else {
                        try plugin_fields.append(arena, plugin_field);
                    }
                }
                try plugins.append(arena, .{ .object = plugin_fields.items });
            }
            try rebuilt.append(arena, .{ .key = field.key, .value = .{ .array = plugins.items } });
        }
        fields = rebuilt.items;
    } else {
        var rebuilt = std.ArrayListUnmanaged(specrail.json.Field).empty;
        var replaced = false;
        for (fields) |field| {
            if (std.mem.eql(u8, field.key, "version")) {
                try rebuilt.append(arena, .{ .key = "version", .value = .{ .string = version } });
                replaced = true;
            } else {
                try rebuilt.append(arena, field);
            }
        }
        if (!replaced) {
            try rebuilt.append(arena, .{ .key = "version", .value = .{ .string = version } });
        }
        fields = rebuilt.items;
    }

    const text = try std.fmt.allocPrint(arena, "{s}\n", .{
        try specrail.json.stringify(arena, .{ .object = fields }),
    });
    try writeFileText(io, destination_path, text);
}

fn listSkillDirs(arena: std.mem.Allocator, io: std.Io, skills_dir: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, skills_dir, .{ .iterate = true });
    defer dir.close(io);
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const name = try arena.dupe(u8, entry.name);
        const skill_md = try std.fs.path.join(arena, &.{ skills_dir, name, "SKILL.md" });
        if ((std.Io.Dir.cwd().statFile(io, skill_md, .{}) catch null) == null) continue;
        try names.append(arena, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return names.items;
}

fn assemble(arena: std.mem.Allocator, io: std.Io, options: *const Options, output: []const u8) !void {
    const root = options.root;

    // libexec: one binary per platform.
    for (options.artifacts) |artifact| {
        const name = if (std.mem.startsWith(u8, artifact.target, "windows-"))
            try std.fmt.allocPrint(arena, "specrail-{s}.exe", .{artifact.target})
        else
            try std.fmt.allocPrint(arena, "specrail-{s}", .{artifact.target});
        const destination = try std.fs.path.join(arena, &.{ output, "libexec", name });
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(destination).?);
        try copyFileMode(arena, io, artifact.path, destination, 0o755);
    }

    // Launchers and shared documents.
    try copyTree(arena, io, try std.fs.path.join(arena, &.{ root, "bin" }), try std.fs.path.join(arena, &.{ output, "bin" }));
    for ([_][]const u8{ "README.md", "LICENSE", "NOTICE" }) |file| {
        try copyTree(
            arena,
            io,
            try std.fs.path.join(arena, &.{ root, file }),
            try std.fs.path.join(arena, &.{ output, file }),
        );
    }
    try copyTree(arena, io, try std.fs.path.join(arena, &.{ root, "licenses" }), try std.fs.path.join(arena, &.{ output, "licenses" }));

    // Skills shipped alongside the binaries.
    const skills_dir = try std.fs.path.join(arena, &.{ root, "skills" });
    for (try listSkillDirs(arena, io, skills_dir)) |name| {
        try copyTree(
            arena,
            io,
            try std.fs.path.join(arena, &.{ skills_dir, name }),
            try std.fs.path.join(arena, &.{ output, "skills", name }),
        );
    }

    // Manifests the assistants read.
    inline for ([_][]const u8{ "claude", "qoder" }) |assistant| {
        const manifest_dir = try std.fmt.allocPrint(arena, ".{s}-plugin", .{assistant});
        try writeManifest(
            arena,
            io,
            try std.fs.path.join(arena, &.{ root, manifest_dir, "plugin.json" }),
            try std.fs.path.join(arena, &.{ output, manifest_dir, "plugin.json" }),
            options.version,
            false,
        );
        try writeManifest(
            arena,
            io,
            try std.fs.path.join(arena, &.{ root, manifest_dir, "marketplace.json" }),
            try std.fs.path.join(arena, &.{ output, manifest_dir, "marketplace.json" }),
            options.version,
            true,
        );
    }

    // Executable bit on the launcher.
    const launcher = try std.fs.path.join(arena, &.{ output, "bin", "specrail" });
    var launcher_file = try std.Io.Dir.cwd().openFile(io, launcher, .{});
    defer launcher_file.close(io);
    try launcher_file.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));

    // Runtime descriptor.
    var target_values = std.ArrayListUnmanaged(specrail.json.J).empty;
    for (options.artifacts) |artifact| {
        try target_values.append(arena, .{ .string = artifact.target });
    }
    const runtime_fields = try arena.dupe(specrail.json.Field, &[_]specrail.json.Field{
        .{ .key = "runtime", .value = .{ .string = "zig" } },
        .{ .key = "version", .value = .{ .string = try zigVersionString(arena) } },
        .{ .key = "targets", .value = .{ .array = target_values.items } },
    });
    const runtime_text = try std.fmt.allocPrint(arena, "{s}\n", .{
        try specrail.json.stringify(arena, .{ .object = runtime_fields }),
    });
    try writeFileText(io, try std.fs.path.join(arena, &.{ output, "runtime.json" }), runtime_text);
}

fn isEmptyDir(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var iterator = dir.iterate();
    const first = iterator.next(io) catch return false;
    return first == null;
}

fn run(arena: std.mem.Allocator, io: std.Io, options: *const Options) !void {
    const destination = options.destination;
    const parent = std.fs.path.dirname(destination) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, parent);

    if ((std.Io.Dir.cwd().statFile(io, destination, .{}) catch null) != null) {
        const runtime_path = try std.fs.path.join(arena, &.{ destination, "runtime.json" });
        if ((std.Io.Dir.cwd().statFile(io, runtime_path, .{}) catch null) == null and !isEmptyDir(io, destination)) {
            return error.RefuseReplace;
        }
    }

    var staging_path: []const u8 = undefined;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (attempt > 64) return error.StagingFailed;
        var seed: [8]u8 = undefined;
        io.random(&seed);
        staging_path = try std.fmt.allocPrint(arena, "{s}/.specrail-build-{x}", .{ parent, std.mem.readInt(u64, &seed, .little) });
        std.Io.Dir.cwd().createDir(io, staging_path, std.Io.File.Permissions.fromMode(0o755)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break;
    }
    errdefer std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};

    const output = try std.fs.path.join(arena, &.{ staging_path, "specrail" });
    try std.Io.Dir.cwd().createDir(io, output, std.Io.File.Permissions.fromMode(0o755));
    try assemble(arena, io, options, output);

    if ((std.Io.Dir.cwd().statFile(io, destination, .{}) catch null) != null) {
        try std.Io.Dir.cwd().deleteTree(io, destination);
    }
    try std.Io.Dir.renameAbsolute(output, destination, io);
    std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
}

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var artifacts = std.ArrayListUnmanaged(Artifact).empty;
    var options = Options{ .root = "", .destination = "", .version = "" };
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return fail("unable to read arguments", .{});
    defer args.deinit();
    _ = args.next();
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--root")) {
            options.root = args.next() orelse return fail("--root needs a value", .{});
        } else if (std.mem.eql(u8, flag, "--destination")) {
            options.destination = args.next() orelse return fail("--destination needs a value", .{});
        } else if (std.mem.eql(u8, flag, "--version")) {
            options.version = args.next() orelse return fail("--version needs a value", .{});
        } else if (std.mem.eql(u8, flag, "--artifact")) {
            const target = args.next() orelse return fail("--artifact needs a target", .{});
            const path = args.next() orelse return fail("--artifact needs a path", .{});
            artifacts.append(arena, .{ .target = target, .path = path }) catch return fail("out of memory", .{});
        } else {
            return fail("unknown argument {s}", .{flag});
        }
    }
    options.artifacts = artifacts.items;
    if (options.root.len == 0 or options.destination.len == 0 or options.version.len == 0 or options.artifacts.len == 0) {
        return fail("usage: build-plugin --root <dir> --destination <dir> --version <v> --artifact <target> <path>...", .{});
    }

    run(arena, io, &options) catch |err| switch (err) {
        error.RefuseReplace => return fail("Refusing to replace a non-build directory: {s}", .{options.destination}),
        else => return fail("{s} failed: {s}", .{ options.destination, @errorName(err) }),
    };
    std.debug.print("Plugin built at {s}\n", .{options.destination});
    return 0;
}
