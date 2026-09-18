const std = @import("std");
const parse = @import("parse.zig");
const query = @import("query.zig");

fn fm(entries: []const parse.Entry) parse.Frontmatter {
    return .{ .entries = entries };
}

test "grepSpecs matches with metadata filters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]query.SpecContentEntry{
        .{
            .path = "a.md",
            .content = "hello world\nfoo bar",
            .frontmatter = fm(&.{
                .{ .key = "id", .value = .{ .scalar = "a" } },
                .{ .key = "type", .value = .{ .scalar = "module-design" } },
                .{ .key = "tags", .value = .{ .list = &.{"x"} } },
            }),
        },
        .{
            .path = "b.md",
            .content = "hello there",
            .frontmatter = fm(&.{
                .{ .key = "id", .value = .{ .scalar = "b" } },
                .{ .key = "type", .value = .{ .scalar = "task-spec" } },
            }),
        },
    };

    const all = try query.grepSpecs(arena, &entries, .{ .pattern = "hello" });
    try std.testing.expectEqual(@as(usize, 2), all.matches.len);
    try std.testing.expectEqualStrings("a.md", all.matches[0].path);
    try std.testing.expectEqualStrings("b.md", all.matches[1].path);

    const typed = try query.grepSpecs(arena, &entries, .{ .pattern = "hello", .filters = .{ .node_type = "task-spec" } });
    try std.testing.expectEqual(@as(usize, 1), typed.matches.len);
    try std.testing.expectEqualStrings("b.md", typed.matches[0].path);

    const tagged = try query.grepSpecs(arena, &entries, .{ .pattern = "hello", .filters = .{ .tag = "x" } });
    try std.testing.expectEqual(@as(usize, 1), tagged.matches.len);
    try std.testing.expectEqualStrings("a.md", tagged.matches[0].path);

    const regexed = try query.grepSpecs(arena, &entries, .{ .pattern = "^foo", .regex = true });
    try std.testing.expectEqual(@as(usize, 1), regexed.matches.len);
    try std.testing.expectEqual(@as(usize, 2), regexed.matches[0].line);
}

test "grepSpecs marks truncated only when a match exists beyond the limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]query.SpecContentEntry{
        .{
            .path = "a.md",
            .content = "x\nx\nx",
            .frontmatter = fm(&.{.{ .key = "id", .value = .{ .scalar = "a" } }, .{ .key = "type", .value = .{ .scalar = "t" } }}),
        },
    };
    const exact = try query.grepSpecs(arena, &entries, .{ .pattern = "x", .limit = 3 });
    try std.testing.expectEqual(@as(usize, 3), exact.matches.len);
    try std.testing.expect(!exact.truncated);

    const cut = try query.grepSpecs(arena, &entries, .{ .pattern = "x", .limit = 2 });
    try std.testing.expectEqual(@as(usize, 2), cut.matches.len);
    try std.testing.expect(cut.truncated);
}

test "grepSpecs strips the CR of a CRLF spec so anchored patterns still match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]query.SpecContentEntry{
        .{
            .path = "a.md",
            .content = "---\r\nid: a\r\ntype: t\r\n---\r\nhello world\r\n",
            .frontmatter = fm(&.{.{ .key = "id", .value = .{ .scalar = "a" } }, .{ .key = "type", .value = .{ .scalar = "t" } }}),
        },
    };
    const anchored_end = try query.grepSpecs(arena, &entries, .{ .pattern = "world$", .regex = true });
    try std.testing.expectEqual(@as(usize, 1), anchored_end.matches.len);
    const anchored_start = try query.grepSpecs(arena, &entries, .{ .pattern = "^hello", .regex = true });
    try std.testing.expectEqualStrings("hello world", anchored_start.matches[0].snippet);
}

test "grepSpecs falls back to the default limit rather than reporting a silent truncation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]query.SpecContentEntry{
        .{
            .path = "a.md",
            .content = "x\nx",
            .frontmatter = fm(&.{.{ .key = "id", .value = .{ .scalar = "a" } }, .{ .key = "type", .value = .{ .scalar = "t" } }}),
        },
    };
    for ([_]f64{ 0, -5, 0.5 }) |limit| {
        const result = try query.grepSpecs(arena, &entries, .{ .pattern = "x", .limit = limit });
        try std.testing.expectEqual(@as(usize, 2), result.matches.len);
        try std.testing.expect(!result.truncated);
    }
    try std.testing.expectEqual(@as(usize, 200), query.DEFAULT_GREP_LIMIT);
}

test "grepSpecs reports invalid patterns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]query.SpecContentEntry{
        .{
            .path = "a.md",
            .content = "hello",
            .frontmatter = fm(&.{.{ .key = "id", .value = .{ .scalar = "a" } }, .{ .key = "type", .value = .{ .scalar = "t" } }}),
        },
    };
    try std.testing.expectError(error.InvalidPattern, query.grepSpecs(arena, &entries, .{ .pattern = "(unclosed", .regex = true }));
}
