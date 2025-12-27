pub const MessageHeader = union(enum(u8)) {
    Request: @import("request-header.zig").RequestHeader,
    Response: @import("response-header.zig").ResponseHeader,
};
