pub const StatusCode = enum(u16) {
    ok = 200,
    created = 201,
    no_content = 204,
    bad_request = 400,
    not_found = 404,
    method_not_allowed = 405,
    internal_server_error = 500,

    pub fn toReasonString(self: StatusCode) []const u8 {
        return switch (self) {
            .ok => "OK",
            .created => "Created",
            .no_content => "No Content",
            .bad_request => "Bad Request",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .internal_server_error => "Internal Server Error",
        };
    }

    pub fn toString(self: StatusCode) []const u8 {
        return switch (self) {
            .ok => "200 OK",
            .created => "201 Created",
            .no_content => "204 No Content",
            .bad_request => "400 Bad Request",
            .not_found => "404 Not Found",
            .method_not_allowed => "405 Method Not Allowed",
            .internal_server_error => "500 Internal Server Error",
        };
    }
};
