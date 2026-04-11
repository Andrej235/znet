const std = @import("std");

const Connection = @import("../http/connection.zig").Connection;

pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    version: HttpVersion,
    connection: Connection,

    body: ?[]const u8,
    content_type: ?ContentType,
    accepts: ?[]const u8,
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
    http10,
    http11,
    http2,

    pub fn fromString(s: []const u8) ?HttpVersion {
        if (std.mem.eql(u8, s, "HTTP/1.0")) return .http10;
        if (std.mem.eql(u8, s, "HTTP/1.1")) return .http11;
        if (std.mem.eql(u8, s, "HTTP/2.0")) return .http2;
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

/// Request body content type, not suitable for representing response types which can be more complex (e.g. streaming, multipart, etc.)
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

pub const ResponseContentType = enum {
    json, // default
    octet_stream,
    text,

    pub fn fromString(content_type: []const u8) ?ResponseContentType {
        if (std.ascii.eqlIgnoreCase(content_type, "application/json") or std.ascii.eqlIgnoreCase(content_type, "text/json")) {
            return .json;
        }
        return null;
    }

    /// Content type parameter needs to be in the same format as in the Accept header, e.g. "application/json"
    /// Supports content negotiation with quality values (q), e.g. "application/json;q=0.8, application/xml;q=0.9"
    /// If content type is set to a wildcard ("*/*"), it will default to json
    /// If content type is null, it will be treated as "*/*"
    /// If content type is not supported, an error will be returned
    pub fn fromAcceptHeader(content_type: []const u8) ?ResponseContentType {
        if (std.mem.eql(u8, content_type, "*/*")) {
            return .json;
        }

        var best_quality: f32 = 0.0;
        var best_content_type: ?ResponseContentType = null;

        var it = std.mem.tokenizeAny(u8, content_type, " ,");
        while (it.next()) |token| {
            const semicolon_index = std.mem.indexOfScalar(u8, token, ';');
            if (semicolon_index) |sc_idx| {
                const params = std.mem.trim(u8, token[sc_idx + 1 ..], &std.ascii.whitespace);
                if (std.mem.indexOfScalar(u8, params, '=')) |eq_idx| {
                    const param_name = std.mem.trim(u8, params[0..eq_idx], &std.ascii.whitespace);
                    const param_value = std.mem.trim(u8, params[eq_idx + 1 ..], &std.ascii.whitespace);

                    if (std.mem.eql(u8, param_name, "q")) {
                        const quality = std.fmt.parseFloat(f32, param_value) catch continue;
                        if (quality > best_quality and quality <= 1.0) {
                            const ct = std.mem.trim(u8, token[0..sc_idx], &std.ascii.whitespace);
                            if (ResponseContentType.fromString(ct)) |ct_enum| {
                                best_quality = quality;
                                best_content_type = ct_enum;
                            }
                        }
                    }
                }
            } else {
                // If there's no semicolon, the entire token is the content type with a default quality of 1.0
                const trimmed_ct = std.mem.trim(u8, token, &std.ascii.whitespace);
                if (ResponseContentType.fromString(trimmed_ct)) |ct| {
                    return ct;
                }
            }
        }

        return best_content_type;
    }

    pub fn toString(self: ResponseContentType) []const u8 {
        return switch (self) {
            .json => "application/json",
            .octet_stream => "application/octet-stream",
            .text => "text/plain",
        };
    }

    pub fn toStringUtf8(self: ResponseContentType) []const u8 {
        return switch (self) {
            .json => "application/json; charset=utf-8",
            .octet_stream => "application/octet-stream; charset=utf-8",
            .text => "text/plain; charset=utf-8",
        };
    }
};
