pub const ServerOptions = struct {
    contracts: []const type,
    max_clients: usize = 1024,
};
