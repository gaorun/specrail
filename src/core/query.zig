const std = @import("std");
const graph_mod = @import("graph.zig");
const parse = @import("parse.zig");
const regex = @import("regex.zig");

const SpecGraph = graph_mod.SpecGraph;
const Kind = graph_mod.Kind;

pub const SpecContentEntry = struct {
    path: []const u8,
    content: []const u8,
    frontmatter: parse.Frontmatter,
};

pub const SpecFilters = struct {
    node_type: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    depends_on: ?[]const u8 = null,
};

pub const GrepOptions = struct {
    pattern: []const u8,
    regex: bool = false,
    ignore_case: bool = true,
    limit: ?f64 = null,
    filters: SpecFilters = .{},
};

pub const GrepMatch = struct {
    path: []const u8,
    line: usize,
    snippet: []const u8,
};

pub const GrepResult = struct {
    matches: []const GrepMatch,
    truncated: bool,
};

pub const DEFAULT_GREP_LIMIT: usize = 200;

pub const GrepError = error{ InvalidPattern, OutOfMemory };

fn effectiveLimit(limit: ?f64) usize {
    const requested = limit orelse @as(f64, @floatFromInt(DEFAULT_GREP_LIMIT));
    const truncated = @trunc(requested);
    if (truncated > 0) {
        const max: f64 = @floatFromInt(std.math.maxInt(usize) / 2);
        return @intFromFloat(@min(truncated, max));
    }
    return DEFAULT_GREP_LIMIT;
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var matched = true;
        for (needle, 0..) |byte, offset| {
            const actual = haystack[index + offset];
            if (actual == byte) continue;
            if (std.ascii.isAlphabetic(actual) and swapCaseByte(actual) == byte) continue;
            matched = false;
            break;
        }
        if (matched) return true;
    }
    return false;
}

fn matchesFilters(fm: parse.Frontmatter, filters: SpecFilters) bool {
    if (filters.node_type) |wanted| {
        const actual = parse.scalar(fm, parse.TYPE) orelse return false;
        if (!std.mem.eql(u8, actual, wanted)) return false;
    }
    if (filters.parent) |wanted| {
        const actual = parse.scalar(fm, parse.PARENT) orelse return false;
        if (!std.mem.eql(u8, actual, wanted)) return false;
    }
    var scratch: [1][]const u8 = undefined;
    if (filters.tag) |wanted| {
        var found = false;
        for (parse.listField(fm, parse.TAGS, &scratch)) |item| {
            if (std.mem.eql(u8, item, wanted)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    if (filters.depends_on) |wanted| {
        var found = false;
        for (parse.listField(fm, parse.DEPENDS_ON, &scratch)) |item| {
            if (std.mem.eql(u8, item, wanted)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub fn grepSpecs(
    allocator: std.mem.Allocator,
    entries: []const SpecContentEntry,
    options: GrepOptions,
) GrepError!GrepResult {
    const limit = effectiveLimit(options.limit);
    var compiled: ?regex.Regex = null;
    if (options.regex) {
        compiled = try regex.Regex.compile(allocator, options.pattern, options.ignore_case);
    }

    var matches = std.ArrayListUnmanaged(GrepMatch).empty;
    for (entries) |entry| {
        if (!matchesFilters(entry.frontmatter, options.filters)) continue;
        var line_iterator = std.mem.splitScalar(u8, entry.content, '\n');
        var line_number: usize = 0;
        while (line_iterator.next()) |raw_line| {
            line_number += 1;
            var line = raw_line;
            if (line_number == 1 and std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const matched = if (compiled) |active|
                try active.search(line)
            else if (options.ignore_case)
                containsIgnoreCaseAscii(line, options.pattern)
            else
                std.mem.indexOf(u8, line, options.pattern) != null;
            if (!matched) continue;
            if (matches.items.len >= limit) return .{ .matches = matches.items, .truncated = true };
            try matches.append(allocator, .{
                .path = entry.path,
                .line = line_number,
                .snippet = std.mem.trim(u8, line, " \t\r\n"),
            });
        }
    }
    return .{ .matches = matches.items, .truncated = false };
}

pub const SliceDirection = enum { subtree, ancestors, neighbors };

pub const SliceOptions = struct {
    root: []const u8,
    direction: SliceDirection,
    depth: ?f64 = null,
    edge: ?Kind = null,
};

pub const GraphSlice = struct {
    root: []const u8,
    direction: SliceDirection,
    nodes: []const *const graph_mod.SpecNode,
    edges: []const graph_mod.SpecEdge,
    missing: []const []const u8,
};

pub fn graphSlice(
    allocator: std.mem.Allocator,
    graph: *const SpecGraph,
    options: SliceOptions,
) error{OutOfMemory}!GraphSlice {
    const depth = options.depth orelse 1;
    var included: std.StringArrayHashMapUnmanaged(void) = .empty;
    try included.put(allocator, options.root, {});
    var edges = std.ArrayListUnmanaged(graph_mod.SpecEdge).empty;
    var seen_edges: std.StringArrayHashMapUnmanaged(void) = .empty;
    var missing: std.StringArrayHashMapUnmanaged(void) = .empty;

    var frontier = std.ArrayListUnmanaged([]const u8).empty;
    try frontier.append(allocator, options.root);

    var step: f64 = 0;
    while (step < depth) : (step += 1) {
        var next_frontier = std.ArrayListUnmanaged([]const u8).empty;
        for (frontier.items) |id| {
            try walkNode(allocator, graph, options, id, &edges, &seen_edges, &missing, &included, &next_frontier);
        }
        if (next_frontier.items.len == 0) break;
        frontier = next_frontier;
    }

    var nodes = std.ArrayListUnmanaged(*const graph_mod.SpecNode).empty;
    var included_iterator = included.iterator();
    while (included_iterator.next()) |kv| {
        const pointer = graph.nodes.getPtr(kv.key_ptr.*) orelse continue;
        try nodes.append(allocator, pointer);
    }

    return .{
        .root = options.root,
        .direction = options.direction,
        .nodes = nodes.items,
        .edges = edges.items,
        .missing = missing.keys(),
    };
}

fn walkNode(
    allocator: std.mem.Allocator,
    graph: *const SpecGraph,
    options: SliceOptions,
    id: []const u8,
    edges: *std.ArrayListUnmanaged(graph_mod.SpecEdge),
    seen_edges: *std.StringArrayHashMapUnmanaged(void),
    missing: *std.StringArrayHashMapUnmanaged(void),
    included: *std.StringArrayHashMapUnmanaged(void),
    next_frontier: *std.ArrayListUnmanaged([]const u8),
) error{OutOfMemory}!void {
    const Step = struct {
        target: []const u8,
        edge: graph_mod.SpecEdge,
    };
    var steps = std.ArrayListUnmanaged(Step).empty;
    switch (options.direction) {
        .subtree => {
            const kind: Kind = .parent;
            if (graph.reverse[@intFromEnum(kind)].get(id)) |children| {
                for (children.items) |child| {
                    try steps.append(allocator, .{ .target = child, .edge = .{ .from = child, .to = id, .kind = kind } });
                }
            }
        },
        .ancestors => {
            const kind: Kind = .parent;
            if (graph.forward[@intFromEnum(kind)].get(id)) |parents| {
                for (parents.items) |parent| {
                    try steps.append(allocator, .{ .target = parent, .edge = .{ .from = id, .to = parent, .kind = kind } });
                }
            }
        },
        .neighbors => {
            const kind: Kind = options.edge orelse .depends_on;
            if (graph.forward[@intFromEnum(kind)].get(id)) |targets| {
                for (targets.items) |to| {
                    try steps.append(allocator, .{ .target = to, .edge = .{ .from = id, .to = to, .kind = kind } });
                }
            }
            if (graph.reverse[@intFromEnum(kind)].get(id)) |sources| {
                for (sources.items) |from| {
                    try steps.append(allocator, .{ .target = from, .edge = .{ .from = from, .to = id, .kind = kind } });
                }
            }
        },
    }

    for (steps.items) |step| {
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}", .{ step.edge.from, step.edge.kind.name(), step.edge.to });
        if (!seen_edges.contains(key)) {
            try seen_edges.put(allocator, key, {});
            try edges.append(allocator, step.edge);
        }
        if (!graph.nodes.contains(step.target)) {
            if (!missing.contains(step.target)) try missing.put(allocator, step.target, {});
        }
        if (!included.contains(step.target)) {
            try included.put(allocator, step.target, {});
            try next_frontier.append(allocator, step.target);
        }
    }
}

fn swapCaseByte(byte: u8) u8 {
    if (std.ascii.isLower(byte)) return std.ascii.toUpper(byte);
    if (std.ascii.isUpper(byte)) return std.ascii.toLower(byte);
    return byte;
}
