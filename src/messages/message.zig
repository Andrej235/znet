const MessageHeader = union(enum(u8)) {
    ResponseHeader: @import("response-header.zig").ResponseHeader,
    RequestHeader: @import("request-header.zig").RequestHeader,
};

pub const Message = struct {
    header: MessageHeader,
    payload: []const u8,
};
