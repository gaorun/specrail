const std = @import("std");
const regex = @import("regex.zig");

fn matches(arena: std.mem.Allocator, pattern: []const u8, ignore_case: bool, text: []const u8) !bool {
    const compiled = try regex.Regex.compile(arena, pattern, ignore_case);
    return compiled.search(text);
}

test "literal, dot and anchor matching" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(try matches(arena, "foo", false, "a foo b"));
    try std.testing.expect(!try matches(arena, "foo", false, "a bar b"));
    try std.testing.expect(try matches(arena, "f.o", false, "foo"));
    try std.testing.expect(!try matches(arena, "f.o", false, "f\no"));
    try std.testing.expect(try matches(arena, "^foo", false, "foo bar"));
    try std.testing.expect(!try matches(arena, "^foo", false, "bar foo"));
    try std.testing.expect(try matches(arena, "bar$", false, "foo bar"));
    try std.testing.expect(!try matches(arena, "bar$", false, "bar foo"));
    try std.testing.expect(try matches(arena, "", false, "anything"));
    try std.testing.expect(try matches(arena, "规格", false, "跨助手规格 CLI"));
}

test "case-insensitive matching folds ASCII" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(try matches(arena, "HELLO", true, "hello world"));
    try std.testing.expect(!try matches(arena, "HELLO", false, "hello world"));
    try std.testing.expect(try matches(arena, "[a-z]+", true, "ABC"));
}

test "classes, ranges, negation and shorthand escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(try matches(arena, "[abc]+", false, "zzzbzz"));
    try std.testing.expect(!try matches(arena, "[^abc]+", false, "abc"));
    try std.testing.expect(try matches(arena, "[^abc]+", false, "abd"));
    try std.testing.expect(try matches(arena, "[a-c]x", false, "bx"));
    try std.testing.expect(try matches(arena, "\\d+", false, "abc123"));
    try std.testing.expect(!try matches(arena, "\\d+", false, "abcdef"));
    try std.testing.expect(try matches(arena, "\\w+", false, "hello_1"));
    try std.testing.expect(try matches(arena, "\\s", false, "a b"));
    try std.testing.expect(try matches(arena, "[\\d]+x", false, "42x"));
    try std.testing.expect(try matches(arena, "[)]", false, "a)b"));
    try std.testing.expect(try matches(arena, "[]]", false, "x]"));
}

test "quantifiers including bounds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(try matches(arena, "ab*c", false, "ac"));
    try std.testing.expect(try matches(arena, "ab*c", false, "abbbc"));
    try std.testing.expect(try matches(arena, "ab+c", false, "abc"));
    try std.testing.expect(!try matches(arena, "ab+c", false, "ac"));
    try std.testing.expect(try matches(arena, "ab?c", false, "ac"));
    try std.testing.expect(try matches(arena, "a{2}", false, "aa"));
    try std.testing.expect(!try matches(arena, "^a{3}$", false, "aa"));
    try std.testing.expect(try matches(arena, "^a{2,4}$", false, "aaa"));
    try std.testing.expect(!try matches(arena, "^a{2,4}$", false, "aaaaa"));
    try std.testing.expect(try matches(arena, "^a{2,}$", false, "aaaaaa"));
    try std.testing.expect(try matches(arena, "a+?b", false, "aab"));
    try std.testing.expect(try matches(arena, "a{", false, "a{"));
}

test "alternation and groups" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(try matches(arena, "cat|dog", false, "hotdog"));
    try std.testing.expect(try matches(arena, "^(cat|dog)$", false, "dog"));
    try std.testing.expect(!try matches(arena, "^(cat|dog)$", false, "dogcat"));
    try std.testing.expect(try matches(arena, "(ab)+c", false, "ababc"));
    try std.testing.expect(try matches(arena, "(?:ab)+c", false, "ababc"));
    try std.testing.expect(try matches(arena, "mod.*e", false, "specs/module-x.md"));
}

test "invalid patterns are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "(unclosed", "*abc", "+abc", "?abc", "[abc", "a\\", "a)b", "(?=x)" }) |pattern| {
        try std.testing.expectError(error.InvalidPattern, matches(arena, pattern, false, "text"));
    }
}
