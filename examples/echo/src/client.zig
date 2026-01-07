const std = @import("std");
const znet = @import("znet");
const TestContract = @import("server/test-contract").TestContract;

pub fn main() !void {
    var client = try znet.Client.init(std.heap.page_allocator, .{});
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    try client.connect(address);

    const result = (try client.fetch(TestContract.add, .{12345})).await();

    std.debug.print("{!}\n", .{result});
    try client.deinit();

    // keep the program alive to allow background network thread to operate, todo: get rid of this
    std.Thread.sleep(100000000000);
}

const ASDContract = struct {
    pub fn add(a: i32) AddErrors!i32 {
        if (a > 5)
            return error.ValOver5;

        return a;
    }
};

pub const AddErrors = error{
    ValOver5,
};
