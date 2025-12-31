pub const ServerOptions = struct {
    contracts: []const type,
    max_clients: u32 = 1024,
};
