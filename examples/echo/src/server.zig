const std = @import("std");
const znet = @import("znet");
const role = @import("znet/role").role;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try znet.Server(.{
        .contracts = &.{TestContract},
        .max_clients = 2048,
    }).init(allocator);

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    std.debug.print("{}\n", .{role});

    try server.run(address);
}

pub const TestContract = struct {
    pub fn testFunction(x: i32) i32 {
        return x;
    }

    pub fn echoString(s: []const u8) []const u8 {
        return s;
    }

    pub fn add(a: i32) AddErrors!i32 {
        if (a > 5)
            return error.ValOver5;

        return a;
    }
};

pub const AddErrors = error{
    ValOver5,
};
