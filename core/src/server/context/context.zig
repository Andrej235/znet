const std = @import("std");
const Clients = @import("clients.zig").Clients;

pub const Context = struct {
    allocator: std.mem.Allocator,
    clients: Clients,
};
