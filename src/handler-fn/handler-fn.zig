const std = @import("std");

pub const HandlerFn = *const fn (allocator: std.mem.Allocator, input_reader: std.io.AnyReader, output_writer: std.io.AnyWriter) anyerror!void;
