const std = @import("std");
const json = @import("../json.zig");

pub const SKILL_PREFIX = "specrail-";
pub const COMMAND_SCOPE = "specrail";

/// Message order matters: it appears verbatim in usage errors and config
/// validation messages.
pub const TOOL_NAMES = [_][]const u8{ "qoder", "claude", "codex", "pi" };

pub const Tool = enum {
    qoder,
    claude,
    codex,
    pi,

    pub fn name(self: Tool) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(text: []const u8) ?Tool {
        inline for (std.meta.tags(Tool)) |tool| {
            if (std.mem.eql(u8, @tagName(tool), text)) return tool;
        }
        return null;
    }
};

pub const SkillFile = struct {
    path: []const u8,
    content: []const u8,
};

pub const Skill = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    files: []const SkillFile,
};

pub const GeneratedFile = struct {
    path: []const u8,
    content: []const u8,
};

fn skillsRoot(tool: Tool) []const u8 {
    return switch (tool) {
        .pi => ".pi/skills",
        .qoder => ".qoder/skills",
        .claude => ".claude/skills",
        .codex => ".agents/skills",
    };
}

fn scalarValue(arena: std.mem.Allocator, value: []const u8) error{OutOfMemory}![]const u8 {
    return json.stringify(arena, .{ .string = value });
}

fn tagsLine(arena: std.mem.Allocator, tags: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeByte('[') catch return error.OutOfMemory;
    for (tags, 0..) |tag, index| {
        if (index > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(try scalarValue(arena, tag)) catch return error.OutOfMemory;
    }
    out.writer.writeByte(']') catch return error.OutOfMemory;
    return out.written();
}

fn commandPath(arena: std.mem.Allocator, tool: Tool, skill: Skill) error{OutOfMemory}![]const u8 {
    return switch (tool) {
        .pi => std.fmt.allocPrint(arena, ".pi/prompts/{s}.md", .{skill.name}),
        .qoder => std.fmt.allocPrint(arena, ".qoder/commands/{s}/{s}.md", .{ COMMAND_SCOPE, skill.id }),
        .claude => std.fmt.allocPrint(arena, ".claude/commands/{s}/{s}.md", .{ COMMAND_SCOPE, skill.id }),
        .codex => unreachable,
    };
}

fn commandFrontmatter(arena: std.mem.Allocator, tool: Tool, skill: Skill) error{OutOfMemory}!?[]const u8 {
    const scope = json.stringify(arena, .{ .string = COMMAND_SCOPE }) catch return error.OutOfMemory;
    return switch (tool) {
        .pi => try std.fmt.allocPrint(arena, "description: {s}", .{try scalarValue(arena, skill.description)}),
        .qoder => try std.fmt.allocPrint(arena, "name: {s}\ndescription: {s}\ncategory: {s}\ntags: {s}", .{
            try scalarValue(arena, skill.name),
            try scalarValue(arena, skill.description),
            scope,
            try tagsLine(arena, &.{COMMAND_SCOPE}),
        }),
        .claude => try std.fmt.allocPrint(arena, "name: {s}\ndescription: {s}\nallowed-tools: Bash({s}:*)\ncategory: {s}\ntags: {s}", .{
            try scalarValue(arena, skill.name),
            try scalarValue(arena, skill.description),
            COMMAND_SCOPE,
            scope,
            try tagsLine(arena, &.{COMMAND_SCOPE}),
        }),
        .codex => null,
    };
}

fn commandInput(tool: Tool) ?[]const u8 {
    return switch (tool) {
        .pi => "$@",
        .claude => "$ARGUMENTS",
        .qoder, .codex => null,
    };
}

pub fn renderSkillFiles(
    arena: std.mem.Allocator,
    tool: Tool,
    skills: []const Skill,
) error{OutOfMemory}![]GeneratedFile {
    var files = std.ArrayListUnmanaged(GeneratedFile).empty;
    const root = skillsRoot(tool);
    for (skills) |skill| {
        for (skill.files) |file| {
            try files.append(arena, .{
                .path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ root, skill.name, file.path }),
                .content = file.content,
            });
        }
    }
    return files.items;
}

pub fn renderCommandFiles(
    arena: std.mem.Allocator,
    tool: Tool,
    skills: []const Skill,
) error{OutOfMemory}![]GeneratedFile {
    if (tool == .codex) return &.{};
    var files = std.ArrayListUnmanaged(GeneratedFile).empty;
    for (skills) |skill| {
        const skill_path = try std.fmt.allocPrint(arena, "{s}/{s}/SKILL.md", .{ skillsRoot(tool), skill.name });
        const frontmatter = (try commandFrontmatter(arena, tool, skill)).?;
        const input_suffix = if (commandInput(tool)) |input|
            try std.fmt.allocPrint(arena, "\n\n**Input**: {s}", .{input})
        else
            "";
        try files.append(arena, .{
            .path = try commandPath(arena, tool, skill),
            .content = try std.fmt.allocPrint(
                arena,
                "---\n{s}\n---\n\nRead and follow the skill at `{s}` for the current task.{s}\n",
                .{ frontmatter, skill_path, input_suffix },
            ),
        });
    }
    return files.items;
}
