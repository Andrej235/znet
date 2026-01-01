const std = @import("std");
const posix = std.posix;

const Serializer = @import("serializer/serializer.zig").Serializer;
const CountingSerializer = @import("serializer/counting-serializer.zig").Serializer;
const serializeMessageHeaders = @import("message-headers/serialize-message-headers.zig").serializeMessageHeaders;
const deserializeMessageHeaders = @import("message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;
const RequestHeaders = @import("message-headers/request-headers.zig").RequestHeaders;

const Client = @import("client/client.zig").Client;
const TestContract = @import("server-main.zig").TestContract;

pub fn main() !void {
    var client = try Client(.{ .server_contracts = &.{TestContract} }).init(std.heap.page_allocator);
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    try client.connect(address);

    const result = try client.contracts.Test.echoString(client, .{"Hello, world!"});
    std.debug.print("from main: {s}\n", .{@typeName(@TypeOf(result))});
    const a = try result.await();
    std.debug.print("{s}\n", .{a});

    // keep the program alive to allow background network thread to operate, todo: get rid of this
    std.Thread.sleep(100000000000);
}
