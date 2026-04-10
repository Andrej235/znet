const std = @import("std");

pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    version: HttpVersion,

    body: ?[]const u8,
    content_type: ?ContentType,
};

pub const HttpMethod = enum(u8) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    HEAD = 4,
    OPTIONS = 5,
    CONNECT = 6,
    TRACE = 7,
    PATCH = 8,

    pub fn fromString(s: []const u8) ?HttpMethod {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, s, "CONNECT")) return .CONNECT;
        if (std.mem.eql(u8, s, "TRACE")) return .TRACE;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        return null;
    }

    pub const count = @typeInfo(@This()).@"enum".fields.len;
};

pub const HttpVersion = enum {
    Http10,
    Http11,
    Http2,

    pub fn fromString(s: []const u8) ?HttpVersion {
        if (std.mem.eql(u8, s, "HTTP/1.0")) return .Http10;
        if (std.mem.eql(u8, s, "HTTP/1.1")) return .Http11;
        if (std.mem.eql(u8, s, "HTTP/2.0")) return .Http2;
        return null;
    }
};

pub const ContentType = enum {
    octet_stream, // default for unknown content types
    text,
    json,
    form_url_encoded,
    multipart_form_data,

    pub fn fromString(s: []const u8) ?ContentType {
        if (std.mem.eql(u8, s, "application/octet-stream")) return .octet_stream;
        if (std.mem.eql(u8, s, "text/plain")) return .text;
        if (std.mem.eql(u8, s, "application/json")) return .json;
        if (std.mem.eql(u8, s, "application/x-www-form-urlencoded")) return .form_url_encoded;
        if (std.mem.eql(u8, s, "multipart/form-data")) return .multipart_form_data;
        return null;
    }
};
