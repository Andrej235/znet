const std = @import("std");

const Response = @import("./response.zig").Response;

const HttpResponseWriter = @import("./writers/http.zig").HttpResponseWriter;

pub const ResponseWriter = struct {
    pub fn write(comptime TBody: type, response: Response(TBody), writer: *std.Io.Writer) !usize {
        return switch (response) {
            .http => |http| try HttpResponseWriter(TBody).write(http, writer),
        };
    }
};
