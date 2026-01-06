const MessageType = @import("message-type.zig").MessageType;

// TODO: add flags
pub const RequestHeaders = struct {
    version: u8,
    msg_type: MessageType,
    request_id: u32,
    contract_id: u16,
    method_id: u16,
    payload_len: u32,
};
