pub const MessageHeader = union(enum(u8)) {
    Request: @import("request-headers.zig").RequestHeaders,
    Response: @import("response-headers.zig").ResponseHeader,
};
