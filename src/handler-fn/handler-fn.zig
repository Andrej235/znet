const std = @import("std");

pub const HandlerFn = *const fn (allocator: std.mem.Allocator, input_reader: anytype, output_writer: anytype) anyerror!void;
