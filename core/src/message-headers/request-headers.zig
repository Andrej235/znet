const MessageType = @import("message-type.zig").MessageType;

pub const RequestHeaders = struct {
    version: u8,
    msg_type: MessageType,
    flags: u16,
    request_id: u32,
    contract_id: u16,
    method_id: u16,
    payload_len: u32,
};

pub const ByteSize = @sizeOf(RequestHeaders);
pub const BitSize = @bitSizeOf(RequestHeaders);
