pub const RequestHeaders = @import("request_headers.zig").RequestHeaders;
pub const ResponseHeaders = @import("response_headers.zig").ResponseHeaders;
pub const BroadcastHeaders = @import("broadcast_headers.zig").BroadcastHeaders;
pub const Type = @import("../message_headers/message_type.zig").MessageType;

pub const MessageHeaders = union(Type) {
    Request: RequestHeaders,
    Response: ResponseHeaders,
    Broadcast: BroadcastHeaders,
};

pub const HeadersByteSize = struct {
    pub const Request = @import("request_headers.zig").ByteSize;
    pub const Response = @import("response_headers.zig").ByteSize;
    pub const Broadcast = @import("broadcast_headers.zig").ByteSize;
};

pub const HeadersBitSize = struct {
    pub const Request = @import("request_headers.zig").BitSize;
    pub const Response = @import("response_headers.zig").BitSize;
    pub const Broadcast = @import("broadcast_headers.zig").BitSize;
};
