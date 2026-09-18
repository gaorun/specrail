const std = @import("std");

pub const ID = "id";
pub const TYPE = "type";
pub const STATUS = "status";
pub const TITLE = "title";
pub const PARENT = "parent";
pub const DEPENDS_ON = "depends-on";
pub const REFERENCES = "references";
pub const IMPLEMENTS = "implements";
pub const COVERS = "covers";
pub const TAGS = "tags";

pub const IDENTITY_FIELDS = [_][]const u8{ ID, TYPE };
pub const REQUIRED_FIELDS = [_][]const u8{ ID, TYPE, TITLE };
pub const SINGLE_LINK_FIELDS = [_][]const u8{PARENT};
pub const LIST_LINK_FIELDS = [_][]const u8{ DEPENDS_ON, REFERENCES, IMPLEMENTS };
pub const LIST_FIELDS = [_][]const u8{ DEPENDS_ON, REFERENCES, IMPLEMENTS, COVERS, TAGS };
pub const FIELD_ORDER = [_][]const u8{ ID, TYPE, STATUS, TITLE, PARENT, DEPENDS_ON, REFERENCES, IMPLEMENTS, COVERS, TAGS };
pub const SPEC_TYPES = [_][]const u8{
    "goal-and-requirements",
    "architecture-design",
    "module-design",
    "submodule-design",
    "task-spec",
};
pub const SPEC_STATUSES = [_][]const u8{ "draft", "active", "stale", "done", "deprecated" };

pub const Value = union(enum) {
    scalar: []const u8,
    list: []const []const u8,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Frontmatter = struct {
    entries: []const Entry = &.{},

    pub fn get(self: Frontmatter, key: []const u8) ?Value {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

pub fn isListField(key: []const u8) bool {
    for (LIST_FIELDS) |field| {
        if (std.mem.eql(u8, field, key)) return true;
    }
    return false;
}

pub fn isIdentityField(key: []const u8) bool {
    for (IDENTITY_FIELDS) |field| {
        if (std.mem.eql(u8, field, key)) return true;
    }
    return false;
}

pub fn scalar(fm: Frontmatter, key: []const u8) ?[]const u8 {
    const value = fm.get(key) orelse return null;
    return switch (value) {
        .scalar => |text| if (text.len > 0) text else null,
        else => null,
    };
}

/// The caller provides a one-element scratch buffer for scalar values, mirroring
/// the JS list() that promotes a scalar to a single-item list.
pub fn listField(fm: Frontmatter, key: []const u8, scratch: *[1][]const u8) []const []const u8 {
    const value = fm.get(key) orelse return &.{};
    switch (value) {
        .list => |items| return items,
        .scalar => |text| {
            if (text.len == 0) return &.{};
            scratch[0] = text;
            return scratch;
        },
    }
}

pub fn isSpec(fm: ?Frontmatter) bool {
    const frontmatter = fm orelse return false;
    inline for (IDENTITY_FIELDS) |field| {
        if (scalar(frontmatter, field) == null) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Splitting

pub const ParsedFile = struct {
    frontmatter: ?Frontmatter,
    body: []const u8,
};

const FENCE = "---";
const BOM = "\xef\xbb\xbf";

const Split = struct {
    /// Line-ending-joined frontmatter text, or null when there is no fenced block.
    fm_text: ?[]const u8,
    body: []const u8,
};

fn splitLines(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}!std.ArrayListUnmanaged([]const u8) {
    var lines = std.ArrayListUnmanaged([]const u8).empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);
    return lines;
}

fn splitFrontmatter(allocator: std.mem.Allocator, content: []const u8) error{OutOfMemory}!Split {
    const normalized = if (std.mem.startsWith(u8, content, BOM)) content[BOM.len..] else content;
    var lines = try splitLines(allocator, normalized);
    if (lines.items.len == 0) return .{ .fm_text = null, .body = content };
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.items[0], " \t\r"), FENCE)) {
        return .{ .fm_text = null, .body = content };
    }
    var end: ?usize = null;
    for (lines.items[1..], 1..) |line, index| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), FENCE)) {
            end = index;
            break;
        }
    }
    const closing = end orelse return .{ .fm_text = null, .body = content };
    var fm_lines = std.ArrayListUnmanaged([]const u8).empty;
    for (lines.items[1..closing]) |line| {
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try fm_lines.append(allocator, trimmed);
    }
    const body = try std.mem.join(allocator, "\n", lines.items[closing + 1 ..]);
    return .{ .fm_text = try std.mem.join(allocator, "\n", fm_lines.items), .body = body };
}

// ---------------------------------------------------------------------------
// Subset YAML parsing (frontmatter dialect)

pub const ParseError = error{ InvalidFrontmatter, OutOfMemory };

const RawEntry = struct {
    key: []const u8,
    /// null value means the entry exists in the document but its value is a
    /// nested map (or otherwise non-scalar), which the read model drops.
    value: ?Value,
    line_start: usize,
    line_end: usize,
    /// Raw " # ..." suffix on the entry's value line, kept for edits.
    inline_comment: ?[]const u8 = null,
};

const RawDoc = struct {
    entries: []RawEntry,
};

fn parseRawDoc(allocator: std.mem.Allocator, fm_text: []const u8) ParseError!RawDoc {
    const lines = try splitLines(allocator, fm_text);

    var entries = std.ArrayListUnmanaged(RawEntry).empty;
    var index: usize = 0;
    while (index < lines.items.len) {
        const line = lines.items[index];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            index += 1;
            continue;
        }
        if (line[0] == ' ' or line[0] == '\t') return error.InvalidFrontmatter;

        const colon = findKeyColon(line) orelse return error.InvalidFrontmatter;
        const key = std.mem.trim(u8, line[0..colon], " ");
        if (key.len == 0) return error.InvalidFrontmatter;
        for (entries.items) |existing| {
            if (std.mem.eql(u8, existing.key, key)) return error.InvalidFrontmatter;
        }
        var rest = line[colon + 1 ..];
        if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return error.InvalidFrontmatter;
        rest = std.mem.trim(u8, rest, " ");

        var inline_comment: ?[]const u8 = null;
        const value_part = stripInlineComment(rest);
        if (value_part.len != rest.len) {
            inline_comment = rest[value_part.len..];
            rest = value_part;
        }

        if (rest.len == 0) {
            const block = collectIndented(lines.items, index + 1);
            if (block.line_count == 0) {
                index += 1;
                continue; // null value: dropped, matching toFrontmatter
            }
            const first = std.mem.trim(u8, lines.items[block.first_line], " ");
            if (std.mem.startsWith(u8, first, "- ") or std.mem.eql(u8, first, "-")) {
                var items = std.ArrayListUnmanaged([]const u8).empty;
                var line_index = block.first_line;
                while (line_index <= block.last_line) : (line_index += 1) {
                    const item_line = std.mem.trim(u8, lines.items[line_index], " ");
                    if (item_line.len == 0 or item_line[0] == '#') continue;
                    if (item_line[0] != '-') return error.InvalidFrontmatter;
                    var item_text = std.mem.trim(u8, item_line[1..], " ");
                    item_text = stripInlineComment(item_text);
                    if (item_text.len == 0) continue;
                    const item_value = try parseScalarText(allocator, item_text);
                    if (item_value) |value| try items.append(allocator, value);
                }
                try entries.append(allocator, .{
                    .key = key,
                    .value = .{ .list = items.items },
                    .line_start = index,
                    .line_end = block.last_line,
                });
                index = block.last_line + 1;
                continue;
            }
            try entries.append(allocator, .{
                .key = key,
                .value = null, // nested block: kept in the document, dropped from the read model
                .line_start = index,
                .line_end = block.last_line,
            });
            index = block.last_line + 1;
            continue;
        }

        if (rest[0] == '[') {
            const items = try parseFlowList(allocator, rest);
            try entries.append(allocator, .{
                .key = key,
                .value = .{ .list = items },
                .line_start = index,
                .line_end = index,
                .inline_comment = inline_comment,
            });
            index += 1;
            continue;
        }

        if (rest[0] == '|' or rest[0] == '>') {
            const folded = rest[0] == '>';
            const chomp: u8 = if (rest.len > 1) rest[1] else 0;
            const block = collectIndented(lines.items, index + 1);
            var text: []const u8 = "";
            if (block.line_count > 0) {
                var block_text = std.ArrayListUnmanaged(u8).empty;
                const indent = countIndent(lines.items[block.first_line]);
                var line_index = block.first_line;
                while (line_index <= block.last_line) : (line_index += 1) {
                    const raw_line = lines.items[line_index];
                    const content_start = @min(indent, raw_line.len);
                    if (line_index > block.first_line) {
                        if (folded) {
                            try block_text.append(allocator, ' ');
                        } else {
                            try block_text.append(allocator, '\n');
                        }
                    }
                    try block_text.appendSlice(allocator, raw_line[content_start..]);
                }
                if (chomp != '-') try block_text.append(allocator, '\n');
                text = block_text.items;
            }
            try entries.append(allocator, .{
                .key = key,
                .value = .{ .scalar = text },
                .line_start = index,
                .line_end = if (block.line_count > 0) block.last_line else index,
                .inline_comment = inline_comment,
            });
            index = if (block.line_count > 0) block.last_line + 1 else index + 1;
            continue;
        }

        const value = try parseScalarText(allocator, rest);
        if (value != null) {
            try entries.append(allocator, .{
                .key = key,
                .value = .{ .scalar = value.? },
                .line_start = index,
                .line_end = index,
                .inline_comment = inline_comment,
            });
        }
        index += 1;
    }
    return .{ .entries = entries.items };
}

fn countIndent(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

/// Finds the colon that terminates a mapping key: must be followed by a space,
/// tab, or end of line, and must not sit inside a quoted scalar.
fn findKeyColon(line: []const u8) ?usize {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const c = line[index];
        if (c == '"' or c == '\'') {
            const quote = c;
            index += 1;
            while (index < line.len) : (index += 1) {
                if (line[index] == quote) {
                    if (quote == '\'' and index + 1 < line.len and line[index + 1] == '\'') {
                        index += 1;
                        continue;
                    }
                    break;
                }
            }
            continue;
        }
        if (c == ':') {
            if (index + 1 == line.len) return index;
            if (line[index + 1] == ' ' or line[index + 1] == '\t') return index;
        }
    }
    return null;
}

fn stripInlineComment(text: []const u8) []const u8 {
    if (text.len > 0 and text[0] == '#') return text[0..0];
    var index: usize = 0;
    var in_quote: u8 = 0;
    while (index < text.len) : (index += 1) {
        const c = text[index];
        if (in_quote != 0) {
            if (c == in_quote) {
                if (in_quote == '\'' and index + 1 < text.len and text[index + 1] == '\'') {
                    index += 1;
                    continue;
                }
                in_quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            in_quote = c;
            continue;
        }
        if (c == '#' and index > 0 and (text[index - 1] == ' ' or text[index - 1] == '\t')) {
            return std.mem.trimEnd(u8, text[0..index], " \t");
        }
    }
    return std.mem.trimEnd(u8, text, " \t");
}

const Block = struct {
    first_line: usize,
    last_line: usize,
    line_count: usize,
};

/// Collects the indented block following a bare `key:` line. Blank lines are
/// allowed inside the block; the block ends at the first non-indented line.
fn collectIndented(lines: []const []const u8, start: usize) Block {
    var last: ?usize = null;
    var count: usize = 0;
    var index = start;
    while (index < lines.len) : (index += 1) {
        const line = lines[index];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') break;
        last = index;
        count += 1;
    }
    if (last) |last_index| {
        return .{ .first_line = start, .last_line = last_index, .line_count = count };
    }
    return .{ .first_line = start, .last_line = start, .line_count = 0 };
}

/// Parses one scalar token. null means the token is a null value and its entry
/// is dropped; an empty string is kept (it is a real, if empty, scalar).
fn parseScalarText(allocator: std.mem.Allocator, text: []const u8) ParseError!?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '"') return try parseDoubleQuoted(allocator, trimmed);
    if (trimmed[0] == '\'') return try parseSingleQuoted(allocator, trimmed);
    if (std.mem.indexOf(u8, trimmed, ": ") != null) return error.InvalidFrontmatter;
    if (trimmed[trimmed.len - 1] == ':') return null; // nested mapping in scalar position
    return coercePlain(trimmed);
}

fn parseDoubleQuoted(allocator: std.mem.Allocator, text: []const u8) ParseError![]const u8 {
    if (text.len < 2) return error.InvalidFrontmatter;
    var out = std.ArrayListUnmanaged(u8).empty;
    var index: usize = 1;
    while (index < text.len) : (index += 1) {
        const c = text[index];
        if (c == '"') {
            const rest = std.mem.trim(u8, text[index + 1 ..], " \t");
            if (rest.len != 0) return error.InvalidFrontmatter;
            return out.items;
        }
        if (c == '\\') {
            index += 1;
            if (index >= text.len) return error.InvalidFrontmatter;
            const escaped = text[index];
            const mapped: ?u8 = switch (escaped) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                'a' => 7,
                'b' => 8,
                'f' => 12,
                'v' => 11,
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'e' => 27,
                else => null,
            };
            if (mapped) |byte| {
                try out.append(allocator, byte);
                continue;
            }
            if (escaped == 'u') {
                if (index + 4 >= text.len) return error.InvalidFrontmatter;
                const code = std.fmt.parseInt(u21, text[index + 1 .. index + 5], 16) catch return error.InvalidFrontmatter;
                index += 4;
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(code, &buffer) catch return error.InvalidFrontmatter;
                try out.appendSlice(allocator, buffer[0..length]);
                continue;
            }
            return error.InvalidFrontmatter;
        }
        try out.append(allocator, c);
    }
    return error.InvalidFrontmatter;
}

fn parseSingleQuoted(allocator: std.mem.Allocator, text: []const u8) ParseError![]const u8 {
    if (text.len < 2) return error.InvalidFrontmatter;
    var out = std.ArrayListUnmanaged(u8).empty;
    var index: usize = 1;
    while (index < text.len) : (index += 1) {
        const c = text[index];
        if (c == '\'') {
            if (index + 1 < text.len and text[index + 1] == '\'') {
                try out.append(allocator, '\'');
                index += 1;
                continue;
            }
            const rest = std.mem.trim(u8, text[index + 1 ..], " \t");
            if (rest.len != 0) return error.InvalidFrontmatter;
            return out.items;
        }
        try out.append(allocator, c);
    }
    return error.InvalidFrontmatter;
}

/// YAML 1.2 core-schema coercions, rendered the way JS String(value) would.
fn coercePlain(text: []const u8) ?[]const u8 {
    if (isNullWord(text)) return null;
    if (std.mem.eql(u8, text, "~")) return null;
    if (std.ascii.eqlIgnoreCase(text, "true")) return "true";
    if (std.ascii.eqlIgnoreCase(text, "false")) return "false";
    if (std.ascii.eqlIgnoreCase(text, ".inf") or std.mem.eql(u8, text, "+.inf")) return "Infinity";
    if (std.mem.eql(u8, text, "-.inf") or std.mem.eql(u8, text, "-.Inf") or std.mem.eql(u8, text, "-.INF")) return "-Infinity";
    if (std.ascii.eqlIgnoreCase(text, ".nan")) return "NaN";
    return text;
}

fn isNullWord(text: []const u8) bool {
    return std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "Null") or std.mem.eql(u8, text, "NULL");
}

fn parseFlowList(allocator: std.mem.Allocator, text: []const u8) ParseError![]const []const u8 {
    const inner_full = std.mem.trim(u8, text, " \t");
    if (inner_full.len < 2 or inner_full[0] != '[') return error.InvalidFrontmatter;
    if (inner_full[inner_full.len - 1] != ']') return error.InvalidFrontmatter;
    const inner = std.mem.trim(u8, inner_full[1 .. inner_full.len - 1], " \t");
    var items = std.ArrayListUnmanaged([]const u8).empty;
    if (inner.len == 0) return items.items;

    var depth: usize = 0;
    var in_quote: u8 = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= inner.len) : (index += 1) {
        const at_end = index == inner.len;
        const c: u8 = if (at_end) ',' else inner[index];
        if (!at_end) {
            if (in_quote != 0) {
                if (c == in_quote) in_quote = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                in_quote = c;
                continue;
            }
            if (c == '[' or c == '{') depth += 1;
            if (c == ']' or c == '}') {
                if (depth == 0) return error.InvalidFrontmatter;
                depth -= 1;
            }
        }
        if (c == ',' and depth == 0) {
            const item_text = std.mem.trim(u8, inner[start..index], " \t");
            if (item_text.len > 0) {
                if (item_text[0] == '[') {
                    const nested = try parseFlowList(allocator, item_text);
                    try items.append(allocator, try std.mem.join(allocator, ",", nested));
                } else {
                    const value = try parseScalarText(allocator, item_text);
                    if (value) |item| try items.append(allocator, item);
                }
            }
            start = index + 1;
        }
    }
    if (in_quote != 0) return error.InvalidFrontmatter;
    if (depth != 0) return error.InvalidFrontmatter;
    return items.items;
}

fn toFrontmatter(allocator: std.mem.Allocator, doc: RawDoc) error{OutOfMemory}!Frontmatter {
    var entries = std.ArrayListUnmanaged(Entry).empty;
    for (doc.entries) |raw| {
        const value = raw.value orelse continue; // nested blocks are dropped
        try entries.append(allocator, .{ .key = raw.key, .value = value });
    }
    return .{ .entries = entries.items };
}

pub fn parseFile(allocator: std.mem.Allocator, content: []const u8) error{OutOfMemory}!ParsedFile {
    const split = try splitFrontmatter(allocator, content);
    const fm_text = split.fm_text orelse return .{ .frontmatter = null, .body = split.body };
    const trimmed = std.mem.trim(u8, fm_text, " \t\n\r");
    if (trimmed.len == 0 or isNullWord(trimmed) or std.mem.eql(u8, trimmed, "~")) {
        return .{ .frontmatter = .{ .entries = &.{} }, .body = split.body };
    }
    const doc = parseRawDoc(allocator, fm_text) catch {
        return .{ .frontmatter = null, .body = content };
    };
    const frontmatter = try toFrontmatter(allocator, doc);
    return .{ .frontmatter = frontmatter, .body = split.body };
}

// ---------------------------------------------------------------------------
// Emission

fn isPlainSafeScalar(value: []const u8) bool {
    if (value.len == 0) return false;
    const first = value[0];
    switch (first) {
        '#', ',', '[', ']', '{', '}', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => return false,
        '?' => if (value.len == 1 or value[1] == ' ') return false,
        '-' => if (value.len == 1 or value[1] == ' ') return false,
        ':' => if (value.len == 1 or value[1] == ' ') return false,
        else => {},
    }
    if (value[0] == ' ' or value[value.len - 1] == ' ') return false;
    if (std.mem.indexOf(u8, value, ": ") != null) return false;
    if (std.mem.indexOf(u8, value, " #") != null) return false;
    if (looksNumeric(value)) return false;
    if (looksSpecialWord(value)) return false;
    return true;
}

fn looksSpecialWord(value: []const u8) bool {
    const words = [_][]const u8{ "true", "false", "null", "~" };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return true;
    }
    return false;
}

fn looksNumeric(value: []const u8) bool {
    var index: usize = 0;
    if (index < value.len and (value[index] == '-' or value[index] == '+')) index += 1;
    if (index >= value.len) return false;
    const rest = value[index..];
    if (rest.len > 1 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X')) return allDigits(rest[2..], 16);
    if (rest.len > 1 and rest[0] == '0' and (rest[1] == 'b' or rest[1] == 'B')) return allDigits(rest[2..], 2);
    if (rest.len > 1 and rest[0] == '0' and (rest[1] == 'o' or rest[1] == 'O')) return allDigits(rest[2..], 8);
    var digits: usize = 0;
    var dots: usize = 0;
    for (rest, 0..) |c, position| {
        if (c >= '0' and c <= '9') {
            digits += 1;
            continue;
        }
        if (c == '.') {
            dots += 1;
            if (dots > 1) return false;
            continue;
        }
        if (c == 'e' or c == 'E') {
            if (digits == 0) return false;
            const exponent = rest[position + 1 ..];
            var exp_index: usize = 0;
            if (exp_index < exponent.len and (exponent[exp_index] == '-' or exponent[exp_index] == '+')) exp_index += 1;
            if (exp_index >= exponent.len) return false;
            return allDigits(exponent[exp_index..], 10);
        }
        return false;
    }
    return digits > 0;
}

fn allDigits(text: []const u8, base: u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        const valid = switch (base) {
            2 => c == '0' or c == '1',
            8 => c >= '0' and c <= '7',
            16 => std.ascii.isHex(c),
            else => c >= '0' and c <= '9',
        };
        if (!valid) return false;
    }
    return true;
}

pub fn appendScalarText(writer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) error{OutOfMemory}!void {
    if (isPlainSafeScalar(value)) {
        try writer.appendSlice(allocator, value);
        return;
    }
    try writer.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.appendSlice(allocator, "\\\""),
            '\\' => try writer.appendSlice(allocator, "\\\\"),
            '\n' => try writer.appendSlice(allocator, "\\n"),
            '\t' => try writer.appendSlice(allocator, "\\t"),
            '\r' => try writer.appendSlice(allocator, "\\r"),
            else => try writer.append(allocator, c),
        }
    }
    try writer.append(allocator, '"');
}

fn appendFlowItem(writer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) error{OutOfMemory}!void {
    if (std.mem.indexOfScalar(u8, value, ',') != null) {
        try writer.append(allocator, '"');
        for (value) |c| {
            switch (c) {
                '"' => try writer.appendSlice(allocator, "\\\""),
                '\\' => try writer.appendSlice(allocator, "\\\\"),
                else => try writer.append(allocator, c),
            }
        }
        try writer.append(allocator, '"');
        return;
    }
    try appendScalarText(writer, allocator, value);
}

pub fn formatValue(allocator: std.mem.Allocator, value: Value) error{OutOfMemory}![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    switch (value) {
        .scalar => |text| {
            if (std.mem.indexOfScalar(u8, text, '\n') != null) {
                // Block literal; the TS yaml lib renders a quirky plain form, we
                // emit the canonical equivalent instead (documented deviation).
                try out.appendSlice(allocator, "|-\n");
                var iterator = std.mem.splitScalar(u8, text, '\n');
                var first = true;
                while (iterator.next()) |line| {
                    if (!first) try out.append(allocator, '\n');
                    try out.appendSlice(allocator, "  ");
                    try out.appendSlice(allocator, line);
                    first = false;
                }
            } else {
                try appendScalarText(&out, allocator, text);
            }
        },
        .list => |items| {
            try out.append(allocator, '[');
            for (items, 0..) |item, index| {
                if (index > 0) try out.appendSlice(allocator, ", ");
                try appendFlowItem(&out, allocator, item);
            }
            try out.append(allocator, ']');
        },
    }
    return out.items;
}

pub fn serializeFrontmatter(allocator: std.mem.Allocator, fm: Frontmatter) error{OutOfMemory}![]const u8 {
    var result = std.ArrayListUnmanaged(u8).empty;
    try result.appendSlice(allocator, FENCE);
    try result.append(allocator, '\n');
    for (fm.entries) |entry| {
        switch (entry.value) {
            .scalar => |text| {
                if (text.len == 0) continue;
            },
            .list => |items| {
                if (items.len == 0) continue;
            },
        }
        try result.appendSlice(allocator, entry.key);
        try result.appendSlice(allocator, ": ");
        try result.appendSlice(allocator, try formatValue(allocator, entry.value));
        try result.append(allocator, '\n');
    }
    try result.appendSlice(allocator, FENCE);
    try result.append(allocator, '\n');
    return result.items;
}

// ---------------------------------------------------------------------------
// Frontmatter editing (line-preserving)

pub const FrontmatterEdit = struct {
    set: []const Entry = &.{},
    remove: []const []const u8 = &.{},
    add_list: []const Entry = &.{},
    remove_list: []const Entry = &.{},
};

pub const EditResult = union(enum) {
    content: []const u8,
    err: []const u8,
};

const ERR_NO_FRONTMATTER = "File has no frontmatter to update.";
const ERR_INVALID_YAML = "File frontmatter is not valid YAML.";
const ERR_RENAME_ID = "Cannot rename a spec's id via set.";
const ERR_USE_LIST_EDIT = "Use addList/removeList to edit the list field ";
const ERR_PROTECTED = "Cannot remove protected field ";
const ERR_WOULD_UNSPEC = "Update would leave the file without a valid id and type.";

fn lineEndingOf(text: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, text, '\n') orelse return "\n";
    if (first > 0 and text[first - 1] == '\r') return "\r\n";
    return "\n";
}

const WorkEntry = struct {
    key: []const u8,
    original_value: ?Value,
    line_start: usize,
    line_end: usize,
    inline_comment: ?[]const u8,
    /// Final value: null means deleted; undefined-in-Zig = untouched.
    edited: bool = false,
    deleted: bool = false,
    value: ?Value = null,
};

fn findByKey(work: *std.ArrayListUnmanaged(WorkEntry), key: []const u8) ?*WorkEntry {
    for (work.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry;
    }
    return null;
}

fn currentList(entry: *WorkEntry, scratch: *[1][]const u8) []const []const u8 {
    const value = entry.value orelse entry.original_value orelse return &.{};
    switch (value) {
        .list => |items| return items,
        .scalar => |text| {
            if (text.len == 0) return &.{};
            scratch[0] = text;
            return scratch;
        },
    }
}

pub fn updateFrontmatterText(allocator: std.mem.Allocator, file_text: []const u8, edit: FrontmatterEdit) error{OutOfMemory}!EditResult {
    const has_bom = std.mem.startsWith(u8, file_text, BOM);
    const split = try splitFrontmatter(allocator, file_text);
    const fm_text = split.fm_text orelse return .{ .err = ERR_NO_FRONTMATTER };
    if (std.mem.trim(u8, fm_text, " \t\r\n").len == 0) return .{ .err = ERR_INVALID_YAML };

    const doc = parseRawDoc(allocator, fm_text) catch return .{ .err = ERR_INVALID_YAML };

    const lines = try splitLines(allocator, fm_text);

    var work = std.ArrayListUnmanaged(WorkEntry).empty;
    for (doc.entries) |raw| {
        try work.append(allocator, .{
            .key = raw.key,
            .original_value = raw.value,
            .line_start = raw.line_start,
            .line_end = raw.line_end,
            .inline_comment = raw.inline_comment,
        });
    }

    // Same operation order as the TS implementation: set, remove, addList, removeList.
    for (edit.set) |set_entry| {
        if (std.mem.eql(u8, set_entry.key, ID)) return .{ .err = ERR_RENAME_ID };
        if (isListField(set_entry.key)) {
            return .{ .err = try std.fmt.allocPrint(allocator, "{s}\"{s}\".", .{ ERR_USE_LIST_EDIT, set_entry.key }) };
        }
        if (findByKey(&work, set_entry.key)) |entry| {
            entry.edited = true;
            entry.value = set_entry.value;
        } else {
            try work.append(allocator, .{
                .key = set_entry.key,
                .original_value = null,
                .line_start = lines.items.len,
                .line_end = lines.items.len,
                .inline_comment = null,
                .edited = true,
                .value = set_entry.value,
            });
        }
    }

    for (edit.remove) |key| {
        if (isIdentityField(key)) {
            return .{ .err = try std.fmt.allocPrint(allocator, "{s}\"{s}\".", .{ ERR_PROTECTED, key }) };
        }
        if (findByKey(&work, key)) |entry| entry.deleted = true;
    }

    for (edit.add_list) |list_entry| {
        const added = switch (list_entry.value) {
            .list => |items| items,
            .scalar => &.{},
        };
        if (findByKey(&work, list_entry.key)) |entry| {
            var scratch: [1][]const u8 = undefined;
            const current: []const []const u8 = if (entry.deleted) &.{} else currentList(entry, &scratch);
            var merged = std.ArrayListUnmanaged([]const u8).empty;
            for (current) |item| try merged.append(allocator, item);
            for (added) |item| {
                var present = false;
                for (merged.items) |already| {
                    if (std.mem.eql(u8, already, item)) {
                        present = true;
                        break;
                    }
                }
                if (!present) try merged.append(allocator, item);
            }
            if (entry.deleted) {
                // Re-adding a previously removed key appends it at the end,
                // like doc.set on a missing key.
                entry.line_start = lines.items.len;
                entry.line_end = lines.items.len;
            }
            entry.deleted = false;
            entry.edited = true;
            entry.value = .{ .list = merged.items };
        } else if (added.len > 0) {
            try work.append(allocator, .{
                .key = list_entry.key,
                .original_value = null,
                .line_start = lines.items.len,
                .line_end = lines.items.len,
                .inline_comment = null,
                .edited = true,
                .value = .{ .list = added },
            });
        }
    }

    for (edit.remove_list) |list_entry| {
        const removed = switch (list_entry.value) {
            .list => |items| items,
            .scalar => &.{},
        };
        const entry = findByKey(&work, list_entry.key) orelse continue;
        var scratch: [1][]const u8 = undefined;
        const current: []const []const u8 = if (entry.deleted) &.{} else currentList(entry, &scratch);
        var kept = std.ArrayListUnmanaged([]const u8).empty;
        for (current) |item| {
            var remove_it = false;
            for (removed) |candidate| {
                if (std.mem.eql(u8, candidate, item)) {
                    remove_it = true;
                    break;
                }
            }
            if (!remove_it) try kept.append(allocator, item);
        }
        if (kept.items.len == 0) {
            entry.deleted = true;
            entry.edited = true;
        } else {
            entry.deleted = false;
            entry.edited = true;
            entry.value = .{ .list = kept.items };
        }
    }

    // Validate the edited document still carries id + type.
    var has_id = false;
    var has_type = false;
    for (work.items) |entry| {
        if (entry.deleted) continue;
        const value = if (entry.edited) entry.value else entry.original_value;
        const text = switch (value orelse continue) {
            .scalar => |scalar_text| scalar_text,
            else => continue,
        };
        if (text.len == 0) continue;
        if (std.mem.eql(u8, entry.key, ID)) has_id = true;
        if (std.mem.eql(u8, entry.key, TYPE)) has_type = true;
    }
    if (!has_id or !has_type) return .{ .err = ERR_WOULD_UNSPEC };

    // Rebuild the frontmatter line by line.
    var result_lines = std.ArrayListUnmanaged([]const u8).empty;
    var line_index: usize = 0;
    while (line_index < lines.items.len) {
        var entry_at_line: ?*WorkEntry = null;
        for (work.items) |*entry| {
            if (entry.line_start == line_index and entry.line_end < lines.items.len) {
                entry_at_line = entry;
                break;
            }
        }
        if (entry_at_line) |entry| {
            if (!entry.deleted) {
                if (entry.edited) {
                    const value: Value = entry.value orelse Value{ .scalar = "" };
                    var text = std.ArrayListUnmanaged(u8).empty;
                    try text.appendSlice(allocator, entry.key);
                    try text.appendSlice(allocator, ": ");
                    try text.appendSlice(allocator, try formatValue(allocator, value));
                    if (entry.inline_comment) |comment| try text.appendSlice(allocator, comment);
                    var text_lines = std.mem.splitScalar(u8, text.items, '\n');
                    while (text_lines.next()) |text_line| try result_lines.append(allocator, text_line);
                } else {
                    var index = entry.line_start;
                    while (index <= entry.line_end) : (index += 1) {
                        try result_lines.append(allocator, lines.items[index]);
                    }
                }
            }
            line_index = entry.line_end + 1;
            continue;
        }
        try result_lines.append(allocator, lines.items[line_index]);
        line_index += 1;
    }
    // Appended entries (line_start == lines.len) in work order.
    for (work.items) |entry| {
        if (entry.line_start != lines.items.len) continue;
        if (entry.deleted or !entry.edited) continue;
        const value: Value = entry.value orelse Value{ .scalar = "" };
        var text = std.ArrayListUnmanaged(u8).empty;
        try text.appendSlice(allocator, entry.key);
        try text.appendSlice(allocator, ": ");
        try text.appendSlice(allocator, try formatValue(allocator, value));
        if (entry.inline_comment) |comment| try text.appendSlice(allocator, comment);
        try result_lines.append(allocator, text.items);
    }

    const line_ending = lineEndingOf(file_text);
    var block = std.ArrayListUnmanaged(u8).empty;
    if (has_bom) try block.appendSlice(allocator, BOM);
    try block.appendSlice(allocator, FENCE);
    try block.appendSlice(allocator, line_ending);
    for (result_lines.items, 0..) |line, index| {
        if (index > 0) try block.appendSlice(allocator, line_ending);
        try block.appendSlice(allocator, line);
    }
    try block.appendSlice(allocator, line_ending);
    try block.appendSlice(allocator, FENCE);
    try block.appendSlice(allocator, line_ending);
    try block.appendSlice(allocator, split.body);

    return .{ .content = block.items };
}
