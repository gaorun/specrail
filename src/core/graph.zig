const std = @import("std");
const parse = @import("parse.zig");

pub const LINK_KINDS = [_][]const u8{ parse.PARENT, parse.DEPENDS_ON, parse.REFERENCES, parse.IMPLEMENTS };

pub const Kind = enum {
    parent,
    depends_on,
    references,
    implements,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .parent => parse.PARENT,
            .depends_on => parse.DEPENDS_ON,
            .references => parse.REFERENCES,
            .implements => parse.IMPLEMENTS,
        };
    }

    pub fn fromName(text: []const u8) ?Kind {
        for (LINK_KINDS, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, text)) return @enumFromInt(index);
        }
        return null;
    }
};

pub const SpecNode = struct {
    id: []const u8,
    type: []const u8,
    title: ?[]const u8,
    path: []const u8,
    frontmatter: parse.Frontmatter,
};

pub const SpecEdge = struct {
    from: []const u8,
    to: []const u8,
    kind: Kind,
};

pub const SpecFileEntry = struct {
    path: []const u8,
    frontmatter: parse.Frontmatter,
};

pub const Adjacency = [LINK_KINDS.len]std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8));

pub const SpecGraph = struct {
    nodes: std.StringArrayHashMapUnmanaged(SpecNode) = .empty,
    edges: []const SpecEdge = &.{},
    forward: Adjacency = .{ .empty, .empty, .empty, .empty },
    reverse: Adjacency = .{ .empty, .empty, .empty, .empty },
    duplicate_ids: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,
};

/// Single-valued link fields promote to a one-element list; the caller
/// provides the scratch element.
pub fn linkTargets(fm: parse.Frontmatter, kind: Kind, scratch: *[1][]const u8) []const []const u8 {
    if (kind == .parent) {
        const target = parse.scalar(fm, parse.PARENT) orelse return &.{};
        scratch[0] = target;
        return scratch;
    }
    return parse.listField(fm, kind.name(), scratch);
}

fn pushEdge(
    map: *std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) error{OutOfMemory}!void {
    const entry = try map.getOrPut(allocator, key);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    try entry.value_ptr.append(allocator, value);
}

pub fn buildGraph(allocator: std.mem.Allocator, entries: []const SpecFileEntry) error{OutOfMemory}!SpecGraph {
    var graph: SpecGraph = .{};
    var paths_by_id: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;

    for (entries) |entry| {
        const id = parse.scalar(entry.frontmatter, parse.ID) orelse continue;
        const node_type = parse.scalar(entry.frontmatter, parse.TYPE) orelse continue;
        try pushEdge(&paths_by_id, allocator, id, entry.path);
        if (!graph.nodes.contains(id)) {
            try graph.nodes.put(allocator, id, .{
                .id = id,
                .type = node_type,
                .title = parse.scalar(entry.frontmatter, parse.TITLE),
                .path = entry.path,
                .frontmatter = entry.frontmatter,
            });
        }
    }

    var edges = std.ArrayListUnmanaged(SpecEdge).empty;
    var node_iterator = graph.nodes.iterator();
    while (node_iterator.next()) |kv| {
        const node = kv.value_ptr.*;
        inline for (std.meta.tags(Kind)) |kind| {
            var scratch: [1][]const u8 = undefined;
            for (linkTargets(node.frontmatter, kind, &scratch)) |target| {
                try edges.append(allocator, .{ .from = node.id, .to = target, .kind = kind });
                try pushEdge(&graph.forward[@intFromEnum(kind)], allocator, node.id, target);
                try pushEdge(&graph.reverse[@intFromEnum(kind)], allocator, target, node.id);
            }
        }
    }
    graph.edges = edges.items;

    var duplicates_iterator = paths_by_id.iterator();
    while (duplicates_iterator.next()) |kv| {
        if (kv.value_ptr.items.len > 1) {
            try graph.duplicate_ids.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
        }
    }

    return graph;
}
