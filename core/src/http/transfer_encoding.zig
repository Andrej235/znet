const std = @import("std");

pub const TransferEncoding = enum {
    none,
    chunked,

    pub fn fromString(s: []const u8) ?TransferEncoding {
        if (std.ascii.eqlIgnoreCase(s, "chunked")) {
            return .chunked;
        }

        if (std.ascii.eqlIgnoreCase(s, "identity")) {
            return .none;
        }

        return null;
    }
};
