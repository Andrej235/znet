const std = @import("std");
const HandlerFn = @import("handler-fn.zig").HandlerFn;

pub fn createHandlerFn(comptime fn_impl: anytype) HandlerFn {
    return struct {
        fn handler(allocator: std.mem.Allocator, input_reader: anytype, output_writer: anytype) anyerror!void {
            // unimplemented
            _ = allocator;
            _ = input_reader;
            _ = output_writer;
            std.debug.print("Deserialize payload\n", .{});
            _ = fn_impl() catch {};
            std.debug.print("Serialize output headers and payload\n", .{});
        }
    }.handler;
}
