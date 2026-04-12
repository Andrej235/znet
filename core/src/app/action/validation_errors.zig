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

pub const ValidationErrorsResponse = struct {
    message: []const u8,
    details: ?[]const ErrorDetails,
    truncated: bool,
};

pub const ValidationErrors = struct {
    message_buffer: [1024]u8 = undefined, // todo: make configurable

    consumed_bytes: usize = 0,
    errors_count: usize = 0,

    message: []const u8 = undefined,
    details: [16]ErrorDetails = undefined, // todo: make configurable
    truncated: bool = false, // indicates that there were more errors that are not included in the details

    pub fn init(message: []const u8) error{MessageTooLong}!ValidationErrors {
        var errors = ValidationErrors{
            .consumed_bytes = message.len,
        };

        if (message.len > errors.message_buffer.len) {
            return error.MessageTooLong;
        }

        @memcpy(errors.message_buffer[0..message.len], message);
        errors.message = errors.message_buffer[0..message.len];
        errors.consumed_bytes = message.len;

        return errors;
    }

    /// Returns true if the error was added, false if there was no more space to add it
    /// If adding fails, truncated will be set to true to indicate that there were more errors that are not included in the details
    pub fn add(self: *ValidationErrors, source: ErrorSource, field: ?[]const u8, issue: []const u8) bool {
        const needed_space = if (field) |f| f.len + issue.len else issue.len;
        if (self.errors_count >= self.details.len or self.consumed_bytes + needed_space > self.message_buffer.len) {
            self.truncated = true;
            return false;
        }

        if (field) |f| {
            @memcpy(self.message_buffer[self.consumed_bytes .. self.consumed_bytes + f.len], f);
            @memcpy(self.message_buffer[self.consumed_bytes + f.len .. self.consumed_bytes + needed_space], issue);
        } else {
            @memcpy(self.message_buffer[self.consumed_bytes .. self.consumed_bytes + issue.len], issue);
        }

        self.details[self.errors_count] = .{
            .source = source,
            .field = if (field) |f| self.message_buffer[self.consumed_bytes .. self.consumed_bytes + f.len] else null,
            .issue = if (field) |f| self.message_buffer[self.consumed_bytes + f.len .. self.consumed_bytes + needed_space] else self.message_buffer[self.consumed_bytes .. self.consumed_bytes + issue.len],
        };

        self.consumed_bytes += needed_space;
        self.errors_count += 1;
        return true;
    }

    pub fn toResponseBody(self: *const ValidationErrors) ValidationErrorsResponse {
        return .{
            .message = self.message,
            .details = if (self.errors_count == 0) null else self.details[0..self.errors_count],
            .truncated = self.truncated,
        };
    }
};
