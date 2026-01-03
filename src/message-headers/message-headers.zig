pub const MessageHeaders = union(enum(u8)) {
    Request: @import("request-headers.zig").RequestHeaders,
    Response: @import("response-headers.zig").ResponseHeader,
    Broadcast: @import("broadcast-headers.zig").BroadcastHeaders,
};
