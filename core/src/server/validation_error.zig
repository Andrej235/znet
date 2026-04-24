const http = @import("../http/http.zig");

pub const ValidationError = struct {
    error_code: http.StatusCode,
    message: []const u8,
};
