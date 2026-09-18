const std = @import("std");
const graph_mod = @import("graph.zig");
const parse = @import("parse.zig");

const Kind = graph_mod.Kind;
const SpecGraph = graph_mod.SpecGraph;

pub const DanglingLink = struct {
    from: []const u8,
    from_path: []const u8,
    kind: Kind,
    target: []const u8,
};

pub const DuplicateId = struct {
    id: []const u8,
    paths: []const []const u8,
};

pub const ParentCycle = struct {
    ids: []const []const u8,
};

pub const ValidationReport = struct {
    dangling_links: []const DanglingLink = &.{},
    duplicate_ids: []const DuplicateId = &.{},
    parent_cycles: []const ParentCycle = &.{},
};

fn sortedCycleKey(allocator: std.mem.Allocator, ids: []const []const u8) error{OutOfMemory}![]const u8 {
    const copy = try allocator.dupe([]const u8, ids);
    std.mem.sort([]const u8, copy, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return std.mem.join(allocator, "\x00", copy);
}

fn findParentCycles(allocator: std.mem.Allocator, graph: SpecGraph) error{OutOfMemory}![]const ParentCycle {
    var cycles = std.ArrayListUnmanaged(ParentCycle).empty;
    var cycle_keys = std.ArrayListUnmanaged([]const u8).empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    var node_iterator = graph.nodes.iterator();
    while (node_iterator.next()) |kv| {
        const start_id = kv.key_ptr.*;
        if (seen.contains(start_id)) continue;
        var path = std.ArrayListUnmanaged([]const u8).empty;
        var on_path: std.StringArrayHashMapUnmanaged(usize) = .empty;
        var current: ?[]const u8 = start_id;

        while (current) |current_id| {
            if (!graph.nodes.contains(current_id)) break;
            if (on_path.get(current_id)) |first_index| {
                const ring = path.items[first_index..];
                const key = try sortedCycleKey(allocator, ring);
                var duplicate = false;
                for (cycle_keys.items) |existing| {
                    if (std.mem.eql(u8, existing, key)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    try cycle_keys.append(allocator, key);
                    try cycles.append(allocator, .{ .ids = try allocator.dupe([]const u8, ring) });
                }
                break;
            }
            if (seen.contains(current_id)) break;
            try on_path.put(allocator, current_id, path.items.len);
            try path.append(allocator, current_id);
            const node = graph.nodes.get(current_id) orelse break;
            current = parse.scalar(node.frontmatter, parse.PARENT);
        }
        for (path.items) |id| {
            if (!seen.contains(id)) try seen.put(allocator, id, {});
        }
    }
    return cycles.items;
}

pub fn validateGraph(allocator: std.mem.Allocator, graph: SpecGraph) error{OutOfMemory}!ValidationReport {
    var dangling = std.ArrayListUnmanaged(DanglingLink).empty;
    var node_iterator = graph.nodes.iterator();
    while (node_iterator.next()) |kv| {
        const node = kv.value_ptr.*;
        inline for (std.meta.tags(Kind)) |kind| {
            var scratch: [1][]const u8 = undefined;
            for (graph_mod.linkTargets(node.frontmatter, kind, &scratch)) |target| {
                if (!graph.nodes.contains(target)) {
                    try dangling.append(allocator, .{
                        .from = node.id,
                        .from_path = node.path,
                        .kind = kind,
                        .target = target,
                    });
                }
            }
        }
    }

    var duplicates = std.ArrayListUnmanaged(DuplicateId).empty;
    var duplicate_iterator = graph.duplicate_ids.iterator();
    while (duplicate_iterator.next()) |kv| {
        try duplicates.append(allocator, .{ .id = kv.key_ptr.*, .paths = kv.value_ptr.items });
    }

    return .{
        .dangling_links = dangling.items,
        .duplicate_ids = duplicates.items,
        .parent_cycles = try findParentCycles(allocator, graph),
    };
}

pub fn isValid(report: ValidationReport) bool {
    return report.dangling_links.len == 0 and report.duplicate_ids.len == 0 and report.parent_cycles.len == 0;
}
