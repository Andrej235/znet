pub const MessageHeader = union(enum(u8)) {
    Request: @import("request-header.zig").RequestHeaders,
    Response: @import("response-header.zig").ResponseHeader,
};
