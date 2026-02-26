const std = @import("std");
const windows = std.os.windows;
const posix = std.posix;
const ws2_32 = windows.ws2_32;
const net = std.net;
const Poller = @import("../poller/poller.zig");

pub const WindowsListener = struct {
    listener_fd: posix.socket_t,

    pub fn init(address: net.Address) !WindowsListener {
        const s = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        errdefer posix.close(s);

        var mode: u32 = 1;
        if (ws2_32.ioctlsocket(s, ws2_32.FIONBIO, &mode) == ws2_32.SOCKET_ERROR) return error.Unexpected;

        try posix.setsockopt(s, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(s, &address.any, address.getOsSockLen());
        try posix.listen(s, 128);

        return WindowsListener{ .listener_fd = s };
    }

    pub fn register(self: *WindowsListener, poller: *Poller, index: u32) !void {
        try poller.add(self.listener_fd, index, true, false);
    }

    pub fn drainAccepts(self: *WindowsListener, comptime _: type, reactor: anytype) !void {
        while (true) {
            var address: std.net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(std.net.Address);

            const socket = posix.accept(self.listener_fd, &address.any, &address_len, 0) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            var mode: u32 = 1;
            if (ws2_32.ioctlsocket(socket, ws2_32.FIONBIO, &mode) == ws2_32.SOCKET_ERROR) {
                posix.close(socket);
                continue;
            }

            reactor.attachClientSocket(socket, address) catch |err| {
                posix.close(socket);
                if (err == error.ReactorFull) return;
                return err;
            };
        }
    }

    pub fn deinit(self: *WindowsListener) void {
        posix.close(self.listener_fd);
    }
};
