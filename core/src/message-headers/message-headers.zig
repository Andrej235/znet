pub const RequestHeaders = @import("request-headers.zig").RequestHeaders;
pub const ResponseHeaders = @import("response-headers.zig").ResponseHeaders;
pub const BroadcastHeaders = @import("broadcast-headers.zig").BroadcastHeaders;
pub const Type = @import("../message-headers/message-type.zig").MessageType;

pub const MessageHeaders = union(Type) {
    Request: RequestHeaders,
    Response: ResponseHeaders,
    Broadcast: BroadcastHeaders,
};

pub const HeadersByteSize = struct {
    pub const Request = @import("request-headers.zig").ByteSize;
    pub const Response = @import("response-headers.zig").ByteSize;
    pub const Broadcast = @import("broadcast-headers.zig").ByteSize;
};

pub const HeadersBitSize = struct {
    pub const Request = @import("request-headers.zig").BitSize;
    pub const Response = @import("response-headers.zig").BitSize;
    pub const Broadcast = @import("broadcast-headers.zig").BitSize;
};
