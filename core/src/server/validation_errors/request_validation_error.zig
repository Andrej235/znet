const http = @import("../../http/http.zig");

/// Represents a validation error that occurs during the processing of an HTTP request.
pub const RequestValidationError = struct {
    error_code: http.StatusCode,
    message: []const u8,
};
