const std = @import("std");
const RequestHeaders = @import("../../message_headers/request_headers.zig").RequestHeaders;
const ReactorContext = @import("../reactor.zig").ReactorContext;

pub const HandlerFn = *const fn (
    context: ReactorContext,
    request_headers: RequestHeaders,
    input_reader: *std.Io.Reader,
    output_writer: *std.Io.Writer,
    input_buffer_idx: u32,
) anyerror!void;
