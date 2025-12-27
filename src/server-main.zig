const std = @import("std");
const App = @import("app.zig").App;
const zNet = @import("server/server.zig");

pub fn main() !void {
    const server = zNet.Server.start(.{ .contracts = &.{TestContract} });
    server.call_tables[0][0](std.heap.page_allocator, null, null) catch |err| {
        std.debug.print("Error calling handler: {}\n", .{err});
    };
}

const TestContract = struct {
    pub fn testFunction() !void {
        std.debug.print("Test function called\n", .{});
    }
};
