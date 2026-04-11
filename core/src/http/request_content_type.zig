const std = @import("std");

pub const RequestContentType = enum {
    octet_stream, // default for unknown content types
    text,
    json,
    form_url_encoded,
    multipart_form_data,

    pub fn fromString(s: []const u8) ?RequestContentType {
        if (std.mem.eql(u8, s, "application/octet-stream")) return .octet_stream;
        if (std.mem.eql(u8, s, "text/plain")) return .text;
        if (std.mem.eql(u8, s, "application/json")) return .json;
        if (std.mem.eql(u8, s, "application/x-www-form-urlencoded")) return .form_url_encoded;
        if (std.mem.eql(u8, s, "multipart/form-data")) return .multipart_form_data;
        return null;
    }
};
