const std = @import("std");
const Out = @import("out.zig").Out;

pub const Context = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    out: *Out,
    argv: []const []const u8,
};
