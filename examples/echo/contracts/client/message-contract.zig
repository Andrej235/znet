const std = @import("std");
const znet = @import("znet");
const TestContract = @import("server/test-contract").TestContract;

pub const MessageContract = struct {
    pub fn receiveMessage(client: *znet.Client, sender_name: []const u8, message: []const u8) !void {
        std.debug.print(">{s}: {s}\n", .{ sender_name, message });
        const promise = try client.fetch(TestContract.multiply, .{ 3, 5 });
        const res: i32 = promise.await();
        std.debug.print("{}\n", .{res});
    }
};
