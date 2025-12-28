const std = @import("std");
const RequestHeaders = @import("../message-headers/request-header.zig").RequestHeader;

pub const HandlerFn = *const fn (
    request_headers: RequestHeaders,
    allocator: std.mem.Allocator,
    input_reader: *std.Io.Reader,
    output_writer: *std.Io.Writer,
) anyerror!void;
