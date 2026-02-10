const std = @import("std");
const RequestHeaders = @import("../../message_headers/request_headers.zig").RequestHeaders;
const Server = @import("../server.zig").Server;

pub const HandlerFn = *const fn (
    allocator: std.mem.Allocator,
    server: *Server,
    initiated_by_connection_id: u32,
    request_headers: RequestHeaders,
    input_reader: *std.Io.Reader,
    output_writer: *std.Io.Writer,
    input_buffer_idx: u32,
) anyerror!void;
