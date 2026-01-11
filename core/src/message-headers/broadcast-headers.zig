const MessageType = @import("message-type.zig").MessageType;

pub const BroadcastHeaders = struct {
    version: u8,
    message_type: MessageType,
    flags: u16,
    contract_id: u16,
    method_id: u16,
    payload_len: u32,
};

pub const ByteSize = @sizeOf(BroadcastHeaders);
pub const BitSize = @bitSizeOf(BroadcastHeaders);
