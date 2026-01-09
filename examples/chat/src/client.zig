const std = @import("std");
const znet = @import("znet");
const MessageContract = @import("server/message-contract").MessageContract;

pub fn main() !void {
    var client = try znet.Client.init(std.heap.page_allocator, .{});
    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try client.connect(address);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var writer = &stdout_writer.interface;

    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var reader = &stdin_reader.interface;

    try writer.writeAll("Chat client: enter your name\n");
    try writer.flush();

    try writer.writeAll("> ");
    try writer.flush();

    const line = try reader.takeDelimiter('\n') orelse return;
    const name = try std.heap.page_allocator.dupe(u8, line);

    while (try reader.takeDelimiter('\n')) |msg| {
        const promise = try client.fetch(MessageContract.send, .{ name, msg });
        _ = promise.await();
    }
}
