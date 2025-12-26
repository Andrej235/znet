const MessageType = @import("message-type.zig").MessageType;

pub const ResponseHeader = struct {
    version: u8,
    msg_type: MessageType,
    request_id: u32,
    payload_len: u32,
};
