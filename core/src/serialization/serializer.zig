const std = @import("std");

pub const Json = @import("json/serializer.zig").Serializer;

pub const Errors = @import("./errors.zig").SerializationErrors || error{
    UnsupportedContentType,
};

const ContentType = enum {
    json, // default
    octet_stream,
    text,

    pub fn fromString(content_type: []const u8) ?ContentType {
        if (std.ascii.eqlIgnoreCase(content_type, "application/json") or std.ascii.eqlIgnoreCase(content_type, "text/json")) {
            return .json;
        }
        return null;
    }
};

/// Content type parameter needs to be in the same format as in the Accept header, e.g. "application/json"
/// Supports content negotiation with quality values (q), e.g. "application/json;q=0.8, application/xml;q=0.9"
/// If content type is set to a wildcard ("*/*"), it will default to json
/// If content type is null, it will be treated as "*/*"
/// If content type is not supported, an error will be returned
pub fn toContentTypeFromAcceptHeader(comptime T: type, content_type: ?[]const u8, writer: *std.Io.Writer, data: T) Errors!void {
    if (content_type == null) {
        return Json.serialize(T, writer, data);
    }

    if (std.mem.eql(u8, content_type.?, "*/*")) {
        return Json.serialize(T, writer, data);
    }

    var best_quality: f32 = 0.0;
    var best_content_type: ?ContentType = null;

    var it = std.mem.tokenizeAny(u8, content_type.?, " ,");
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
                        if (ContentType.fromString(ct)) |ct_enum| {
                            best_quality = quality;
                            best_content_type = ct_enum;
                        }
                    }
                }
            }
        } else {
            // If there's no semicolon, the entire token is the content type with a default quality of 1.0
            const trimmed_ct = std.mem.trim(u8, token, &std.ascii.whitespace);
            if (ContentType.fromString(trimmed_ct)) |ct| {
                return toContentType(T, ct, writer, data);
            }
        }
    }

    return toContentType(T, best_content_type orelse ContentType.json, writer, data);
}

pub fn toContentType(comptime T: type, content_type: ContentType, writer: *std.Io.Writer, data: T) Errors!void {
    switch (content_type) {
        .json => return Json.serialize(T, writer, data),
        else => return Errors.UnsupportedContentType,
    }
}
