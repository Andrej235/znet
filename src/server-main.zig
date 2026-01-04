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

    // context switching / todo: replace the wrapped contracts object with a fetch(Contract.function, args), could completely omit the required client parameter as it could be a decl with self param

};

pub const AddErrors = error{
    ValOver5,
};
