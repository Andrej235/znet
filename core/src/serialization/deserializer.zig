const std = @import("std");
const ContentType = @import("../http/http.zig").RequestContentType;

pub const Json = @import("json/deserializer.zig").Deserializer;
pub const FormUrlEncoded = @import("form_url_encoded/deserializer.zig").Deserializer;

pub const DeserializerErrors = @import("./errors.zig").DeserializationErrors;
pub const Errors = DeserializerErrors || error{
    UnsupportedContentType,
};

pub fn fromContentType(comptime T: type, content_type: ?ContentType, allocator: std.mem.Allocator, reader: *std.Io.Reader) Errors!T {
    switch (content_type orelse .octet_stream) {
        .json => return Json.deserialize(allocator, reader, T),
        .form_url_encoded => return FormUrlEncoded.deserialize(allocator, reader, T),
        else => return Errors.UnsupportedContentType,
    }
}
