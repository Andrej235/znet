const std = @import("std");
const MessageHeader = @import("message-header.zig").MessageHeader;
const RequestHeader = @import("request-header.zig").RequestHeader;
const ResponseHeader = @import("response-header.zig").ResponseHeader;
const app_version = @import("../app-version.zig").app_version;

pub fn deserializeMessageHeader(reader: anytype) DeserializeMessageHeaderErrors!MessageHeader {
    const version = reader.readInt(u8, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField;
    if (version != app_version) {
        return DeserializeMessageHeaderErrors.InvalidMessageHeaderVersion;
    }

    const msg_type = reader.readInt(u8, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField;
    return switch (msg_type) {
        0 => {
            const header: RequestHeader = .{
                .version = version,
                .msg_type = .Request,
                .request_id = reader.readInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .contract_id = reader.readInt(u16, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .method_id = reader.readInt(u16, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .payload_len = reader.readInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
            };
            return .{ .Request = header };
        },
        1 => {
            const header: ResponseHeader = .{
                .version = version,
                .msg_type = .Response,
                .request_id = reader.readInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .payload_len = reader.readInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
            };
            return .{ .Response = header };
        },
        else => return DeserializeMessageHeaderErrors.InvalidMessageType,
    };
}

const DeserializeMessageHeaderErrors = error{
    InvalidMessageHeaderVersion,
    InvalidMessageType,
    EndOfStream,
    FailedToReadField,
};
