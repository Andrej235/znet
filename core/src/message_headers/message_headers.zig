pub const RequestHeaders = @import("request_headers.zig").RequestHeaders;
pub const ResponseHeaders = @import("response_headers.zig").ResponseHeaders;
pub const Type = @import("../message_headers/message_type.zig").MessageType;

pub const MessageHeaders = union(Type) {
    Request: RequestHeaders,
    Response: ResponseHeaders,
};

pub const HeadersByteSize = struct {
    pub const Request = @import("request_headers.zig").ByteSize;
    pub const Response = @import("response_headers.zig").ByteSize;
};

pub const HeadersBitSize = struct {
    pub const Request = @import("request_headers.zig").BitSize;
    pub const Response = @import("response_headers.zig").BitSize;
};
