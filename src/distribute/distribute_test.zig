const std = @import("std");
const adapters = @import("adapters.zig");
const config_m = @import("config.zig");
const generate = @import("generate.zig");
const rule = @import("rule.zig");

fn fixtureSkill(arena: std.mem.Allocator) !adapters.Skill {
    const files = try arena.dupe(adapters.SkillFile, &.{
        .{ .path = "SKILL.md", .content = "---\nname: specrail-demo\ndescription: \"Demo skill.\"\n---\n\n# Demo\n" },
        .{ .path = "extra.md", .content = "extra\n" },
    });
    return .{ .id = "demo", .name = "specrail-demo", .description = "Demo skill.", .files = files };
}

test "adapters render skill and command files per tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const skills = try arena.dupe(adapters.Skill, &.{try fixtureSkill(arena)});

    const qoder_commands = try adapters.renderCommandFiles(arena, .qoder, skills);
    try std.testing.expectEqual(@as(usize, 1), qoder_commands.len);
    try std.testing.expectEqualStrings(".qoder/commands/specrail/demo.md", qoder_commands[0].path);
    try std.testing.expectEqualStrings(
        "---\nname: \"specrail-demo\"\ndescription: \"Demo skill.\"\ncategory: \"specrail\"\ntags: [\"specrail\"]\n---\n\nRead and follow the skill at `.qoder/skills/specrail-demo/SKILL.md` for the current task.\n",
        qoder_commands[0].content,
    );

    const claude_commands = try adapters.renderCommandFiles(arena, .claude, skills);
    try std.testing.expectEqualStrings(".claude/commands/specrail/demo.md", claude_commands[0].path);
    try std.testing.expect(std.mem.indexOf(u8, claude_commands[0].content, "allowed-tools: Bash(specrail:*)") != null);
    try std.testing.expect(std.mem.endsWith(u8, claude_commands[0].content, "\n\n**Input**: $ARGUMENTS\n"));

    const pi_commands = try adapters.renderCommandFiles(arena, .pi, skills);
    try std.testing.expectEqualStrings(".pi/prompts/specrail-demo.md", pi_commands[0].path);
    try std.testing.expect(std.mem.endsWith(u8, pi_commands[0].content, "\n\n**Input**: $@\n"));

    const codex_commands = try adapters.renderCommandFiles(arena, .codex, skills);
    try std.testing.expectEqual(@as(usize, 0), codex_commands.len);

    const codex_skills = try adapters.renderSkillFiles(arena, .codex, skills);
    try std.testing.expectEqualStrings(".agents/skills/specrail-demo/SKILL.md", codex_skills[0].path);
    try std.testing.expectEqualStrings(".agents/skills/specrail-demo/extra.md", codex_skills[1].path);
}

test "expectedFiles sorts by path and includes the context ignore file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const skills = try arena.dupe(adapters.Skill, &.{try fixtureSkill(arena)});
    const tools = try arena.dupe(adapters.Tool, &.{ .qoder, .codex });
    const files = try generate.expectedFiles(arena, skills, tools);
    var found_ignore = false;
    for (files) |file| {
        if (std.mem.eql(u8, file.path, ".specrail/.gitignore")) {
            found_ignore = true;
            try std.testing.expectEqualStrings("context/\n", file.content);
        }
    }
    try std.testing.expect(found_ignore);
    var index: usize = 1;
    while (index < files.len) : (index += 1) {
        try std.testing.expect(std.mem.order(u8, files[index - 1].path, files[index].path) == .lt);
    }
}

test "config round-trips and validates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    try config_m.writeConfig(arena, io, root, .{
        .version = "0.1.0",
        .tools = &.{ .qoder, .pi },
        .files = &.{ ".specrail/.gitignore", ".qoder/commands/specrail/demo.md" },
    });
    const read_back = (try config_m.readConfig(arena, io, root)).?;
    try std.testing.expectEqualStrings("0.1.0", read_back.version);
    try std.testing.expectEqual(@as(usize, 2), read_back.tools.len);
    try std.testing.expectEqual(adapters.Tool.qoder, read_back.tools[0]);
    try std.testing.expectEqual(@as(usize, 2), read_back.files.len);

    const bad_cases = [_]struct { content: []const u8, message: []const u8 }{
        .{ .content = "[]\n", .message = ".specrail/config.json must be a JSON object" },
        .{ .content = "{}\n", .message = ".specrail/config.json must declare a specrail version" },
        .{ .content = "{\"version\":\"1\",\"tools\":[\"nope\"],\"files\":[]}\n", .message = ".specrail/config.json tools must come from: qoder, claude, codex, pi" },
        .{ .content = "{\"version\":\"1\",\"tools\":[],\"files\":[\"../x\"]}\n", .message = ".specrail/config.json files must be root-relative paths" },
    };
    const config_path = try std.fs.path.join(arena, &.{ root, config_m.CONFIG_PATH });
    for (bad_cases) |bad| {
        var file = try std.Io.Dir.cwd().createFile(io, config_path, .{ .truncate = true });
        try file.writeStreamingAll(io, bad.content);
        file.close(io);
        std.testing.expectError(error.Distribute, config_m.readConfig(arena, io, root)) catch |err| {
            std.debug.print("expected Distribute for {s}: {t}\n", .{ bad.content, err });
            return err;
        };
        try std.testing.expectEqualStrings(bad.message, @import("../errors.zig").message);
    }
}

test "rule block upserts verbatim, appends, and is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const agents = try std.fs.path.join(arena, &.{ root, "AGENTS.md" });

    try std.testing.expect(!try rule.hasRuleBlock(arena, io, agents));
    try rule.upsertRuleBlock(arena, io, agents, rule.RULE_TEXT);
    const first = try std.Io.Dir.cwd().readFileAlloc(io, agents, arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(rule.RULE_BEGIN ++ "\n" ++ rule.RULE_TEXT ++ "\n" ++ rule.RULE_END ++ "\n", first);
    try std.testing.expect(try rule.hasRuleBlock(arena, io, agents));

    try rule.upsertRuleBlock(arena, io, agents, rule.RULE_TEXT);
    const second = try std.Io.Dir.cwd().readFileAlloc(io, agents, arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(first, second);

    var file = try std.Io.Dir.cwd().createFile(io, agents, .{ .truncate = true });
    try file.writeStreamingAll(io, "# Notes\n\nsome prose");
    file.close(io);
    try rule.upsertRuleBlock(arena, io, agents, rule.RULE_TEXT);
    const appended = try std.Io.Dir.cwd().readFileAlloc(io, agents, arena, .limited(1 << 20));
    try std.testing.expect(std.mem.startsWith(u8, appended, "# Notes\n\nsome prose\n\n"));
    try std.testing.expect(std.mem.endsWith(u8, appended, rule.RULE_END ++ "\n"));
}

test "readSkillsFromDir validates the skill directory contract" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const writeSkill = struct {
        fn call(arena2: std.mem.Allocator, io2: std.Io, base: []const u8, dir: []const u8, content: []const u8) !void {
            const dir_path = try std.fs.path.join(arena2, &.{ base, dir });
            try std.Io.Dir.cwd().createDirPath(io2, dir_path);
            const file_path = try std.fs.path.join(arena2, &.{ dir_path, "SKILL.md" });
            var file = try std.Io.Dir.cwd().createFile(io2, file_path, .{ .truncate = true });
            try file.writeStreamingAll(io2, content);
            file.close(io2);
        }
    }.call;

    try writeSkill(arena, io, root, "specrail-good", "---\nname: specrail-good\ndescription: \"Good.\"\n---\n");
    const skills = try generate.readSkillsFromDir(arena, io, root);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("good", skills[0].id);
    try std.testing.expectEqualStrings("Good.", skills[0].description);

    const bad_cases = [_]struct { dir: []const u8, content: []const u8, message: []const u8 }{
        .{
            .dir = "specrail-name-mismatch",
            .content = "---\nname: specrail-other\ndescription: \"x\"\n---\n",
            .message = "specrail-name-mismatch/SKILL.md declares name \"specrail-other\"; the directory name must match it",
        },
        .{
            .dir = "no-prefix",
            .content = "---\nname: no-prefix\ndescription: \"x\"\n---\n",
            .message = "no-prefix: skill names must start with \"specrail-\"",
        },
        .{
            .dir = "specrail-no-fence",
            .content = "just prose\n",
            .message = "specrail-no-fence/SKILL.md has no YAML frontmatter",
        },
    };
    for (bad_cases, 0..) |bad, index| {
        const case_root = try std.fmt.allocPrint(arena, "{s}/case-{d}", .{ root, index });
        try writeSkill(arena, io, case_root, bad.dir, bad.content);
        std.testing.expectError(error.Distribute, generate.readSkillsFromDir(arena, io, case_root)) catch |err| return err;
        try std.testing.expectEqualStrings(bad.message, @import("../errors.zig").message);
    }
}

test "init writes expected files, then re-init with fewer tools removes the dropped ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const skills = try arena.dupe(adapters.Skill, &.{try fixtureSkill(arena)});
    const all_tools = try arena.dupe(adapters.Tool, &.{ .qoder, .claude, .pi, .codex });

    const first = try generate.initProject(arena, io, root, all_tools, skills, "0.1.0", true);
    try std.testing.expectEqual(@as(usize, 12), first.files.len); // 1 ignore + 2 skill files x4 tools + 1 command x3 tools
    try std.testing.expect(first.rule_written);

    const user_note = try std.fs.path.join(arena, &.{ root, "notes", "mine.md" });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(user_note).?);
    var file = try std.Io.Dir.cwd().createFile(io, user_note, .{});
    try file.writeStreamingAll(io, "user content\n");
    file.close(io);

    const fewer = try arena.dupe(adapters.Tool, &.{.qoder});
    const second = try generate.initProject(arena, io, root, fewer, skills, "0.1.0", false);
    try std.testing.expect(second.removed.len > 0);
    const claude_skill = try std.fs.path.join(arena, &.{ root, ".claude/skills/specrail-demo/SKILL.md" });
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, claude_skill, .{}) catch null) == null);

    const user_content = try std.Io.Dir.cwd().readFileAlloc(io, user_note, arena, .limited(1 << 20));
    try std.testing.expectEqualStrings("user content\n", user_content);
}
