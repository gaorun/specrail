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
    .{ .name = "rule", .kind = .boolean },
};

pub fn run(ctx: *context.Context) anyerror!u8 {
    const parsed = try args_mod.parse(ctx.arena, ctx.argv, &command_specs);
    if (parsed.positionals.items.len > 0) {
        return args_mod.usageError(ctx.arena, "sync takes no positional arguments.", .{});
    }
    const version = version_mod.packageVersion();
    const root = try args_mod.rootFrom(ctx.arena, ctx.io, parsed.stringOf("root"));
    const apply_report = try generate.syncProject(
        ctx.arena,
        ctx.io,
        root,
        try embeddedSkills(ctx.arena),
        version,
        parsed.boolOf("rule"),
    );
    if (parsed.boolOf("json")) {
        try ctx.out.print(try json.stringify(ctx.arena, try report_mod.applyReportJson(ctx.arena, apply_report)));
    } else {
        try report_mod.printApplyReport(ctx, "Synced", apply_report);
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
