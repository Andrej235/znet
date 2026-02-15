const std = @import("std");
const znet = @import("znet");

const EchoContract = struct {
    pub fn echo(message: []const u8) []const u8 {
        return message;
    }
};

const Schema = znet.Schema(.{
    .server_contracts = &.{
        EchoContract,
    },
});

test "echo" {
    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    const server = try znet.Server.run(std.heap.page_allocator, .{}, Schema, address);

    std.Thread.sleep(1_000_000); // todo: make server.run block until all threads are ready

    const client = try znet.Client(Schema).init(std.heap.page_allocator, .{});
    try client.connect(address);

    var promise = try client.fetch(EchoContract.echo, .{"Hello, world!"});
    const res = try promise.await(.release);
    std.debug.print("{s}\n", .{res});
    try client.disconnect();

    std.Thread.sleep(1_000_000);
    try server.stop();
}
