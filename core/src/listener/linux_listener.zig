const std = @import("std");
const posix = std.posix;
const net = std.net;

const Poller = @import("../poller/poller.zig");
const Reactor = @import("../server/reactor.zig").Reactor;

pub const LinuxListener = struct {
    listener_fd: posix.socket_t,

    /// Create listening socket
    pub fn init(address: net.Address) !LinuxListener {
        const socket_type: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(address.any.family, socket_type, protocol);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        return LinuxListener{
            .listener_fd = listener,
        };
    }

    /// Close listener
    pub fn deinit(self: *LinuxListener) void {
        posix.close(self.listener_fd);
    }

    /// Register listener with poller
    pub fn register(self: *LinuxListener, poller: *Poller, index: u32) !void {
        try poller.add(self.listener_fd, index, true, false);
    }

    /// Called for all pending connections.
    pub fn drainAccepts(
        self: *LinuxListener,
        comptime TApp: type,
        reactor: *Reactor(TApp),
    ) !void {
        // the while loop will keep accepting connections until the first time posix.accept tries to block in order to wait for a new connection, i.e. there are no more pending connections
        // or attachClientSocket returns an error indicating that the connection should be closed immediately (e.g. if the reactor is already full and cannot accept more connections)
        while (true) {
            var address: std.net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(std.net.Address);
            const socket = posix.accept(self.listener_fd, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            reactor.attachClientSocket(socket, address) catch |err| {
                // todo: reject any other pending connections
                posix.close(socket);

                if (err == error.ReactorFull)
                    return;

                return err;
            };
        }
    }
};
