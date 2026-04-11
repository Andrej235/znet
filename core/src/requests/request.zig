const HttpRequest = @import("http.zig").HttpRequest;

pub const Request = union(enum) {
    http: HttpRequest,
};