pub const ClientOptions = struct {
    max_pending_requests: u32 = 128,
    read_buffer_size: usize = 4096,
    write_buffer_size: usize = 4096,
    max_outbound_messages: usize = 128,
    max_inbound_messages: usize = 128,
};