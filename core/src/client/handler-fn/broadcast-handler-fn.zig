const std = @import("std");
const Client = @import("../client.zig").Client;

pub const BroadcastHandlerFn = *const fn (
    client: *Client,
    allocator: std.mem.Allocator,
    input_reader: *std.io.Reader,
) anyerror!void;
