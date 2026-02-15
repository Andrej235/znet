const std = @import("std");
const znet = @import("znet");

pub const EchoContract = struct {
    pub fn echo(message: []const u8) []const u8 {
        return message;
    }
};

pub const Schema = znet.Schema(.{
    .server_contracts = &.{EchoContract},
});
