const std = @import("std");
const parse = @import("parse.zig");
const golden = @import("golden");

const serialize_golden = golden.serialize;
const update_golden = golden.update;

fn frontmatterFromJson(allocator: std.mem.Allocator, entries_json: std.json.Array) !parse.Frontmatter {
    var entries = std.ArrayListUnmanaged(parse.Entry).empty;
    for (entries_json.items) |item| {
        const pair = item.array;
        const key = pair.items[0].string;
        const value_json = pair.items[1];
        switch (value_json) {
            .string => |text| try entries.append(allocator, .{ .key = key, .value = .{ .scalar = text } }),
            .array => |items| {
                var list_items = std.ArrayListUnmanaged([]const u8).empty;
                for (items.items) |list_item| try list_items.append(allocator, list_item.string);
                try entries.append(allocator, .{ .key = key, .value = .{ .list = list_items.items } });
            },
            else => return error.TestUnexpectedResult,
        }
    }
    return .{ .entries = entries.items };
}

test "golden: serializeFrontmatter matches every captured case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, serialize_golden, .{});
    for (parsed.value.array.items) |case| {
        const name = case.object.get("name").?.string;
        const frontmatter = try frontmatterFromJson(arena, case.object.get("entries").?.array);
        const expected = case.object.get("output").?.string;
        const actual = try parse.serializeFrontmatter(arena, frontmatter);
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("serialize case {s}:\n  expected {s}\n  actual   {s}\n", .{ name, expected, actual });
            return error.TestUnexpectedResult;
        }
    }
}

fn entryListFromJson(allocator: std.mem.Allocator, object: ?std.json.Value) ![]const parse.Entry {
    const value = object orelse return &.{};
    var entries = std.ArrayListUnmanaged(parse.Entry).empty;
    var iterator = value.object.iterator();
    while (iterator.next()) |kv| {
        switch (kv.value_ptr.*) {
            .string => |text| try entries.append(allocator, .{ .key = kv.key_ptr.*, .value = .{ .scalar = text } }),
            .array => |items| {
                var list_items = std.ArrayListUnmanaged([]const u8).empty;
                for (items.items) |list_item| try list_items.append(allocator, list_item.string);
                try entries.append(allocator, .{ .key = kv.key_ptr.*, .value = .{ .list = list_items.items } });
            },
            else => return error.TestUnexpectedResult,
        }
    }
    return entries.items;
}

fn editFromJson(allocator: std.mem.Allocator, edit_json: std.json.ObjectMap) !parse.FrontmatterEdit {
    var remove = std.ArrayListUnmanaged([]const u8).empty;
    if (edit_json.get("remove")) |value| {
        for (value.array.items) |item| try remove.append(allocator, item.string);
    }
    return .{
        .set = try entryListFromJson(allocator, edit_json.get("set")),
        .remove = remove.items,
        .add_list = try entryListFromJson(allocator, edit_json.get("addList")),
        .remove_list = try entryListFromJson(allocator, edit_json.get("removeList")),
    };
}

/// Deliberate contract-level deviations from the captured yaml-lib behavior:
/// the Zig editor preserves untouched block lists verbatim and emits a
/// canonical block literal for multi-line scalars.
fn patchedExpectation(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "block-list-untouched")) {
        return "---\nid: a\ntype: task-spec\ntags:\n  - one\n  - two\nstatus: draft\ntitle: B\n---\n";
    }
    if (std.mem.eql(u8, name, "set-multiline-value")) {
        return "---\nid: alpha\ntype: task-spec\ntitle: |-\n  l1\n  l2\nstatus: draft\ntags: [one, two]\n---\n";
    }
    return null;
}

test "golden: updateFrontmatterText matches every captured case (with documented deviations)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, update_golden, .{});
    for (parsed.value.array.items) |case| {
        const name = case.object.get("name").?.string;
        const file = case.object.get("file").?.string;
        const edit = try editFromJson(arena, case.object.get("edit").?.object);
        const result = try parse.updateFrontmatterText(arena, file, edit);
        const result_json = case.object.get("result").?.object;
        if (result_json.get("error")) |expected_error| {
            switch (result) {
                .err => |message| {
                    if (!std.mem.eql(u8, expected_error.string, message)) {
                        std.debug.print("update case {s}: expected error {s}, got {s}\n", .{ name, expected_error.string, message });
                        return error.TestUnexpectedResult;
                    }
                },
                .content => {
                    std.debug.print("update case {s}: expected error, got content\n", .{name});
                    return error.TestUnexpectedResult;
                },
            }
            continue;
        }
        const expected = patchedExpectation(name) orelse result_json.get("content").?.string;
        switch (result) {
            .content => |content| {
                if (!std.mem.eql(u8, expected, content)) {
                    std.debug.print("update case {s}:\n  expected {s}\n  actual   {s}\n", .{ name, expected, content });
                    return error.TestUnexpectedResult;
                }
            },
            .err => |message| {
                std.debug.print("update case {s}: expected content, got error {s}\n", .{ name, message });
                return error.TestUnexpectedResult;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Ported behavior tests from core.test.ts

test "parseFile splits frontmatter (scalars + inline arrays) from body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse.parseFile(arena, "---\nid: foo\ntype: module-design\ntitle: Foo\ndepends-on: [a, b]\ntags: [x]\n---\n\n## Body\ntext\n");
    const fm = parsed.frontmatter.?;
    try std.testing.expectEqualStrings("foo", parse.scalar(fm, "id").?);
    try std.testing.expectEqualStrings("module-design", parse.scalar(fm, "type").?);
    try std.testing.expectEqualStrings("Foo", parse.scalar(fm, "title").?);
    var scratch: [1][]const u8 = undefined;
    const depends = parse.listField(fm, "depends-on", &scratch);
    try std.testing.expectEqual(@as(usize, 2), depends.len);
    try std.testing.expectEqualStrings("a", depends[0]);
    try std.testing.expectEqualStrings("b", depends[1]);
    try std.testing.expectEqualStrings("\n## Body\ntext\n", parsed.body);
}

test "parseFile reads block-style arrays, normalizing to a string list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse.parseFile(arena, "---\nid: m\ntype: module-design\ntitle: M\ndepends-on:\n  - a\n  - b\n---\nbody\n");
    var scratch: [1][]const u8 = undefined;
    const depends = parse.listField(parsed.frontmatter.?, "depends-on", &scratch);
    try std.testing.expectEqual(@as(usize, 2), depends.len);
    try std.testing.expectEqualStrings("a", depends[0]);
    try std.testing.expectEqualStrings("b", depends[1]);
}

test "parseFile returns null frontmatter for malformed YAML instead of throwing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse.parseFile(arena, "---\nid: m\n  bad: : indent\n\t- x\n---\nbody\n");
    try std.testing.expect(parsed.frontmatter == null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "body") != null);
}

test "parseFile returns null frontmatter without a leading fence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse.parseFile(arena, "# Just prose\nno fence");
    try std.testing.expect(parsed.frontmatter == null);
    try std.testing.expectEqualStrings("# Just prose\nno fence", parsed.body);
}

test "isSpec requires id and type" {
    const with_both = parse.Frontmatter{ .entries = &.{
        .{ .key = "id", .value = .{ .scalar = "a" } },
        .{ .key = "type", .value = .{ .scalar = "t" } },
    } };
    const only_id = parse.Frontmatter{ .entries = &.{.{ .key = "id", .value = .{ .scalar = "a" } }} };
    const only_type = parse.Frontmatter{ .entries = &.{.{ .key = "type", .value = .{ .scalar = "t" } }} };
    try std.testing.expect(parse.isSpec(with_both));
    try std.testing.expect(!parse.isSpec(only_id));
    try std.testing.expect(!parse.isSpec(only_type));
    try std.testing.expect(!parse.isSpec(null));
}

test "serializeFrontmatter emits in given key order, arrays inline, empties dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fm = parse.Frontmatter{ .entries = &.{
        .{ .key = "id", .value = .{ .scalar = "foo" } },
        .{ .key = "type", .value = .{ .scalar = "module-design" } },
        .{ .key = "title", .value = .{ .scalar = "T" } },
        .{ .key = "depends-on", .value = .{ .list = &.{} } },
        .{ .key = "covers", .value = .{ .list = &.{"c"} } },
        .{ .key = "tags", .value = .{ .list = &.{ "x", "y" } } },
    } };
    const out = try parse.serializeFrontmatter(arena, fm);
    try std.testing.expectEqualStrings("---\nid: foo\ntype: module-design\ntitle: T\ncovers: [c]\ntags: [x, y]\n---\n", out);
}

test "serialize and parse round-trip including a list item with a comma" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fm = parse.Frontmatter{ .entries = &.{
        .{ .key = "id", .value = .{ .scalar = "x" } },
        .{ .key = "type", .value = .{ .scalar = "t" } },
        .{ .key = "title", .value = .{ .scalar = "T" } },
        .{ .key = "tags", .value = .{ .list = &.{ "hello, world", "b" } } },
    } };
    const text = try std.fmt.allocPrint(arena, "{s}\nbody", .{try parse.serializeFrontmatter(arena, fm)});
    const reparsed = try parse.parseFile(arena, text);
    var scratch: [1][]const u8 = undefined;
    const tags = parse.listField(reparsed.frontmatter.?, "tags", &scratch);
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("hello, world", tags[0]);
    try std.testing.expectEqualStrings("b", tags[1]);
}

test "parseFile strips trailing CR of CRLF frontmatter lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse.parseFile(arena, "---\r\nid: my-spec\r\ntype: module-design\r\ntitle: T\r\n---\r\nbody\r\n");
    try std.testing.expectEqualStrings("my-spec", parse.scalar(parsed.frontmatter.?, "id").?);
    const flow = try parse.parseFile(arena, "---\r\nid: my-spec\r\ntype: module-design\r\ntags: [a, b]\r\n---\r\nbody\r\n");
    var scratch: [1][]const u8 = undefined;
    const tags = parse.listField(flow.frontmatter.?, "tags", &scratch);
    try std.testing.expectEqual(@as(usize, 2), tags.len);
}

test "update preserves comments and nested non-dialect fields through an edit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = "---\nid: a # the slug\ntype: module-design\n# a standalone note\nowner:\n  name: bob\n  team: infra\ntags: [x, y]\n---\nprose body\n";
    const edit = parse.FrontmatterEdit{
        .add_list = &.{.{ .key = "tags", .value = .{ .list = &.{"z"} } }},
        .set = &.{.{ .key = "status", .value = .{ .scalar = "active" } }},
    };
    const result = try parse.updateFrontmatterText(arena, file, edit);
    const content = switch (result) {
        .content => |text| text,
        .err => |message| {
            std.debug.print("unexpected error: {s}\n", .{message});
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expect(std.mem.indexOf(u8, content, "owner:") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "name: bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "# the slug") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "# a standalone note") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "tags: [x, y, z]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "status: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "prose body") != null);
    const reparsed = try parse.parseFile(arena, content);
    try std.testing.expectEqualStrings("a", parse.scalar(reparsed.frontmatter.?, "id").?);
}

test "update writes CRLF files back with CRLF endings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = "---\r\nid: a\r\ntype: module-design\r\ntitle: T\r\n---\r\nbody line\r\n";
    const result = try parse.updateFrontmatterText(arena, file, .{ .set = &.{.{ .key = "title", .value = .{ .scalar = "T2" } }} });
    const content = switch (result) {
        .content => |text| text,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.indexOf(u8, content, "title: T2") != null);
    var index: usize = 0;
    while (index < content.len) : (index += 1) {
        if (content[index] == '\n') {
            if (index == 0 or content[index - 1] != '\r') return error.TestUnexpectedResult;
        }
    }
}

test "update leaves the prose body byte-identical, mixed line endings included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "# Body\nplain line\r\nanother\n";
    const file = try std.fmt.allocPrint(arena, "---\nid: a\ntype: module-design\ntitle: T\n---\n{s}", .{body});
    const result = try parse.updateFrontmatterText(arena, file, .{ .set = &.{.{ .key = "title", .value = .{ .scalar = "T2" } }} });
    const content = switch (result) {
        .content => |text| text,
        .err => return error.TestUnexpectedResult,
    };
    const expected = try std.fmt.allocPrint(arena, "---\nid: a\ntype: module-design\ntitle: T2\n---\n{s}", .{body});
    try std.testing.expectEqualStrings(expected, content);
}

test "update reads the line ending from the frontmatter, not from any body line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = "---\nid: a\ntype: module-design\ntitle: T\n---\nprose\r\n";
    const result = try parse.updateFrontmatterText(arena, file, .{ .set = &.{.{ .key = "title", .value = .{ .scalar = "T2" } }} });
    const content = switch (result) {
        .content => |text| text,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, content, "---\nid: a\n"));
    try std.testing.expect(std.mem.endsWith(u8, content, "prose\r\n"));
}

test "update keeps a leading BOM" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = "\xef\xbb\xbf---\nid: a\ntype: module-design\ntitle: T\n---\nbody\n";
    const result = try parse.updateFrontmatterText(arena, file, .{ .set = &.{.{ .key = "title", .value = .{ .scalar = "T2" } }} });
    const content = switch (result) {
        .content => |text| text,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, content, "\xef\xbb\xbf"));
    const reparsed = try parse.parseFile(arena, content);
    try std.testing.expectEqualStrings("T2", parse.scalar(reparsed.frontmatter.?, "title").?);
}

test "update refuses unspec-ing edits with the captured messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = "---\nid: a\ntype: module-design\ntitle: T\n---\nbody\n";
    {
        const result = try parse.updateFrontmatterText(arena, file, .{ .set = &.{.{ .key = "tags", .value = .{ .scalar = "a, b" } }} });
        switch (result) {
            .err => |message| try std.testing.expectEqualStrings("Use addList/removeList to edit the list field \"tags\".", message),
            .content => return error.TestUnexpectedResult,
        }
    }
    {
        const result = try parse.updateFrontmatterText(arena, file, .{ .set = &.{.{ .key = "id", .value = .{ .scalar = "b" } }} });
        try std.testing.expectEqualStrings("Cannot rename a spec's id via set.", result.err);
    }
    {
        const result = try parse.updateFrontmatterText(arena, file, .{ .set = &.{.{ .key = "type", .value = .{ .scalar = "" } }} });
        try std.testing.expectEqualStrings("Update would leave the file without a valid id and type.", result.err);
    }
    {
        const result = try parse.updateFrontmatterText(arena, file, .{ .remove = &.{"id"} });
        try std.testing.expectEqualStrings("Cannot remove protected field \"id\".", result.err);
    }
    {
        const result = try parse.updateFrontmatterText(arena, "# no fence\n", .{ .set = &.{.{ .key = "status", .value = .{ .scalar = "active" } }} });
        try std.testing.expectEqualStrings("File has no frontmatter to update.", result.err);
    }
    {
        const result = try parse.updateFrontmatterText(arena, "---\nid: [unclosed\n---\n", .{ .set = &.{.{ .key = "status", .value = .{ .scalar = "active" } }} });
        try std.testing.expectEqualStrings("File frontmatter is not valid YAML.", result.err);
    }
}
