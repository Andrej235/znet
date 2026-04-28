const std = @import("std");

pub const ContentEncoding = enum {
    identity,
    gzip,
    deflate,
    br,

    pub fn fromString(s: []const u8) ?ContentEncoding {
        if (std.ascii.eqlIgnoreCase(s, "identity")) {
            return .identity;
        }

        if (std.ascii.eqlIgnoreCase(s, "gzip")) {
            return .gzip;
        }

        if (std.ascii.eqlIgnoreCase(s, "deflate")) {
            return .deflate;
        }

        if (std.ascii.eqlIgnoreCase(s, "br")) {
            return .br;
        }

        return null;
    }

    pub fn toString(self: ContentEncoding) []const u8 {
        return switch (self) {
            .identity => "identity",
            .gzip => "gzip",
            .deflate => "deflate",
            .br => "br",
        };
    }

    pub fn iteratorFromHeaderValue(header_value: []const u8) ContentEncodingIterator {
        return ContentEncodingIterator.init(header_value);
    }
};

/// Parses the `Content-Encoding` header value and returns an iterator over the encodings specified in the header
/// The encodings are returned in the order they are supposed to be decoded (i.e. the first encoding returned by the iterator is the last encoding applied to the content)
const ContentEncodingIterator = struct {
    std_iterator: std.mem.SplitBackwardsIterator(u8, .scalar),

    pub fn init(header_value: []const u8) ContentEncodingIterator {
        return ContentEncodingIterator{
            .std_iterator = std.mem.splitBackwardsScalar(u8, header_value, ','),
        };
    }

    pub const Errors = error{
        InvalidEncoding,
        EncodingNotSupported,
    };

    pub fn next(self: *ContentEncodingIterator) Errors!?ContentEncoding {
        const part = self.std_iterator.next() orelse return null;
        const token = std.mem.trim(u8, part, &std.ascii.whitespace);

        if (token.len == 0) {
            return Errors.InvalidEncoding;
        }

        return ContentEncoding.fromString(token) orelse return Errors.EncodingNotSupported;
    }
};
