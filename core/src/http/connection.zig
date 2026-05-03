const std = @import("std");

pub const Connection = enum {
    close,
    keep_alive,

    pub fn toString(self: Connection) []const u8 {
        return switch (self) {
            .close => "close",
            .keep_alive => "keep-alive",
        };
    }

    pub fn fromString(s: []const u8) ?Connection {
        if (std.ascii.eqlIgnoreCase(s, "close"))
            return .close;

        if (std.ascii.eqlIgnoreCase(s, "keep-alive"))
            return .keep_alive;

        return null;
    }
};
