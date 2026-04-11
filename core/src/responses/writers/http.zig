const std = @import("std");

const HttpResponse = @import("../http.zig").HttpResponse;

const StatusCode = @import("../../http/status_code.zig").StatusCode;
const HttpVersion = @import("../../requests/http.zig").HttpVersion;
const ContentType = @import("../../requests/http.zig").ResponseContentType;

const Serializer = @import("../../serialization/serializer.zig");

pub fn HttpResponseWriter(comptime TBody: type) type {
    return struct {
        const Self = @This();
        const Response = HttpResponse(TBody);

        bytes_written: usize,
        writer: *std.Io.Writer,

        pub fn write(response: Response, writer: *std.Io.Writer) !usize {
            var self = Self{
                .bytes_written = 0,
                .writer = writer,
            };

            try self.writeStatusLine(response.version, response.status_code);
            try self.writeBody(response.body, response.content_type);

            return self.bytes_written;
        }

        fn writeStatusLine(self: *Self, version: HttpVersion, status_code: StatusCode) !void {
            const version_str = version.toString();
            const status_code_str = status_code.toString();

            try self.writer.writeAll(version_str);
            try self.writer.writeByte(' ');
            try self.writer.writeAll(status_code_str);
            try self.writer.writeAll("\r\n");

            self.bytes_written += version_str.len + 1 + status_code_str.len + 2;
        }

        /// Writes headers needed for the response body, ends headers with an additional CRLF, and writes the body itself
        /// This should only be called after writing all other headers
        /// If TBody is void, this function just writes the CRLF to end the headers
        fn writeBody(self: *Self, body: TBody, content_type: ContentType) !void {
            const content_type_header = "Content-Type: ";
            const content_type_str = content_type.toStringUtf8();

            const content_length = try Serializer.countForContentType(TBody, content_type, body);
            const content_length_header = "Content-Length: ";

            var content_length_str_buffer: [64]u8 = undefined;
            const content_length_str = std.fmt.bufPrint(content_length_str_buffer[0..], "{}", .{content_length}) catch {
                return error.ContentLengthTooLarge;
            };

            try self.writer.writeAll(content_type_header);
            try self.writer.writeAll(content_type_str);
            try self.writer.writeAll("\r\n");
            try self.writer.writeAll(content_length_header);
            try self.writer.writeAll(content_length_str);
            try self.writer.writeAll("\r\n\r\n");

            try Serializer.toContentType(TBody, content_type, self.writer, body);

            self.bytes_written += content_type_header.len + content_type_str.len + 2 + content_length_header.len + content_length_str.len + 4 + content_length;
        }
    };
}
