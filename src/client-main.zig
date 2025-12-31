const std = @import("std");
const posix = std.posix;
const Serializer = @import("serializer/serializer.zig").Serializer;
const CountingSerializer = @import("serializer/counting-serializer.zig").Serializer;
const serializeMessageHeaders = @import("message-headers/serialize-message-headers.zig").serializeMessageHeaders;
const RequestHeaders = @import("message-headers/request-headers.zig").RequestHeaders;

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    const socket = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(socket);

    try posix.connect(socket, &address.any, address.getOsSockLen());

    try send(@as(u32, 25), socket);

    var test_count: u32 = 1;
    while (true) {
        try sendMessage(socket, storage[0..18]);
        test_count += 1;
        std.debug.print("{}\n", .{test_count});
        std.Thread.sleep(std.time.ns_per_ms * 500);
    }

    // const socket2 = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    // defer posix.close(socket2);

    // try posix.connect(socket2, &address.any, address.getOsSockLen());
    // try send(@as(u32, 33), socket2);

    std.Thread.sleep(1_000_000_000_000); // todo: fix server crashing when a client disconnects while trying to read request
}

var storage: [1024]u8 = undefined;
var writer: std.Io.Writer = .fixed(&storage);

fn send(comptime payload: anytype, socket: posix.socket_t) !void {
    const T = @TypeOf(payload);
    const payload_len = try CountingSerializer.serialize(T, payload);
    try serializeMessageHeaders(&writer, .{
        .Request = .{
            .version = 1,
            .contract_id = 0,
            .method_id = 0,
            .msg_type = .Request,
            .request_id = 123,
            .payload_len = payload_len,
        },
    });
    try Serializer.serialize(T, &writer, payload);

    try sendMessage(socket, storage[0 .. payload_len + 14]);

    std.debug.print("Sent message {any}\n", .{payload});
}

fn sendMessage(socket: posix.socket_t, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        sent += try posix.write(socket, data[sent..]);
    }
}
