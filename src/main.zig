const std = @import("std");
const cli = @import("cli/main.zig");

pub fn main(init: std.process.Init) u8 {
    return cli.run(init);
}
