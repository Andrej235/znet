const std = @import("std");
const MessageHeader = @import("message-header.zig").MessageHeader;
const RequestHeader = @import("request-header.zig").RequestHeader;
const ResponseHeader = @import("response-header.zig").ResponseHeader;
const app_version = @import("../app-version.zig").app_version;

pub fn deserializeMessageHeader(reader: anytype) !MessageHeader {
    const version = try reader.readInt(u8, .big);
    if (version != app_version) {
        return error.InvalidMessageHeaderVersion;
    }

    const msg_type = try reader.readInt(u8, .big);
    return switch (msg_type) {
        0 => {
            const header: RequestHeader = .{
                .version = version,
                .msg_type = .Request,
                .request_id = try reader.readInt(u32, .big),
                .contract_id = try reader.readInt(u16, .big),
                .method_id = try reader.readInt(u16, .big),
                .payload_len = try reader.readInt(u32, .big),
            };
            return .{ .Request = header };
        },
        1 => {
            const header: ResponseHeader = .{
                .version = version,
                .msg_type = .Response,
                .request_id = try reader.readInt(u32, .big),
                .payload_len = try reader.readInt(u32, .big),
            };
            return .{ .Response = header };
        },
        else => return DeserializeMessageHeaderErrors.InvalidMessageType,
    };
}

const DeserializeMessageHeaderErrors = error{
    InvalidMessageHeaderVersion,
    InvalidMessageType,
};
