const std = @import("std");
const znet = @import("znet");
const ClientEchoContract = @import("client/echo_contract").EchoContract;

pub const EchoContract = struct {
    pub fn echo(message: []const u8) []const u8 {
        return message;
    }
};
