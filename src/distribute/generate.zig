const std = @import("std");
const adapters = @import("adapters.zig");
const config_m = @import("config.zig");
const rule = @import("rule.zig");
const parse = @import("../core/parse.zig");
const errors = @import("../errors.zig");

pub const AGENTS_FILE = "AGENTS.md";
pub const CONTEXT_IGNORE_PATH = ".specrail/.gitignore";
pub const CONTEXT_IGNORE_CONTENT = "context/\n";

pub const ApplyReport = struct {
    tools: []const adapters.Tool,
    files: []const []const u8,
    removed: []const []const u8,
    rule_written: bool,
};

fn distributeError(arena: std.mem.Allocator, comptime format: []const u8, fmt_args: anytype) errors.Error {
    errors.message = std.fmt.allocPrint(arena, format, fmt_args) catch return error.OutOfMemory;
    return error.Distribute;
}

// ---------------------------------------------------------------------------
// Reading a skills directory (used by tests and by the embed-skills tool)

const SkillCandidate = struct {
    name: []const u8,
    has_skill_md: bool,
};

pub fn readSkillsFromDir(
    arena: std.mem.Allocator,
    io: std.Io,
    skills_dir: []const u8,
) errors.Error![]adapters.Skill {
    var dir = std.Io.Dir.cwd().openDir(io, skills_dir, .{ .iterate = true }) catch {
        return distributeError(arena, "Skills source directory not found: {s}", .{skills_dir});
    };
    defer dir.close(io);
    var candidates = std.ArrayListUnmanaged(SkillCandidate).empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const name = try arena.dupe(u8, entry.name);
        const skill_md = try std.fs.path.join(arena, &.{ skills_dir, name, "SKILL.md" });
        const has_skill_md = (std.Io.Dir.cwd().statFile(io, skill_md, .{}) catch null) != null;
        if (has_skill_md) try candidates.append(arena, .{ .name = name, .has_skill_md = true });
    }
    std.mem.sort(SkillCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: SkillCandidate, b: SkillCandidate) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    var skills = std.ArrayListUnmanaged(adapters.Skill).empty;
    for (candidates.items) |candidate| {
        try skills.append(arena, try readSkill(arena, io, skills_dir, candidate.name));
    }
    return skills.items;
}

fn readSkill(
    arena: std.mem.Allocator,
    io: std.Io,
    skills_dir: []const u8,
    dir_name: []const u8,
) errors.Error!adapters.Skill {
    const files = try readDirFiles(arena, io, try std.fs.path.join(arena, &.{ skills_dir, dir_name }), "");
    var skill_file: ?adapters.SkillFile = null;
    for (files) |file| {
        if (std.mem.eql(u8, file.path, "SKILL.md")) skill_file = file;
    }
    const content = (skill_file orelse
        return distributeError(arena, "{s}/SKILL.md is missing", .{dir_name})).content;

    const parsed = try parse.parseFile(arena, content);
    const frontmatter = parsed.frontmatter orelse {
        if (!hasFrontmatterFence(content)) {
            return distributeError(arena, "{s}/SKILL.md has no YAML frontmatter", .{dir_name});
        }
        return distributeError(arena, "{s}/SKILL.md frontmatter must be a YAML mapping", .{dir_name});
    };
    const name = parse.scalar(frontmatter, "name") orelse
        return distributeError(arena, "{s}/SKILL.md must declare a non-empty name and description", .{dir_name});
    const description = parse.scalar(frontmatter, "description") orelse
        return distributeError(arena, "{s}/SKILL.md must declare a non-empty name and description", .{dir_name});
    if (!std.mem.eql(u8, name, dir_name)) {
        return distributeError(
            arena,
            "{s}/SKILL.md declares name \"{s}\"; the directory name must match it",
            .{ dir_name, name },
        );
    }
    if (!std.mem.startsWith(u8, name, adapters.SKILL_PREFIX)) {
        return distributeError(arena, "{s}: skill names must start with \"{s}\"", .{ dir_name, adapters.SKILL_PREFIX });
    }
    return .{
        .id = name[adapters.SKILL_PREFIX.len..],
        .name = name,
        .description = description,
        .files = files,
    };
}

fn hasFrontmatterFence(content: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, content, '\n');
    const first = iterator.next() orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, first, " \t\r"), "---");
}

fn readDirFiles(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    prefix: []const u8,
) errors.Error![]adapters.SkillFile {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return distributeError(arena, "Unable to read {s}", .{dir_path});
    };
    defer dir.close(io);
    const Entry = struct { name: []const u8, directory: bool };
    var entries = std.ArrayListUnmanaged(Entry).empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        const name = try arena.dupe(u8, entry.name);
        switch (entry.kind) {
            .directory => try entries.append(arena, .{ .name = name, .directory = true }),
            .file => try entries.append(arena, .{ .name = name, .directory = false }),
            else => {},
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    var files = std.ArrayListUnmanaged(adapters.SkillFile).empty;
    for (entries.items) |entry| {
        const path = if (prefix.len == 0)
            entry.name
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        const abs = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        if (entry.directory) {
            const nested = try readDirFiles(arena, io, abs, path);
            try files.appendSlice(arena, nested);
        } else {
            const content = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(1 << 22)) catch {
                return distributeError(arena, "Unable to read {s}", .{abs});
            };
            try files.append(arena, .{ .path = path, .content = content });
        }
    }
    return files.items;
}

// ---------------------------------------------------------------------------
// Expected files and reconcile

pub fn expectedFiles(
    arena: std.mem.Allocator,
    skills: []const adapters.Skill,
    tools: []const adapters.Tool,
) error{OutOfMemory}![]adapters.GeneratedFile {
    var files = std.ArrayListUnmanaged(adapters.GeneratedFile).empty;
    try files.append(arena, .{ .path = CONTEXT_IGNORE_PATH, .content = CONTEXT_IGNORE_CONTENT });
    for (tools) |tool| {
        const skill_files = try adapters.renderSkillFiles(arena, tool, skills);
        try files.appendSlice(arena, skill_files);
        const command_files = try adapters.renderCommandFiles(arena, tool, skills);
        try files.appendSlice(arena, command_files);
    }
    std.mem.sort(adapters.GeneratedFile, files.items, {}, struct {
        fn lessThan(_: void, a: adapters.GeneratedFile, b: adapters.GeneratedFile) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);
    return files.items;
}

pub fn initProject(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    tools: []const adapters.Tool,
    skills: []const adapters.Skill,
    version: []const u8,
    rule_flag: bool,
) errors.Error!ApplyReport {
    const previous_config = try config_m.readConfig(arena, io, root);
    const previous: []const []const u8 = if (previous_config) |config| config.files else &.{};
    return reconcile(arena, io, root, tools, skills, version, previous, rule_flag);
}

pub fn syncProject(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    skills: []const adapters.Skill,
    version: []const u8,
    rule_flag: bool,
) errors.Error!ApplyReport {
    const config = (try config_m.readConfig(arena, io, root)) orelse
        return distributeError(arena, "No {s} under {s}. Run \"specrail init\" first.", .{ config_m.CONFIG_PATH, root });
    return reconcile(arena, io, root, config.tools, skills, version, config.files, rule_flag);
}

fn reconcile(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    tools: []const adapters.Tool,
    skills: []const adapters.Skill,
    version: []const u8,
    previous: []const []const u8,
    rule_flag: bool,
) errors.Error!ApplyReport {
    const files = try expectedFiles(arena, skills, tools);
    var paths = std.ArrayListUnmanaged([]const u8).empty;
    for (files) |file| try paths.append(arena, file.path);

    for (files) |file| {
        const abs = try std.fs.path.join(arena, &.{ root, file.path });
        if (std.fs.path.dirname(abs)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
                return distributeError(arena, "Unable to write {s}: {s}", .{ file.path, @errorName(err) });
            };
        }
        var handle = std.Io.Dir.cwd().createFile(io, abs, .{ .truncate = true }) catch |err| {
            return distributeError(arena, "Unable to write {s}: {s}", .{ file.path, @errorName(err) });
        };
        handle.writeStreamingAll(io, file.content) catch |err| {
            handle.close(io);
            return distributeError(arena, "Unable to write {s}: {s}", .{ file.path, @errorName(err) });
        };
        handle.close(io);
    }

    var removed = std.ArrayListUnmanaged([]const u8).empty;
    for (previous) |rel| {
        var still_expected = false;
        for (paths.items) |path| {
            if (std.mem.eql(u8, path, rel)) {
                still_expected = true;
                break;
            }
        }
        if (still_expected) continue;
        const abs = try std.fs.path.join(arena, &.{ root, rel });
        if ((std.Io.Dir.cwd().statFile(io, abs, .{}) catch null) == null) continue;
        std.Io.Dir.cwd().deleteFile(io, abs) catch |err| {
            return distributeError(arena, "Unable to remove {s}: {s}", .{ rel, @errorName(err) });
        };
        try removed.append(arena, rel);
    }

    const agents_path = try std.fs.path.join(arena, &.{ root, AGENTS_FILE });
    var rule_written = false;
    if (rule_flag or try rule.hasRuleBlock(arena, io, agents_path)) {
        try rule.upsertRuleBlock(arena, io, agents_path, rule.RULE_TEXT);
        rule_written = true;
    }

    try config_m.writeConfig(arena, io, root, .{
        .version = version,
        .tools = tools,
        .files = paths.items,
    });

    return .{
        .tools = tools,
        .files = paths.items,
        .removed = removed.items,
        .rule_written = rule_written,
    };
}
