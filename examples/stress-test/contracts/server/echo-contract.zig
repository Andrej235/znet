const std = @import("std");
const znet = @import("znet");
const ClientEchoContract = @import("client/echo-contract").EchoContract;

pub const EchoContract = struct {
    pub fn echo(ctx: *znet.Context, message: []const u8) []const u8 {
        var audience = ctx.clients.all() catch |err| {
            std.debug.print("Failed to get all clients - {}\n", .{err});
            return message;
        };
        audience.broadcast(ClientEchoContract.echo, .{message}) catch |err| {
            std.debug.print("Failed to broadcast - {}\n", .{err});
            return message;
        };

        return message;
    }
};
