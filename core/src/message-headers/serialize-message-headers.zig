const std = @import("std");
const MessageHeaders = @import("../message-headers/message-headers.zig").MessageHeaders;

pub fn serializeMessageHeaders(writer: *std.Io.Writer, header: MessageHeaders) anyerror!void {
    switch (header) {
        .Request => |req_header| {
            try writer.writeInt(u8, req_header.version, .big);
            try writer.writeInt(u8, 0, .big); // MessageType.Request
            try writer.writeInt(u16, req_header.flags, .big);
            try writer.writeInt(u32, req_header.request_id, .big);
            try writer.writeInt(u16, req_header.contract_id, .big);
            try writer.writeInt(u16, req_header.method_id, .big);
            try writer.writeInt(u32, req_header.payload_len, .big);
        },
        .Response => |res_header| {
            try writer.writeInt(u8, res_header.version, .big);
            try writer.writeInt(u8, 1, .big); // MessageType.Response
            try writer.writeInt(u16, res_header.flags, .big);
            try writer.writeInt(u32, res_header.request_id, .big);
            try writer.writeInt(u32, res_header.payload_len, .big);
        },
        .Broadcast => |bcast_header| {
            try writer.writeInt(u8, bcast_header.version, .big);
            try writer.writeInt(u8, 2, .big); // MessageType.Broadcast
            try writer.writeInt(u16, bcast_header.flags, .big);
            try writer.writeInt(u16, bcast_header.contract_id, .big);
            try writer.writeInt(u16, bcast_header.method_id, .big);
            try writer.writeInt(u32, bcast_header.payload_len, .big);
        },
    }
}
