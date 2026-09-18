const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const version = std.mem.trim(u8, try b.build_root.handle.readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        .limited(64),
    ), " \t\r\n");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library face shared with the build-time skills generator.
    const host_lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });

    // Embed the validated skills/ directory into the binary at build time.
    const embed_tool_module = b.createModule(.{
        .root_source_file = b.path("tools/embed_skills.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    embed_tool_module.addImport("specrail", host_lib_module);
    const embed_tool = b.addExecutable(.{ .name = "embed-skills", .root_module = embed_tool_module });
    const run_embed = b.addRunArtifact(embed_tool);
    run_embed.addDirectoryArg(b.path("skills"));
    const generated_skills = run_embed.addOutputFileArg("embedded_skills.zig");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("build_options", options.createModule());
    exe_module.addAnonymousImport("embedded_skills", .{
        .root_source_file = generated_skills,
    });
    const exe = b.addExecutable(.{ .name = "specrail", .root_module = exe_module });
    b.installArtifact(exe);

    const unit_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    unit_module.addImport("build_options", options.createModule());
    const golden_options = b.addOptions();
    golden_options.addOption([]const u8, "serialize", try b.build_root.handle.readFileAlloc(
        b.graph.io,
        "test/golden/serialize.json",
        b.allocator,
        .limited(1 << 20),
    ));
    golden_options.addOption([]const u8, "update", try b.build_root.handle.readFileAlloc(
        b.graph.io,
        "test/golden/update.json",
        b.allocator,
        .limited(1 << 20),
    ));
    unit_module.addImport("golden", golden_options.createModule());
    const unit_tests = b.addTest(.{ .root_module = unit_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);

    const e2e_module = b.createModule(.{
        .root_source_file = b.path("test/e2e_cli.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("cli_exe", exe.getEmittedBin());
    e2e_options.addOptionPath("fixture", b.path("test/golden/cli-fixture"));
    e2e_module.addImport("cli_exe", e2e_options.createModule());
    const e2e_tests = b.addTest(.{ .root_module = e2e_module });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    const e2e_step = b.step("test-e2e", "Run e2e tests against the built CLI");
    e2e_step.dependOn(&run_e2e_tests.step);

    const e2e_write_module = b.createModule(.{
        .root_source_file = b.path("test/e2e_write.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    e2e_write_module.addImport("cli_exe", e2e_options.createModule());
    const e2e_write_tests = b.addTest(.{ .root_module = e2e_write_module });
    const run_e2e_write_tests = b.addRunArtifact(e2e_write_tests);
    e2e_step.dependOn(&run_e2e_write_tests.step);

    const e2e_init_module = b.createModule(.{
        .root_source_file = b.path("test/e2e_init.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    e2e_init_module.addImport("cli_exe", e2e_options.createModule());
    const e2e_init_tests = b.addTest(.{ .root_module = e2e_init_module });
    const run_e2e_init_tests = b.addRunArtifact(e2e_init_tests);
    e2e_step.dependOn(&run_e2e_init_tests.step);

    // ---- distributable plugin assembly -----------------------------------

    const TargetSpec = struct { name: []const u8, query: std.Target.Query };
    const plugin_targets = [_]TargetSpec{
        .{ .name = "darwin-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "darwin-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "linux-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
        .{ .name = "linux-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
        .{ .name = "windows-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows } },
        .{ .name = "windows-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
    };
    const host_os = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => "darwin",
    };
    const host_arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => "arm64",
    };
    const host_target_name = b.fmt("{s}-{s}", .{ host_os, host_arch });

    const plugin_current = b.option(bool, "current", "Build only the host platform plugin artifact") orelse false;
    const plugin_outdir = b.option([]const u8, "outdir", "Override the plugin destination directory");

    const build_plugin_module = b.createModule(.{
        .root_source_file = b.path("tools/build_plugin.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    build_plugin_module.addImport("specrail", host_lib_module);
    const build_plugin_exe = b.addExecutable(.{ .name = "build-plugin", .root_module = build_plugin_module });

    const Artifact = struct { name: []const u8, exe: *std.Build.Step.Compile };
    var plugin_artifacts: std.ArrayListUnmanaged(Artifact) = .empty;
    for (plugin_targets) |spec| {
        if (plugin_current and !std.mem.eql(u8, spec.name, host_target_name)) continue;
        const plugin_target = b.resolveTargetQuery(spec.query);
        const plugin_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = plugin_target,
            .optimize = .ReleaseSmall,
            .strip = true,
        });
        plugin_module.addImport("build_options", options.createModule());
        plugin_module.addAnonymousImport("embedded_skills", .{
            .root_source_file = generated_skills,
        });
        const plugin_exe = b.addExecutable(.{ .name = "specrail", .root_module = plugin_module });
        try plugin_artifacts.append(b.allocator, .{ .name = spec.name, .exe = plugin_exe });
    }

    const plugin_step = b.step("plugin", "Assemble the distributable plugin (plugins/specrail)");
    const run_plugin = b.addRunArtifact(build_plugin_exe);
    run_plugin.addArg("--root");
    run_plugin.addDirectoryArg(b.path("."));
    run_plugin.addArg("--version");
    run_plugin.addArg(version);
    run_plugin.addArg("--destination");
    if (plugin_outdir) |outdir| {
        run_plugin.addDirectoryArg(b.path(outdir));
    } else {
        run_plugin.addDirectoryArg(b.path("plugins/specrail"));
    }
    for (plugin_artifacts.items) |artifact| {
        run_plugin.addArg("--artifact");
        run_plugin.addArg(artifact.name);
        run_plugin.addFileArg(artifact.exe.getEmittedBin());
    }
    plugin_step.dependOn(&run_plugin.step);

    const smoke_run = b.addRunArtifact(build_plugin_exe);
    smoke_run.addArg("--root");
    smoke_run.addDirectoryArg(b.path("."));
    smoke_run.addArg("--version");
    smoke_run.addArg(version);
    smoke_run.addArg("--destination");
    const smoke_dir = smoke_run.addOutputDirectoryArg("specrail");
    for (plugin_artifacts.items) |artifact| {
        smoke_run.addArg("--artifact");
        smoke_run.addArg(artifact.name);
        smoke_run.addFileArg(artifact.exe.getEmittedBin());
    }
    const smoke_options = b.addOptions();
    smoke_options.addOptionPath("plugin_dir", smoke_dir);
    smoke_options.addOptionPath("skills_dir", b.path("skills"));
    const smoke_module = b.createModule(.{
        .root_source_file = b.path("test/plugin_smoke.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    smoke_module.addImport("plugin_opts", smoke_options.createModule());
    const smoke_tests = b.addTest(.{ .root_module = smoke_module });
    const run_smoke_tests = b.addRunArtifact(smoke_tests);
    b.step("plugin-smoke", "Assemble a plugin tree in the cache and smoke-test it").dependOn(&run_smoke_tests.step);
}
