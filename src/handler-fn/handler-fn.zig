const std = @import("std");

pub const HandlerFn = *const fn (allocator: std.mem.Allocator, input_reader: *std.Io.Reader, output_writer: *std.Io.Writer) anyerror!void;
