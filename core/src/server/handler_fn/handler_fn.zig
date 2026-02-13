const std = @import("std");
const RequestHeaders = @import("../../message_headers/request_headers.zig").RequestHeaders;
const Reactor = @import("../reactor.zig").Reactor;

pub const HandlerFn = *const fn (
    allocator: std.mem.Allocator,
    reactor: *Reactor,
    initiated_by_connection_id: u32,
    request_headers: RequestHeaders,
    input_reader: *std.Io.Reader,
    output_writer: *std.Io.Writer,
    input_buffer_idx: u32,
) anyerror!void;
