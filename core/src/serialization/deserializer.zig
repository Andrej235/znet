const std = @import("std");
const ContentType = @import("../server/requests/http.zig").ContentType;

pub const Json = @import("json/deserializer.zig").Deserializer;
pub const FormUrlEncoded = @import("form_url_encoded/deserializer.zig").Deserializer;

pub const Errors = @import("./errors.zig").DeserializationErrors || error{
    UnsupportedContentType,
};

pub fn fromContentType(comptime T: type, content_type: ?ContentType, allocator: std.mem.Allocator, reader: *std.Io.Reader) Errors!T {
    switch (content_type orelse .octet_stream) {
        .json => return Json.deserialize(allocator, reader, T),
        else => return Errors.UnsupportedContentType,
    }
}
