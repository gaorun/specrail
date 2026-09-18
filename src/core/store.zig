const std = @import("std");
const builtin = @import("builtin");
const graph_mod = @import("graph.zig");
const parse = @import("parse.zig");
const query = @import("query.zig");

const IGNORED_DIRS = [_][]const u8{ "node_modules", ".git", "dist", "build" };

pub const SPEC_FILE_EXTENSION = ".md";

/// Documented deviation: folding is ASCII lowercase only (no Unicode NFC).
fn foldEquals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn isIgnoredName(name: []const u8) bool {
    for (IGNORED_DIRS) |ignored| {
        if (foldEquals(name, ignored)) return true;
    }
    return false;
}

fn isIgnoredDirExact(name: []const u8) bool {
    for (IGNORED_DIRS) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

pub fn hasWindowsNamespaceSyntax(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, ':') != null) return true;
    if (path.len > 0 and path[0] == '\\') return true;
    return false;
}

fn relativePath(allocator: std.mem.Allocator, from: []const u8, to: []const u8) error{OutOfMemory}![]const u8 {
    var from_parts = std.ArrayListUnmanaged([]const u8).empty;
    var to_parts = std.ArrayListUnmanaged([]const u8).empty;
    var from_iterator = std.mem.tokenizeScalar(u8, from, '/');
    while (from_iterator.next()) |part| try from_parts.append(allocator, part);
    var to_iterator = std.mem.tokenizeScalar(u8, to, '/');
    while (to_iterator.next()) |part| try to_parts.append(allocator, part);

    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len and
        std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) : (common += 1)
    {}

    var result = std.ArrayListUnmanaged(u8).empty;
    var up: usize = common;
    while (up < from_parts.items.len) : (up += 1) {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, "..");
    }
    var down: usize = common;
    while (down < to_parts.items.len) : (down += 1) {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, to_parts.items[down]);
    }
    return result.items;
}

pub fn isPathInsideRoot(allocator: std.mem.Allocator, root: []const u8, target: []const u8) error{OutOfMemory}!bool {
    const rel = try relativePath(allocator, root, target);
    if (std.mem.eql(u8, rel, "..")) return false;
    if (std.mem.startsWith(u8, rel, "../")) return false;
    if (rel.len > 0 and rel[0] == '/') return false;
    return true;
}

pub const SegmentResolution = union(enum) {
    name: []const u8,
    err: []const u8,
};

pub fn resolvePathSegment(
    allocator: std.mem.Allocator,
    entries: []const []const u8,
    segment: []const u8,
    exists: bool,
) error{OutOfMemory}!SegmentResolution {
    var name = segment;
    if (exists) {
        var exact = false;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry, segment)) {
                exact = true;
                break;
            }
        }
        if (!exact) {
            var matches = std.ArrayListUnmanaged([]const u8).empty;
            for (entries) |entry| {
                if (foldEquals(entry, segment)) try matches.append(allocator, entry);
            }
            if (matches.items.len == 0) {
                return .{ .err = try std.fmt.allocPrint(
                    allocator,
                    "Path component \"{s}\" resolves to no entry its parent directory lists",
                    .{segment},
                ) };
            }
            if (matches.items.len > 1) {
                const rest = try std.mem.join(allocator, "\", \"", matches.items[1..]);
                return .{ .err = try std.fmt.allocPrint(
                    allocator,
                    "Path component \"{s}\" matches more than one entry on this filesystem (\"{s}\", \"{s}\")",
                    .{ segment, matches.items[0], rest },
                ) };
            }
            name = matches.items[0];
        }
    }
    if (isIgnoredName(name)) {
        return .{ .err = try std.fmt.allocPrint(
            allocator,
            "Path is inside an ignored directory (\"{s}\") and would not be indexed",
            .{name},
        ) };
    }
    return .{ .name = name };
}

pub const SpecPathResolution = union(enum) {
    resolved: struct { rel: []const u8, abs: []const u8 },
    err: []const u8,
};

fn lstatKind(io: std.Io, path: []const u8) ?std.Io.File.Kind {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return null;
    return stat.kind;
}

fn listDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        names.append(allocator, allocator.dupe(u8, entry.name) catch return null) catch return null;
    }
    return names.items;
}

pub fn resolveSpecPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    path: []const u8,
) error{OutOfMemory}!SpecPathResolution {
    if (std.mem.trim(u8, path, " \t\r\n").len == 0) {
        return .{ .err = "Path must not be empty." };
    }
    if (path[0] == '/') {
        return .{ .err = try std.fmt.allocPrint(allocator, "Path must be root-relative, not absolute: {s}", .{path}) };
    }
    if (builtin.os.tag == .windows and hasWindowsNamespaceSyntax(path)) {
        return .{ .err = try std.fmt.allocPrint(allocator, "Path must not use Windows drive or stream syntax: {s}", .{path}) };
    }
    if (!std.mem.endsWith(u8, path, SPEC_FILE_EXTENSION)) {
        return .{ .err = try std.fmt.allocPrint(allocator, "Spec files must end in {s}: {s}", .{ SPEC_FILE_EXTENSION, path }) };
    }

    // POSIX-style normalization of the relative path.
    var segments = std.ArrayListUnmanaged([]const u8).empty;
    var iterator = std.mem.tokenizeScalar(u8, path, '/');
    while (iterator.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0 and !std.mem.eql(u8, segments.items[segments.items.len - 1], "..")) {
                _ = segments.pop();
            } else {
                try segments.append(allocator, segment);
            }
            continue;
        }
        try segments.append(allocator, segment);
    }
    for (segments.items) |segment| {
        if (std.mem.eql(u8, segment, "..")) {
            return .{ .err = try std.fmt.allocPrint(allocator, "Path must stay inside the project root: {s}", .{path}) };
        }
    }
    if (lstatKind(io, root) == null) {
        return .{ .err = try std.fmt.allocPrint(allocator, "Project root does not exist: {s}", .{root}) };
    }

    var walked = try allocator.dupe(u8, root);
    var walked_exists = true;
    var canonical = std.ArrayListUnmanaged([]const u8).empty;
    for (segments.items) |segment| {
        var entries: []const []const u8 = &.{};
        if (walked_exists) {
            entries = listDirectory(allocator, io, walked) orelse {
                return .{ .err = try std.fmt.allocPrint(allocator, "Path passes through a directory the index cannot list: {s}", .{path}) };
            };
        }
        const joined = try std.fs.path.join(allocator, &.{ walked, segment });
        const exists = walked_exists and lstatKind(io, joined) != null;
        const resolution = try resolvePathSegment(allocator, entries, segment, exists);
        switch (resolution) {
            .err => |message| return .{ .err = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ message, path }) },
            .name => |name| {
                walked = try std.fs.path.join(allocator, &.{ walked, name });
                const kind = lstatKind(io, walked);
                if (kind != null and kind.? == .sym_link) {
                    return .{ .err = try std.fmt.allocPrint(allocator, "Path passes through a symlink, which the index never follows: {s}", .{path}) };
                }
                try canonical.append(allocator, name);
                walked_exists = exists;
            },
        }
    }

    const rel = try std.mem.join(allocator, "/", canonical.items);
    if (!std.mem.endsWith(u8, rel, SPEC_FILE_EXTENSION)) {
        return .{ .err = try std.fmt.allocPrint(allocator, "Spec files must end in {s}: {s}", .{ SPEC_FILE_EXTENSION, path }) };
    }
    if (!try isPathInsideRoot(allocator, root, walked)) {
        return .{ .err = try std.fmt.allocPrint(allocator, "Path must stay inside the project root: {s}", .{path}) };
    }
    return .{ .resolved = .{ .rel = rel, .abs = walked } };
}

pub const SpecFileRecord = struct {
    abs: []const u8,
    rel: []const u8,
    content: []const u8,
    frontmatter: parse.Frontmatter,
};

const CacheEntry = struct {
    rel: []const u8,
    mtime_ns: i96,
    size: u64,
    content: []const u8,
    frontmatter: ?parse.Frontmatter,
};

pub const SpecIndex = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    cache: std.StringArrayHashMapUnmanaged(CacheEntry) = .empty,
    graph_cache: ?graph_mod.SpecGraph = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) SpecIndex {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    pub fn absPath(self: *SpecIndex, rel: []const u8) error{OutOfMemory}![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, rel });
    }

    fn walkCollect(self: *SpecIndex, dir_path: []const u8, out: *std.ArrayListUnmanaged([]const u8)) error{OutOfMemory}!void {
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        const Candidate = struct { name: []const u8, directory: bool };
        var candidates = std.ArrayListUnmanaged(Candidate).empty;
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch null) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (!isIgnoredDirExact(entry.name)) {
                        try candidates.append(self.allocator, .{ .name = entry.name, .directory = true });
                    }
                },
                .file => {
                    if (std.mem.endsWith(u8, entry.name, SPEC_FILE_EXTENSION)) {
                        try candidates.append(self.allocator, .{ .name = entry.name, .directory = false });
                    }
                },
                else => {},
            }
        }
        std.mem.sort(Candidate, candidates.items, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        for (candidates.items) |candidate| {
            const abs = try std.fs.path.join(self.allocator, &.{ dir_path, candidate.name });
            if (candidate.directory) {
                try self.walkCollect(abs, out);
            } else {
                try out.append(self.allocator, abs);
            }
        }
    }

    fn toRel(self: *SpecIndex, abs: []const u8) []const u8 {
        var end: usize = abs.len;
        while (end > self.root.len and abs[end - 1] == '/') end -= 1;
        var start: usize = self.root.len;
        if (start < end and self.root.len > 0 and self.root[self.root.len - 1] == '/') start -= 1;
        if (start < end and abs[start] == '/') start += 1;
        return abs[start..end];
    }

    fn scan(self: *SpecIndex) error{OutOfMemory}![]const SpecFileRecord {
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        var specs = std.ArrayListUnmanaged(SpecFileRecord).empty;
        var changed = false;

        var paths = std.ArrayListUnmanaged([]const u8).empty;
        try self.walkCollect(self.root, &paths);

        for (paths.items) |abs| {
            if (!seen.contains(abs)) try seen.put(self.allocator, abs, {});
            const stat = std.Io.Dir.cwd().statFile(self.io, abs, .{}) catch continue;
            const existing = self.cache.getPtr(abs);
            const fresh = existing == null or existing.?.mtime_ns != stat.mtime.nanoseconds or existing.?.size != stat.size;
            var entry: *CacheEntry = undefined;
            if (fresh) {
                const content = std.Io.Dir.cwd().readFileAlloc(self.io, abs, self.allocator, .limited(1 << 28)) catch {
                    if (self.cache.swapRemove(abs)) changed = true;
                    continue;
                };
                const parsed = try parse.parseFile(self.allocator, content);
                const record = CacheEntry{
                    .rel = self.toRel(abs),
                    .mtime_ns = stat.mtime.nanoseconds,
                    .size = stat.size,
                    .content = if (parse.isSpec(parsed.frontmatter)) content else "",
                    .frontmatter = parsed.frontmatter,
                };
                try self.cache.put(self.allocator, abs, record);
                entry = self.cache.getPtr(abs).?;
                changed = true;
            } else {
                entry = existing.?;
            }
            if (entry.frontmatter) |frontmatter| {
                if (parse.isSpec(frontmatter)) {
                    try specs.append(self.allocator, .{
                        .abs = abs,
                        .rel = entry.rel,
                        .content = entry.content,
                        .frontmatter = frontmatter,
                    });
                }
            }
        }

        var cache_keys = std.ArrayListUnmanaged([]const u8).empty;
        var cache_iterator = self.cache.iterator();
        while (cache_iterator.next()) |kv| try cache_keys.append(self.allocator, kv.key_ptr.*);
        for (cache_keys.items) |abs| {
            if (!seen.contains(abs)) {
                _ = self.cache.swapRemove(abs);
                changed = true;
            }
        }

        if (changed) self.graph_cache = null;
        return specs.items;
    }

    pub fn graph(self: *SpecIndex) error{OutOfMemory}!*const graph_mod.SpecGraph {
        const specs = try self.scan();
        if (self.graph_cache == null) {
            var entries = std.ArrayListUnmanaged(graph_mod.SpecFileEntry).empty;
            for (specs) |record| {
                try entries.append(self.allocator, .{ .path = record.rel, .frontmatter = record.frontmatter });
            }
            self.graph_cache = try graph_mod.buildGraph(self.allocator, entries.items);
        }
        return &self.graph_cache.?;
    }

    pub fn contentEntries(self: *SpecIndex) error{OutOfMemory}![]const query.SpecContentEntry {
        const specs = try self.scan();
        var entries = std.ArrayListUnmanaged(query.SpecContentEntry).empty;
        for (specs) |record| {
            try entries.append(self.allocator, .{
                .path = record.rel,
                .content = record.content,
                .frontmatter = record.frontmatter,
            });
        }
        return entries.items;
    }

    pub fn recordForId(self: *SpecIndex, id: []const u8) error{OutOfMemory}!?SpecFileRecord {
        const specs = try self.scan();
        for (specs) |record| {
            const record_id = parse.scalar(record.frontmatter, parse.ID) orelse continue;
            if (std.mem.eql(u8, record_id, id)) return record;
        }
        return null;
    }

    pub fn pathForId(self: *SpecIndex, id: []const u8) error{OutOfMemory}!?[]const u8 {
        const record = try self.recordForId(id) orelse return null;
        return record.rel;
    }
};
