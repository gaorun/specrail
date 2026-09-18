const std = @import("std");
const args = @import("args.zig");
const errors = @import("../errors.zig");

const Expect = union(enum) {
    ok: Ok,
    help,
    version,
    usage: []const u8,
};

const Ok = struct {
    positionals: []const []const u8 = &.{},
    root: ?[]const u8 = null,
    json: bool = false,
    tags: []const []const u8 = &.{},
};

const type_specs = [_]args.Spec{.{ .name = "type" }};
const tags_specs = [_]args.Spec{.{ .name = "tags", .multiple = true }};
const limit_specs = [_]args.Spec{.{ .name = "limit" }};

const unknown_long_message = "Unknown option '--bogus'. To specify a positional argument starting with a '-', place it at the end of the command after '--', as in '-- \"--bogus\"";
const unknown_short_message = "Unknown option '-b'. To specify a positional argument starting with a '-', place it at the end of the command after '--', as in '-- \"-b\"";
const ambiguous_message = "Option '--root' argument is ambiguous.\nDid you forget to specify the option argument for '--root'?\nTo specify an option argument starting with a dash use '--root=-XYZ'.";

const cases = [_]struct {
    name: []const u8,
    argv: []const []const u8,
    specs: []const args.Spec = &.{},
    expect: Expect,
}{
    .{ .name = "empty", .argv = &.{}, .expect = .{ .ok = .{} } },
    .{ .name = "help-short", .argv = &.{"-h"}, .expect = .help },
    .{ .name = "version-long", .argv = &.{"--version"}, .expect = .version },
    .{ .name = "bundled-hv", .argv = &.{"-hv"}, .expect = .help },
    .{ .name = "unknown-long", .argv = &.{"--bogus"}, .expect = .{ .usage = unknown_long_message } },
    .{ .name = "unknown-short", .argv = &.{"-b"}, .expect = .{ .usage = unknown_short_message } },
    .{ .name = "missing-arg", .argv = &.{"--root"}, .expect = .{ .usage = "Option '--root <value>' argument missing" } },
    .{ .name = "ambiguous-dash-next", .argv = &.{ "--root", "--json" }, .expect = .{ .usage = ambiguous_message } },
    .{ .name = "ambiguous-dash-next-unknown", .argv = &.{ "--root", "-x" }, .expect = .{ .usage = ambiguous_message } },
    .{ .name = "boolean-with-value", .argv = &.{"--json=x"}, .expect = .{ .usage = "Option '--json' does not take an argument" } },
    .{
        .name = "boolean-then-positional",
        .argv = &.{ "--json", "x" },
        .expect = .{ .ok = .{ .json = true, .positionals = &.{"x"} } },
    },
    .{
        .name = "value-equals-form",
        .argv = &.{ "--root=/tmp", "--type", "t" },
        .specs = &type_specs,
        .expect = .{ .ok = .{ .root = "/tmp" } },
    },
    .{
        .name = "terminator",
        .argv = &.{ "--", "a", "b", "-c" },
        .expect = .{ .ok = .{ .positionals = &.{ "a", "b", "-c" } } },
    },
    .{
        .name = "positional-dash-late",
        .argv = &.{ "arg1", "--", "--dash" },
        .expect = .{ .ok = .{ .positionals = &.{ "arg1", "--dash" } } },
    },
    .{
        .name = "repeated-string-last-wins",
        .argv = &.{ "--root", "r1", "--root", "r2" },
        .expect = .{ .ok = .{ .root = "r2" } },
    },
    .{
        .name = "multiple-collects",
        .argv = &.{ "--tags", "a", "--tags", "b" },
        .specs = &tags_specs,
        .expect = .{ .ok = .{ .tags = &.{ "a", "b" } } },
    },
    .{ .name = "empty-value", .argv = &.{ "--root", "" }, .expect = .{ .ok = .{ .root = "" } } },
    .{ .name = "dash-value-equals", .argv = &.{"--root=-x"}, .expect = .{ .ok = .{ .root = "-x" } } },
    .{
        .name = "short-unknown-combined",
        .argv = &.{"-vh"},
        .expect = .help,
    },
    .{
        .name = "number-flag-ok",
        .argv = &.{ "--limit", "1.5" },
        .specs = &limit_specs,
        .expect = .{ .ok = .{} },
    },
};

test "parse matches captured parseArgs behavior" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (cases) |case| {
        errors.message = "";
        const outcome = args.parse(arena, case.argv, case.specs);
        switch (case.expect) {
            .ok => |expected| {
                const parsed = outcome catch |err| {
                    std.debug.print("case {s}: unexpected error {t} (message: {s})\n", .{ case.name, err, errors.message });
                    return error.TestUnexpectedResult;
                };
                try std.testing.expectEqual(expected.json, parsed.boolOf("json"));
                const root = parsed.stringOf("root");
                try std.testing.expectEqual(expected.root == null, root == null);
                if (expected.root) |wanted| try std.testing.expectEqualStrings(wanted, root.?);
                try std.testing.expectEqual(expected.positionals.len, parsed.positionals.items.len);
                for (expected.positionals, parsed.positionals.items) |wanted, actual| {
                    try std.testing.expectEqualStrings(wanted, actual);
                }
                const tags = parsed.listOf("tags");
                try std.testing.expectEqual(expected.tags.len, tags.len);
                for (expected.tags, tags) |wanted, actual| {
                    try std.testing.expectEqualStrings(wanted, actual);
                }
            },
            .help => try std.testing.expectError(error.HelpRequested, outcome),
            .version => try std.testing.expectError(error.VersionRequested, outcome),
            .usage => |wanted| {
                try std.testing.expectError(error.Usage, outcome);
                try std.testing.expectEqualStrings(wanted, errors.message);
            },
        }
    }
}

test "numberFrom mirrors JS Number coercion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(?f64, null), try args.numberFrom(arena, null, "limit"));
    try std.testing.expectEqual(@as(?f64, 0), try args.numberFrom(arena, "", "limit"));
    try std.testing.expectEqual(@as(?f64, 16), try args.numberFrom(arena, "0x10", "limit"));
    try std.testing.expectEqual(@as(?f64, 5), try args.numberFrom(arena, "0b101", "limit"));
    try std.testing.expectEqual(@as(?f64, 15), try args.numberFrom(arena, "0o17", "limit"));
    try std.testing.expectEqual(@as(?f64, 1.5), try args.numberFrom(arena, "1.5", "limit"));
    try std.testing.expectEqual(@as(?f64, 12), try args.numberFrom(arena, " 12 ", "limit"));
    try std.testing.expectEqual(@as(?f64, 1000), try args.numberFrom(arena, "1e3", "limit"));

    errors.message = "";
    try std.testing.expectError(error.Usage, args.numberFrom(arena, "abc", "limit"));
    try std.testing.expectEqualStrings("--limit must be a number, got \"abc\"", errors.message);

    errors.message = "";
    try std.testing.expectError(error.Usage, args.numberFrom(arena, "1e999", "limit"));
    try std.testing.expectEqualStrings("--limit must be a number, got \"1e999\"", errors.message);
}
