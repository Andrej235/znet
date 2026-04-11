const std = @import("std");

pub const HttpVersion = enum {
    http10,
    http11,
    http2,

    pub fn fromString(s: []const u8) ?HttpVersion {
        if (std.ascii.eqlIgnoreCase(s, "HTTP/1.0")) return .http10;
        if (std.ascii.eqlIgnoreCase(s, "HTTP/1.1")) return .http11;
        if (std.ascii.eqlIgnoreCase(s, "HTTP/2.0")) return .http2;
        return null;
    }

    pub fn toString(self: HttpVersion) []const u8 {
        return switch (self) {
            .http10 => "HTTP/1.0",
            .http11 => "HTTP/1.1",
            .http2 => "HTTP/2.0",
        };
    }
};
