// todo:? serializers should return the number of bytes written

const std = @import("std");
const ContentType = @import("../server/requests/http.zig").ResponseContentType;

pub const Json = @import("json/serializer.zig").Serializer;

pub const Errors = @import("./errors.zig").SerializationErrors || error{
    UnsupportedContentType,
};

pub fn toContentType(comptime T: type, content_type: ContentType, writer: *std.Io.Writer, data: T) Errors!void {
    switch (content_type) {
        .json => return Json.serialize(T, writer, data),
        else => return Errors.UnsupportedContentType,
    }
}

pub fn countForContentType(comptime T: type, content_type: ContentType, data: T) Errors!usize {
    switch (content_type) {
        .json => return Json.count(T, data),
        else => return Errors.UnsupportedContentType,
    }
}
