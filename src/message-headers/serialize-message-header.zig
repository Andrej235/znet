const std = @import("std");
const MessageHeader = @import("../message-headers/message-header.zig").MessageHeader;

pub fn serializeMessageHeader(writer: *std.Io.Writer, header: MessageHeader) anyerror!void {
    switch (header) {
        .Request => |req_header| {
            try writer.writeInt(u8, req_header.version, .big);
            try writer.writeInt(u8, 0, .big); // MessageType.Request
            try writer.writeInt(u32, req_header.request_id, .big);
            try writer.writeInt(u16, req_header.contract_id, .big);
            try writer.writeInt(u16, req_header.method_id, .big);
            try writer.writeInt(u32, req_header.payload_len, .big);
        },
        .Response => |res_header| {
            try writer.writeInt(u8, res_header.version, .big);
            try writer.writeInt(u8, 1, .big); // MessageType.Response
            try writer.writeInt(u32, res_header.request_id, .big);
            try writer.writeInt(u32, res_header.payload_len, .big);
        },
    }
}
