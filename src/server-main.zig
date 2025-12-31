const std = @import("std");
const Server = @import("server/server.zig").Server;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try Server(.{
        .contracts = &.{TestContract},
        .max_clients = 2048,
    }).init(allocator);

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    try server.run(address);
}

const TestContract = struct {
    pub fn testFunction(x: i32) i32 {
        // std.debug.print("---> testFunction: {}\n", .{x});
        return 5 * x;
    }
};
