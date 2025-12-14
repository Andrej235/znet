pub const Role = enum {
    client,
    server,
};

pub var running_as: Role = .client;
