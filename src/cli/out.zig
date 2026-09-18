const std = @import("std");

pub const Out = struct {
    stdout: std.Io.File.Writer,
    stderr: std.Io.File.Writer,

    pub fn init(io: std.Io, stdout_buffer: []u8, stderr_buffer: []u8) Out {
        return .{
            .stdout = std.Io.File.stdout().writerStreaming(io, stdout_buffer),
            .stderr = std.Io.File.stderr().writerStreaming(io, stderr_buffer),
        };
    }

    pub fn print(self: *Out, line: []const u8) !void {
        try self.stdout.interface.writeAll(line);
        try self.stdout.interface.writeAll("\n");
    }

    pub fn printRaw(self: *Out, text: []const u8) !void {
        try self.stdout.interface.writeAll(text);
    }

    pub fn err(self: *Out, line: []const u8) !void {
        self.stdout.interface.flush() catch {};
        try self.stderr.interface.writeAll(line);
        try self.stderr.interface.writeAll("\n");
    }

    pub fn flush(self: *Out) !void {
        try self.stdout.interface.flush();
        try self.stderr.interface.flush();
    }
};
