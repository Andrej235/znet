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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    const server = try znet.Server(Schema).init(gpa.allocator(), .{});
    try server.run(address);

    var client = try znet.Client(Schema).init(gpa.allocator(), .{});
    try client.connect(address);

    var promise = try client.fetch(EchoContract.echo, .{"Hello, world!"});
    const res = try promise.await(.release);
    std.debug.print("{s}\n", .{res});

    promise.destroy(res);
    try client.disconnect();
    try client.deinit();

    try server.shutdown(.immediate);
    server.join();
    try server.deinit();
}
