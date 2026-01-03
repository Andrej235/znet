const MessageType = @import("message-type.zig").MessageType;

pub const BroadcastHeaders = struct {
    version: u8,
    message_type: MessageType,
    contract_id: u16,
    method_id: u16,
    payload_len: u32,
};
