pub const ErrorSource = enum {
    path,
    query,
    body,
};

pub const ErrorDetails = struct {
    source: ErrorSource,
    field: ?[]const u8,
    issue: []const u8,
};

pub const DataValidationErrorResponse = struct {
    message: []const u8,
    details: []const ErrorDetails,
    truncated: bool,
};

/// Used for accumulating validation errors during request processing.
/// Meant for errors caused by parsing the request body, query, or path parameters.
pub fn DataValidationError(comptime max_details_count: usize) type {
    if (max_details_count == 0) {
        @compileError("max_details_count must be greater than 0");
    }

    return struct {
        const Self = @This();

        message: []const u8 = undefined,
        truncated: bool = false, // indicates that there were more errors that are not included in the details

        errors_count: usize = 0,
        details: [max_details_count]ErrorDetails = undefined,

        /// Initializes a new DataValidationError with the given message. The details array will be empty and ready to accumulate errors.
        /// Message must be a compile-time constant string, as it is stored in the struct without copying.
        pub fn init(comptime message: []const u8) Self {
            return Self{
                .message = message,
            };
        }

        /// Tries to add a new error to the details array. If the array is full, it will set truncated to true and return false to indicate that the error was not added.
        /// All parameters must be compile-time constants, as they are stored in the struct without copying.
        pub fn add(self: *Self, comptime source: ErrorSource, comptime field: ?[]const u8, comptime issue: []const u8) bool {
            if (self.errors_count >= self.details.len) {
                self.truncated = true;
                return false;
            }

            self.details[self.errors_count] = .{
                .source = source,
                .field = field,
                .issue = issue,
            };

            self.errors_count += 1;
            return true;
        }

        pub fn toResponseBody(self: *const Self) DataValidationErrorResponse {
            return .{
                .message = self.message,
                .details = self.details[0..self.errors_count],
                .truncated = self.truncated,
            };
        }
    };
}
