const MessageType = @import("message_type.zig").MessageType;

pub const ResponseHeaders = struct {
    version: u8,
    msg_type: MessageType,
    flags: u16,
    request_id: u32,
    payload_len: u32,
};

pub const ByteSize = @sizeOf(ResponseHeaders);
pub const BitSize = @bitSizeOf(ResponseHeaders);
