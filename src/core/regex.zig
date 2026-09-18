const std = @import("std");

/// A deliberately small regex subset: literals, `.`, classes (`[...]`,
/// negation, ranges, `\d \D \w \W \s \S`), escapes, groups, alternation,
/// the quantifiers `* + ? {n} {n,} {n,m}` (a trailing lazy `?` is accepted
/// but has no effect on a boolean search) and the `^` / `$` anchors.
///
/// Not supported (documented deviation from JS RegExp): lookaround,
/// backreferences, `\b`, unicode property escapes, flags beyond `i`,
/// and matching is byte-oriented.
pub const Error = error{ InvalidPattern, OutOfMemory };

pub const Regex = struct {
    allocator: std.mem.Allocator,
    program: []const Inst,
    ignore_case: bool,
    match_pc: u32,

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, ignore_case: bool) Error!Regex {
        var parser = Parser{
            .allocator = allocator,
            .pattern = pattern,
            .position = 0,
        };
        const root = try parser.parseAlternation();
        if (parser.position != pattern.len) return error.InvalidPattern; // stray ')'
        var program: std.ArrayListUnmanaged(Inst) = .empty;
        try emitNode(allocator, &program, root);
        const match_pc: u32 = @intCast(program.items.len);
        try program.append(allocator, .match);
        return .{
            .allocator = allocator,
            .program = program.items,
            .ignore_case = ignore_case,
            .match_pc = match_pc,
        };
    }

    pub fn search(self: Regex, text: []const u8) Error!bool {
        var clist = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.program.len);
        defer clist.deinit(self.allocator);
        var nlist = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.program.len);
        defer nlist.deinit(self.allocator);

        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            clist.setRangeValue(.{ .start = 0, .end = self.program.len }, false);
            try self.addThread(&clist, 0, start, text.len);
            var position = start;
            while (true) {
                if (clist.isSet(self.match_pc)) return true;
                if (position >= text.len) break;
                nlist.setRangeValue(.{ .start = 0, .end = self.program.len }, false);
                var iterator = clist.iterator(.{});
                while (iterator.next()) |pc| {
                    switch (self.program[pc]) {
                        .byte => |byte| {
                            if (byteMatches(text[position], byte, self.ignore_case)) {
                                try self.addThread(&nlist, @intCast(pc + 1), position + 1, text.len);
                            }
                        },
                        .any => {
                            const c = text[position];
                            if (c != '\n' and c != '\r') {
                                try self.addThread(&nlist, @intCast(pc + 1), position + 1, text.len);
                            }
                        },
                        .class => |class| {
                            if (class.matches(text[position], self.ignore_case)) {
                                try self.addThread(&nlist, @intCast(pc + 1), position + 1, text.len);
                            }
                        },
                        else => {},
                    }
                }
                const swap = clist;
                clist = nlist;
                nlist = swap;
                position += 1;
            }
        }
        return false;
    }

    fn addThread(self: Regex, list: *std.DynamicBitSetUnmanaged, start_pc: u32, position: usize, text_len: usize) Error!void {
        var stack = std.ArrayListUnmanaged(u32).empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, start_pc);
        while (stack.pop()) |pc| {
            if (list.isSet(pc)) continue;
            list.set(pc);
            if (pc == self.match_pc) continue;
            switch (self.program[pc]) {
                .jump => |target| try stack.append(self.allocator, target),
                .split => |arms| {
                    try stack.append(self.allocator, arms[0]);
                    try stack.append(self.allocator, arms[1]);
                },
                .anchor_start => {
                    if (position == 0) try stack.append(self.allocator, pc + 1);
                },
                .anchor_end => {
                    if (position == text_len) try stack.append(self.allocator, pc + 1);
                },
                else => {},
            }
        }
    }
};

fn byteMatches(actual: u8, expected: u8, ignore_case: bool) bool {
    if (actual == expected) return true;
    if (!ignore_case) return false;
    return std.ascii.isAlphabetic(actual) and swapCaseByte(actual) == expected;
}

const Inst = union(enum) {
    byte: u8,
    any,
    class: ClassSet,
    anchor_start,
    anchor_end,
    split: [2]u32,
    jump: u32,
    match,
};

const ClassSet = struct {
    bits: [32]u8 = [_]u8{0} ** 32,
    negate: bool = false,

    fn add(self: *ClassSet, byte: u8) void {
        self.bits[byte >> 3] |= @as(u8, 1) << @intCast(byte & 7);
    }

    fn addRange(self: *ClassSet, low: u8, high: u8) void {
        var byte: usize = low;
        while (byte <= high) : (byte += 1) self.add(@intCast(byte));
    }

    fn contains(self: ClassSet, byte: u8) bool {
        return (self.bits[byte >> 3] >> @intCast(byte & 7)) & 1 == 1;
    }

    fn matches(self: ClassSet, byte: u8, ignore_case: bool) bool {
        var member = self.contains(byte);
        if (!member and ignore_case and std.ascii.isAlphabetic(byte)) {
            member = self.contains(swapCaseByte(byte));
        }
        return member != self.negate;
    }
};

fn digitClass() ClassSet {
    var class = ClassSet{};
    class.addRange('0', '9');
    return class;
}

fn wordClass() ClassSet {
    var class = ClassSet{};
    class.addRange('0', '9');
    class.addRange('A', 'Z');
    class.addRange('a', 'z');
    class.add('_');
    return class;
}

fn spaceClass() ClassSet {
    var class = ClassSet{};
    for ([_]u8{ ' ', '\t', '\n', '\r', 11, 12 }) |byte| class.add(byte);
    return class;
}

fn inverted(class: ClassSet) ClassSet {
    var result = class;
    result.negate = !result.negate;
    return result;
}

const Node = union(enum) {
    empty,
    literal: u8,
    any,
    class: ClassSet,
    anchor_start,
    anchor_end,
    concat: []const *const Node,
    alt: []const *const Node,
    repeat: Repeat,
};

const Repeat = struct {
    child: *const Node,
    min: u32,
    max: ?u32,
};

const MAX_REPEAT: u32 = 1 << 14;

const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    position: usize,

    fn peek(self: *Parser) ?u8 {
        if (self.position >= self.pattern.len) return null;
        return self.pattern[self.position];
    }

    fn makeNode(self: *Parser, node: Node) Error!*const Node {
        const pointer = try self.allocator.create(Node);
        pointer.* = node;
        return pointer;
    }

    fn parseAlternation(self: *Parser) Error!*const Node {
        var branches = std.ArrayListUnmanaged(*const Node).empty;
        while (true) {
            const branch = try self.parseConcat();
            try branches.append(self.allocator, branch);
            if (self.peek() == '|') {
                self.position += 1;
                continue;
            }
            break;
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.makeNode(.{ .alt = branches.items });
    }

    fn parseConcat(self: *Parser) Error!*const Node {
        var children = std.ArrayListUnmanaged(*const Node).empty;
        while (self.peek()) |character| {
            if (character == '|' or character == ')') break;
            const child = try self.parseRepeat();
            try children.append(self.allocator, child);
        }
        if (children.items.len == 0) return self.makeNode(.empty);
        if (children.items.len == 1) return children.items[0];
        return self.makeNode(.{ .concat = children.items });
    }

    fn parseRepeat(self: *Parser) Error!*const Node {
        var atom = try self.parseAtom();
        while (self.peek()) |character| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (character) {
                '*' => {
                    self.position += 1;
                },
                '+' => {
                    min = 1;
                    self.position += 1;
                },
                '?' => {
                    max = 1;
                    self.position += 1;
                },
                '{' => {
                    if (!try self.tryParseBraces(&min, &max)) break;
                },
                else => break,
            }
            if (min > MAX_REPEAT or (max != null and max.? > MAX_REPEAT)) return error.InvalidPattern;
            switch (atom.*) {
                .anchor_start, .anchor_end, .empty => return error.InvalidPattern, // nothing to repeat
                else => {},
            }
            atom = try self.makeNode(.{ .repeat = .{ .child = atom, .min = min, .max = max } });
            if (self.peek() == '?') self.position += 1; // lazy: same match set for a boolean search
            if (self.peek()) |next_character| {
                if (next_character == '*' or next_character == '+' or next_character == '?') {
                    return error.InvalidPattern;
                }
            }
        }
        return atom;
    }

    fn tryParseBraces(self: *Parser, min: *u32, max: *?u32) Error!bool {
        const saved = self.position;
        self.position += 1; // consume '{'
        var lower: u32 = 0;
        var digits: usize = 0;
        while (self.peek()) |character| {
            if (character < '0' or character > '9') break;
            lower = lower * 10 + (character - '0');
            if (lower > MAX_REPEAT) {
                self.position = saved;
                return false;
            }
            self.position += 1;
            digits += 1;
        }
        if (digits == 0) {
            self.position = saved;
            return false;
        }
        if (self.peek() == '}') {
            self.position += 1;
            min.* = lower;
            max.* = lower;
            return true;
        }
        if (self.peek() != ',') {
            self.position = saved;
            return false;
        }
        self.position += 1;
        if (self.peek() == '}') {
            self.position += 1;
            min.* = lower;
            max.* = null;
            return true;
        }
        var upper: u32 = 0;
        var upper_digits: usize = 0;
        while (self.peek()) |character| {
            if (character < '0' or character > '9') break;
            upper = upper * 10 + (character - '0');
            if (upper > MAX_REPEAT) {
                self.position = saved;
                return false;
            }
            self.position += 1;
            upper_digits += 1;
        }
        if (upper_digits == 0 or self.peek() != '}') {
            self.position = saved;
            return false;
        }
        self.position += 1;
        min.* = lower;
        max.* = upper;
        return true;
    }

    fn parseAtom(self: *Parser) Error!*const Node {
        const character = self.peek() orelse return self.makeNode(.empty);
        switch (character) {
            '(' => {
                self.position += 1;
                if (self.peek() == '?') {
                    self.position += 1;
                    const modifier = self.peek() orelse return error.InvalidPattern;
                    if (modifier == ':') {
                        self.position += 1;
                    } else {
                        return error.InvalidPattern; // lookaround and named groups unsupported
                    }
                }
                const inner = try self.parseAlternation();
                if (self.peek() != ')') return error.InvalidPattern;
                self.position += 1;
                return inner;
            },
            '[' => return self.parseClass(),
            '.' => {
                self.position += 1;
                return self.makeNode(.any);
            },
            '^' => {
                self.position += 1;
                return self.makeNode(.anchor_start);
            },
            '$' => {
                self.position += 1;
                return self.makeNode(.anchor_end);
            },
            '\\' => return self.parseEscape(),
            ')', '|' => return self.makeNode(.empty),
            '*', '+', '?' => return error.InvalidPattern, // nothing to repeat
            else => {
                self.position += 1;
                return self.makeNode(.{ .literal = character });
            },
        }
    }

    fn parseEscape(self: *Parser) Error!*const Node {
        self.position += 1; // consume '\'
        const character = self.peek() orelse return error.InvalidPattern;
        self.position += 1;
        switch (character) {
            'd' => return self.makeNode(.{ .class = digitClass() }),
            'D' => return self.makeNode(.{ .class = inverted(digitClass()) }),
            'w' => return self.makeNode(.{ .class = wordClass() }),
            'W' => return self.makeNode(.{ .class = inverted(wordClass()) }),
            's' => return self.makeNode(.{ .class = spaceClass() }),
            'S' => return self.makeNode(.{ .class = inverted(spaceClass()) }),
            'n' => return self.makeNode(.{ .literal = '\n' }),
            'r' => return self.makeNode(.{ .literal = '\r' }),
            't' => return self.makeNode(.{ .literal = '\t' }),
            'f' => return self.makeNode(.{ .literal = 12 }),
            'v' => return self.makeNode(.{ .literal = 11 }),
            '0' => return self.makeNode(.{ .literal = 0 }),
            'x' => return self.parseHexEscape(2),
            'u' => {
                if (self.peek() == '{') return error.InvalidPattern;
                return self.parseHexEscape(4);
            },
            else => return self.makeNode(.{ .literal = character }),
        }
    }

    fn parseHexEscape(self: *Parser, digits: usize) Error!*const Node {
        if (self.position + digits > self.pattern.len) return error.InvalidPattern;
        const value = std.fmt.parseInt(u32, self.pattern[self.position .. self.position + digits], 16) catch return error.InvalidPattern;
        self.position += digits;
        var bytes: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(value), &bytes) catch return error.InvalidPattern;
        if (length == 1) return self.makeNode(.{ .literal = bytes[0] });
        var children = std.ArrayListUnmanaged(*const Node).empty;
        for (bytes[0..length]) |byte| {
            try children.append(self.allocator, try self.makeNode(.{ .literal = byte }));
        }
        return self.makeNode(.{ .concat = children.items });
    }

    fn parseClass(self: *Parser) Error!*const Node {
        self.position += 1; // consume '['
        var class = ClassSet{};
        if (self.peek() == '^') {
            class.negate = true;
            self.position += 1;
        }
        var first = true;
        while (true) {
            const character = self.peek() orelse return error.InvalidPattern;
            if (character == ']' and !first) {
                self.position += 1;
                return self.makeNode(.{ .class = class });
            }
            first = false;
            var low: ?u8 = null;
            var nested: ?ClassSet = null;
            if (character == '\\') {
                self.position += 1;
                const escaped = self.peek() orelse return error.InvalidPattern;
                self.position += 1;
                switch (escaped) {
                    'd' => nested = digitClass(),
                    'D' => nested = inverted(digitClass()),
                    'w' => nested = wordClass(),
                    'W' => nested = inverted(wordClass()),
                    's' => nested = spaceClass(),
                    'S' => nested = inverted(spaceClass()),
                    'n' => low = '\n',
                    'r' => low = '\r',
                    't' => low = '\t',
                    'f' => low = 12,
                    'v' => low = 11,
                    '0' => low = 0,
                    'x' => {
                        low = try self.classHex(2);
                    },
                    'u' => {
                        low = try self.classHex(4);
                    },
                    else => low = escaped,
                }
            } else {
                self.position += 1;
                low = character;
            }
            if (nested) |set| {
                var index: usize = 0;
                while (index < 32) : (index += 1) class.bits[index] |= set.bits[index];
                continue;
            }
            const low_byte = low.?;
            if (self.peek() == '-' and self.position + 1 < self.pattern.len and self.pattern[self.position + 1] != ']') {
                self.position += 1; // consume '-'
                var high = self.pattern[self.position];
                self.position += 1;
                if (high == '\\') {
                    const escaped = self.peek() orelse return error.InvalidPattern;
                    self.position += 1;
                    high = switch (escaped) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => escaped,
                    };
                }
                if (high < low_byte) return error.InvalidPattern;
                class.addRange(low_byte, high);
            } else {
                class.add(low_byte);
            }
        }
    }

    fn classHex(self: *Parser, digits: usize) Error!u8 {
        if (self.position + digits > self.pattern.len) return error.InvalidPattern;
        const value = std.fmt.parseInt(u32, self.pattern[self.position .. self.position + digits], 16) catch return error.InvalidPattern;
        self.position += digits;
        if (value > 0xFF) return error.InvalidPattern;
        return @intCast(value);
    }
};

fn emitNode(allocator: std.mem.Allocator, program: *std.ArrayListUnmanaged(Inst), node: *const Node) Error!void {
    switch (node.*) {
        .empty => {},
        .literal => |byte| try program.append(allocator, .{ .byte = byte }),
        .any => try program.append(allocator, .any),
        .class => |class| try program.append(allocator, .{ .class = class }),
        .anchor_start => try program.append(allocator, .anchor_start),
        .anchor_end => try program.append(allocator, .anchor_end),
        .concat => |children| {
            for (children) |child| try emitNode(allocator, program, child);
        },
        .alt => |branches| try emitAlt(allocator, program, branches),
        .repeat => |repeat| try emitRepeat(allocator, program, repeat),
    }
}

fn emitAlt(allocator: std.mem.Allocator, program: *std.ArrayListUnmanaged(Inst), branches: []const *const Node) Error!void {
    if (branches.len == 1) return emitNode(allocator, program, branches[0]);
    var end_jumps = std.ArrayListUnmanaged(u32).empty;
    defer end_jumps.deinit(allocator);
    for (branches[0 .. branches.len - 1]) |branch| {
        const split_index: u32 = @intCast(program.items.len);
        try program.append(allocator, .{ .split = .{ 0, 0 } });
        const first: u32 = @intCast(program.items.len);
        try emitNode(allocator, program, branch);
        const jump_index: u32 = @intCast(program.items.len);
        try program.append(allocator, .{ .jump = 0 });
        try end_jumps.append(allocator, jump_index);
        const second: u32 = @intCast(program.items.len);
        program.items[split_index] = .{ .split = .{ first, second } };
    }
    try emitNode(allocator, program, branches[branches.len - 1]);
    const end: u32 = @intCast(program.items.len);
    for (end_jumps.items) |jump_index| program.items[jump_index] = .{ .jump = end };
}

fn emitRepeat(allocator: std.mem.Allocator, program: *std.ArrayListUnmanaged(Inst), repeat: Repeat) Error!void {
    var index: u32 = 0;
    while (index < repeat.min) : (index += 1) {
        try emitNode(allocator, program, repeat.child);
    }
    const max = repeat.max orelse {
        const loop_start: u32 = @intCast(program.items.len);
        try program.append(allocator, .{ .split = .{ 0, 0 } });
        const body: u32 = @intCast(program.items.len);
        try emitNode(allocator, program, repeat.child);
        try program.append(allocator, .{ .jump = loop_start });
        const after: u32 = @intCast(program.items.len);
        program.items[loop_start] = .{ .split = .{ body, after } };
        return;
    };
    var optional_index: u32 = repeat.min;
    var end_jumps = std.ArrayListUnmanaged(u32).empty;
    defer end_jumps.deinit(allocator);
    while (optional_index < max) : (optional_index += 1) {
        const split_index: u32 = @intCast(program.items.len);
        try program.append(allocator, .{ .split = .{ 0, 0 } });
        const body: u32 = @intCast(program.items.len);
        try emitNode(allocator, program, repeat.child);
        const jump_index: u32 = @intCast(program.items.len);
        try program.append(allocator, .{ .jump = 0 });
        try end_jumps.append(allocator, jump_index);
        const after: u32 = @intCast(program.items.len);
        program.items[split_index] = .{ .split = .{ body, after } };
    }
    const end: u32 = @intCast(program.items.len);
    for (end_jumps.items) |jump_index| program.items[jump_index] = .{ .jump = end };
}

fn swapCaseByte(byte: u8) u8 {
    if (std.ascii.isLower(byte)) return std.ascii.toUpper(byte);
    if (std.ascii.isUpper(byte)) return std.ascii.toLower(byte);
    return byte;
}
