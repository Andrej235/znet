pub const ClientOptions = struct {
    server_contracts: []const type,
    max_pending_requests: u32 = 128,
};