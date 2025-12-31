const std = @import("std");
const posix = std.posix;

const Serializer = @import("serializer/serializer.zig").Serializer;
const CountingSerializer = @import("serializer/counting-serializer.zig").Serializer;
const serializeMessageHeaders = @import("message-headers/serialize-message-headers.zig").serializeMessageHeaders;
const deserializeMessageHeaders = @import("message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;
const RequestHeaders = @import("message-headers/request-headers.zig").RequestHeaders;

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    const socket = try posix.socket(
        address.any.family,
        posix.SOCK.STREAM,
        posix.IPPROTO.TCP,
    );
    defer posix.close(socket);

    try posix.connect(socket, &address.any, address.getOsSockLen());

    while (true) {
        try send(@as(u32, 25), socket);
        const msg = try readMessage(socket);
        std.debug.print("received: {any}\n", .{msg});

        std.Thread.sleep(1000);
    }
}

var send_buffer: [1024]u8 = undefined;
var read_buf: [1024]u8 = undefined;
var read_pos: usize = 0;
var reader = std.io.Reader.fixed(&read_buf);

fn send(comptime payload: anytype, socket: posix.socket_t) !void {
    const T = @TypeOf(payload);

    const payload_len = try CountingSerializer.serialize(T, payload);
    var writer: std.Io.Writer = .fixed(&send_buffer);

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

    const total_len = payload_len + 14; // header size
    try writeAll(socket, send_buffer[0..total_len]);

    std.debug.print("Sent request ({any})\n", .{payload});
}

fn writeAll(socket: posix.socket_t, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        sent += try posix.write(socket, data[sent..]);
    }
}

fn readMessage(socket: posix.socket_t) ![]u8 {
    while (true) {
        // loop until we have a full message to process
        if (try bufferedMessage()) |msg|
            return msg;

        // read more data from the socket, fills up the buffer from pos to the end
        const n = try posix.read(socket, read_buf[read_pos..]);
        if (n == 0) // no more data, connection closed or EOF
            return error.Closed;

        read_pos += n;
    }
}

fn bufferedMessage() !?[]u8 {
    if (read_pos < 10) {
        // not enough data to read the header
        return null;
    }

    const header = try deserializeMessageHeaders(&reader);
    const payload_len = header.Response.payload_len;

    const message_len = payload_len + 10;

    if (read_pos < message_len) {
        // not enough data to read the full message
        return null;
    }

    // copy out the full message before shifting the buffer
    const msg = read_buf[0..message_len];

    // shift remaining data to the front of the buffer
    @memmove(read_buf[0 .. read_pos - message_len], read_buf[message_len..read_pos]);
    read_pos -= message_len;
    reader.seek = 0;

    return msg;
}
