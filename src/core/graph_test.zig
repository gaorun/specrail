const std = @import("std");
const graph_mod = @import("graph.zig");
const parse = @import("parse.zig");
const query = @import("query.zig");
const validate = @import("validate.zig");

fn fm(entries: []const parse.Entry) parse.Frontmatter {
    return .{ .entries = entries };
}

fn scalarEntry(key: []const u8, value: []const u8) parse.Entry {
    return .{ .key = key, .value = .{ .scalar = value } };
}

fn listEntry(key: []const u8, items: []const []const u8) parse.Entry {
    return .{ .key = key, .value = .{ .list = items } };
}

const test_entries = [_]graph_mod.SpecFileEntry{
    .{ .path = "root/SPEC.md", .frontmatter = fm(&.{ scalarEntry("id", "root"), scalarEntry("type", "architecture-design"), scalarEntry("title", "Root") }) },
    .{ .path = "a/SPEC.md", .frontmatter = fm(&.{
        scalarEntry("id", "a"),
        scalarEntry("type", "module-design"),
        scalarEntry("title", "A"),
        scalarEntry("parent", "root"),
        listEntry("depends-on", &.{"b"}),
    }) },
    .{ .path = "b/SPEC.md", .frontmatter = fm(&.{ scalarEntry("id", "b"), scalarEntry("type", "module-design"), scalarEntry("title", "B"), scalarEntry("parent", "root") }) },
};

test "buildGraph derives forward and reverse edges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const graph = try graph_mod.buildGraph(arena, &test_entries);
    try std.testing.expectEqual(@as(usize, 3), graph.nodes.count());
    const node_ids = graph.nodes.keys();
    try std.testing.expectEqual(@as(usize, 3), node_ids.len);

    const forward = graph.forward[@intFromEnum(graph_mod.Kind.depends_on)].get("a").?;
    try std.testing.expectEqual(@as(usize, 1), forward.items.len);
    try std.testing.expectEqualStrings("b", forward.items[0]);

    const reverse = graph.reverse[@intFromEnum(graph_mod.Kind.depends_on)].get("b").?;
    try std.testing.expectEqualStrings("a", reverse.items[0]);

    const children = graph.reverse[@intFromEnum(graph_mod.Kind.parent)].get("root").?;
    try std.testing.expectEqual(@as(usize, 2), children.items.len);
}

test "buildGraph tracks duplicate ids with first file winning the node" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]graph_mod.SpecFileEntry{
        .{ .path = "one.md", .frontmatter = fm(&.{ scalarEntry("id", "dup"), scalarEntry("type", "t") }) },
        .{ .path = "two.md", .frontmatter = fm(&.{ scalarEntry("id", "dup"), scalarEntry("type", "t") }) },
    };
    const graph = try graph_mod.buildGraph(arena, &entries);
    try std.testing.expectEqualStrings("one.md", graph.nodes.get("dup").?.path);
    const paths = graph.duplicate_ids.get("dup").?;
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("one.md", paths.items[0]);
    try std.testing.expectEqualStrings("two.md", paths.items[1]);
}

fn sortedIds(allocator: std.mem.Allocator, slice: query.GraphSlice) ![]const []const u8 {
    var ids = try allocator.alloc([]const u8, slice.nodes.len);
    for (slice.nodes, 0..) |node, index| ids[index] = node.id;
    std.mem.sort([]const u8, ids, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return ids;
}

test "graphSlice walks subtree, ancestors and neighbors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const graph = try graph_mod.buildGraph(arena, &test_entries);

    const subtree = try query.graphSlice(arena, &graph, .{ .root = "root", .direction = .subtree, .depth = 1 });
    const subtree_ids = try sortedIds(arena, subtree);
    try std.testing.expectEqual(@as(usize, 3), subtree_ids.len);
    try std.testing.expectEqualStrings("a", subtree_ids[0]);
    try std.testing.expectEqualStrings("b", subtree_ids[1]);
    try std.testing.expectEqualStrings("root", subtree_ids[2]);

    const ancestors = try query.graphSlice(arena, &graph, .{ .root = "a", .direction = .ancestors, .depth = 5 });
    const ancestor_ids = try sortedIds(arena, ancestors);
    try std.testing.expectEqual(@as(usize, 2), ancestor_ids.len);
    try std.testing.expectEqualStrings("a", ancestor_ids[0]);
    try std.testing.expectEqualStrings("root", ancestor_ids[1]);

    const neighbors_a = try query.graphSlice(arena, &graph, .{ .root = "a", .direction = .neighbors, .edge = .depends_on });
    const a_ids = try sortedIds(arena, neighbors_a);
    try std.testing.expectEqual(@as(usize, 2), a_ids.len);

    const neighbors_b = try query.graphSlice(arena, &graph, .{ .root = "b", .direction = .neighbors, .edge = .depends_on });
    const b_ids = try sortedIds(arena, neighbors_b);
    try std.testing.expectEqual(@as(usize, 2), b_ids.len);
}

test "graphSlice neighbors records each edge once across depth" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]graph_mod.SpecFileEntry{
        .{ .path = "a.md", .frontmatter = fm(&.{ scalarEntry("id", "a"), scalarEntry("type", "t"), listEntry("depends-on", &.{"b"}) }) },
        .{ .path = "b.md", .frontmatter = fm(&.{ scalarEntry("id", "b"), scalarEntry("type", "t"), listEntry("depends-on", &.{"c"}) }) },
        .{ .path = "c.md", .frontmatter = fm(&.{ scalarEntry("id", "c"), scalarEntry("type", "t") }) },
    };
    const graph = try graph_mod.buildGraph(arena, &entries);
    const slice = try query.graphSlice(arena, &graph, .{ .root = "a", .direction = .neighbors, .edge = .depends_on, .depth = 2 });
    try std.testing.expectEqual(@as(usize, 2), slice.edges.len);
    try std.testing.expectEqualStrings("a", slice.edges[0].from);
    try std.testing.expectEqualStrings("b", slice.edges[1].from);
}

test "validateGraph flags dangling links, duplicate ids, and parent cycles" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]graph_mod.SpecFileEntry{
        .{ .path = "a.md", .frontmatter = fm(&.{ scalarEntry("id", "a"), scalarEntry("type", "t"), scalarEntry("parent", "b"), listEntry("depends-on", &.{"ghost"}) }) },
        .{ .path = "b.md", .frontmatter = fm(&.{ scalarEntry("id", "b"), scalarEntry("type", "t"), scalarEntry("parent", "a") }) },
        .{ .path = "c1.md", .frontmatter = fm(&.{ scalarEntry("id", "c"), scalarEntry("type", "t") }) },
        .{ .path = "c2.md", .frontmatter = fm(&.{ scalarEntry("id", "c"), scalarEntry("type", "t") }) },
    };
    const graph = try graph_mod.buildGraph(arena, &entries);
    const report = try validate.validateGraph(arena, graph);

    var found_dangling = false;
    for (report.dangling_links) |link| {
        if (std.mem.eql(u8, link.from, "a") and std.mem.eql(u8, link.target, "ghost") and link.kind == .depends_on and std.mem.eql(u8, link.from_path, "a.md")) {
            found_dangling = true;
        }
    }
    try std.testing.expect(found_dangling);

    var found_duplicate = false;
    for (report.duplicate_ids) |duplicate| {
        if (std.mem.eql(u8, duplicate.id, "c") and duplicate.paths.len == 2) found_duplicate = true;
    }
    try std.testing.expect(found_duplicate);

    try std.testing.expectEqual(@as(usize, 1), report.parent_cycles.len);
    try std.testing.expectEqual(@as(usize, 2), report.parent_cycles[0].ids.len);
    try std.testing.expect(!validate.isValid(report));
}

