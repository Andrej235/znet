const std = @import("std");
const znet = @import("znet");

const EchoContract = struct {
    pub fn echo(message: []const u8) []const u8 {
        return message;
    }
};

const Schema = znet.Schema(.{
    .server_contracts = &.{
        EchoContract,
    },
});

const address = std.net.Address.parseIp("127.0.0.1", 5000) catch unreachable;

test "Basic connect" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const server = try znet.Server(Schema).init(gpa.allocator(), .{});
    try server.run(address);

    var client = try znet.Client(Schema).init(gpa.allocator(), .{});
    try client.connect(address);

    try client.disconnect();
    try client.deinit();

    try server.shutdown(.immediate);
    server.join();
    try server.deinit();
}

test "Connect multiple times" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const server = try znet.Server(Schema).init(gpa.allocator(), .{});
    try server.run(address);

    var client = try znet.Client(Schema).init(gpa.allocator(), .{});

    for (0..1000) |_| {
        try client.connect(address);
        try client.disconnect();

        // give the server a chance to receive the disconnect before we try to connect again
        // otherwise we might just be hitting the max connection limit and not actually testing multiple connects
        std.Thread.sleep(std.time.ns_per_us);
    }

    try client.deinit();

    try server.shutdown(.immediate);
    server.join();
    try server.deinit();
}

test "Concurrent connections" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    const clients_count = 100;

    const server = try znet.Server(Schema).init(allocator, .{
        .max_clients = clients_count,
    });
    try server.run(address);

    const clients = try allocator.alloc(znet.Client(Schema), clients_count);

    for (clients) |*client| {
        client.* = try znet.Client(Schema).init(allocator, .{});
    }

    for (clients) |*client| {
        try client.connect(address);
    }

    for (clients) |*client| {
        try client.disconnect();
        try client.deinit();
    }

    allocator.free(clients);

    try server.shutdown(.immediate);
    server.join();
    try server.deinit();
}

test "Client closes connection while replying" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const server = try znet.Server(Schema).init(allocator, .{});
    try server.run(address);

    var client = try znet.Client(Schema).init(gpa.allocator(), .{});
    try client.connect(address);

    _ = try client.fetch(EchoContract.echo, .{&[_]u8{'A'} ** 1024});

    try client.disconnect();
    try client.deinit();

    try server.shutdown(.immediate);
    server.join();
    try server.deinit();
}

test "Server closes connection while replying" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    // defer std.debug.assert(gpa.deinit() == .ok);

    const server = try znet.Server(Schema).init(allocator, .{});
    try server.run(address);

    var client = try znet.Client(Schema).init(gpa.allocator(), .{});
    try client.connect(address);

    _ = try client.fetch(EchoContract.echo, .{&[_]u8{'A'} ** 1024});

    try server.shutdown(.immediate);
    server.join();
    try server.deinit();

    try client.deinit();
}
