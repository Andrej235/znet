const std = @import("std");
const MessageHeader = @import("message-headers.zig").MessageHeaders;
const RequestHeader = @import("request-headers.zig").RequestHeaders;
const ResponseHeader = @import("response-headers.zig").ResponseHeader;
const app_version = @import("../app-version.zig").app_version;

pub fn deserializeMessageHeaders(reader: *std.Io.Reader) DeserializeMessageHeaderErrors!MessageHeader {
    const version = reader.takeInt(u8, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField;
    if (version != app_version) {
        return DeserializeMessageHeaderErrors.InvalidMessageHeaderVersion;
    }

    const msg_type = reader.takeInt(u8, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField;
    return switch (msg_type) {
        0 => {
            const header: RequestHeader = .{
                .version = version,
                .msg_type = .Request,
                .request_id = reader.takeInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .contract_id = reader.takeInt(u16, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .method_id = reader.takeInt(u16, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .payload_len = reader.takeInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
            };
            return .{ .Request = header };
        },
        1 => {
            const header: ResponseHeader = .{
                .version = version,
                .msg_type = .Response,
                .request_id = reader.takeInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .payload_len = reader.takeInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
            };
            return .{ .Response = header };
        },
        2 => {
            const header: @import("broadcast-headers.zig").BroadcastHeaders = .{
                .version = version,
                .message_type = .Broadcast,
                .contract_id = reader.takeInt(u16, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .method_id = reader.takeInt(u16, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
                .payload_len = reader.takeInt(u32, .big) catch return DeserializeMessageHeaderErrors.FailedToReadField,
            };
            return .{ .Broadcast = header };
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
