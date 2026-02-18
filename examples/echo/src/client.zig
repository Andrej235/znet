const std = @import("std");
const znet = @import("znet");
const EchoContract = @import("contracts/server/echo_contract.zig").EchoContract;

const Schema = znet.Schema(.{ .server_contracts = &.{EchoContract} });

pub fn main() !void {
    var client = try znet.Client(Schema).init(std.heap.page_allocator, .{});
    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try client.connect(address);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var writer = &stdout_writer.interface;

    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var reader = &stdin_reader.interface;

    try writer.writeAll("Echo client: type messages and press Enter to send, you will see them echoed back by the server\n> ");
    try writer.flush();

    while (try reader.takeDelimiter('\n')) |message| {
        var promise = try client.fetch(EchoContract.echo, .{message});
        const echoed_message = try promise.await(.release);

        try writer.writeAll("< ");
        try writer.writeAll(echoed_message);
        try writer.writeAll("\n> ");
        try writer.flush();

        promise.destroy(echoed_message);
    }
}
