const std = @import("std");
const adapters = @import("../../distribute/adapters.zig");
const generate = @import("../../distribute/generate.zig");
const json = @import("../../json.zig");
const args_mod = @import("../args.zig");
const context = @import("../context.zig");
const report_mod = @import("../report.zig");
const version_mod = @import("../version.zig");
const embedded = @import("embedded_skills");

const command_specs = [_]args_mod.Spec{
    .{ .name = "tools" },
    .{ .name = "rule", .kind = .boolean },
};

fn parseTools(ctx: *context.Context, value: ?[]const u8) args_mod.Error![]const adapters.Tool {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var iterator = std.mem.splitScalar(u8, value orelse "", ',');
    while (iterator.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len > 0) try names.append(ctx.arena, name);
    }
    if (names.items.len == 0) {
        return args_mod.usageError(ctx.arena, "--tools is required: qoder, claude, codex, pi", .{});
    }
    var tools = std.ArrayListUnmanaged(adapters.Tool).empty;
    for (names.items) |name| {
        const tool = adapters.Tool.fromName(name) orelse
            return args_mod.usageError(ctx.arena, "--tools must be a comma-separated list of: qoder, claude, codex, pi", .{});
        var present = false;
        for (tools.items) |existing| {
            if (existing == tool) {
                present = true;
                break;
            }
        }
        if (!present) try tools.append(ctx.arena, tool);
    }
    return tools.items;
}

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &command_specs);
    if (parsed.positionals.items.len > 0) {
        return args_mod.usageError(ctx.arena, "init takes no positional arguments.", .{});
    }
    const tools = try parseTools(ctx, parsed.stringOf("tools"));
    const version = version_mod.packageVersion();
    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    const apply_report = try generate.initProject(
        ctx.arena,
        ctx.io,
        root,
        tools,
        try embeddedSkills(ctx.arena),
        version,
        parsed.boolOf("rule"),
    );
    if (parsed.boolOf("json")) {
        try ctx.out.print(try json.stringify(ctx.arena, try report_mod.applyReportJson(ctx.arena, apply_report)));
    } else {
        try report_mod.printApplyReport(ctx, "Initialized", apply_report);
    }
    return 0;
}

fn embeddedSkills(arena: std.mem.Allocator) error{OutOfMemory}![]adapters.Skill {
    var skills = std.ArrayListUnmanaged(adapters.Skill).empty;
    for (embedded.skills) |skill| {
        var files = std.ArrayListUnmanaged(adapters.SkillFile).empty;
        for (skill.files) |file| {
            try files.append(arena, .{ .path = file.path, .content = file.content });
        }
        try skills.append(arena, .{
            .id = skill.id,
            .name = skill.name,
            .description = skill.description,
            .files = files.items,
        });
    }
    return skills.items;
}
