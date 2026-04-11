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
            try self.writeDateHeader();
            try self.writeServerHeader();
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

        fn writeDateHeader(self: *Self) !void {
            const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(std.time.timestamp()) };
            const seconds_since_midnight = seconds.getDaySeconds();

            const day = seconds.getEpochDay();
            const year_day = day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();

            const day_of_week_str = switch (day.day % 7) {
                0 => "Thu", // Jan 1, 1970 was a Thursday, so day 0 is a Thursday
                1 => "Fri",
                2 => "Sat",
                3 => "Sun",
                4 => "Mon",
                5 => "Tue",
                6 => "Wed",
                else => unreachable,
            };

            const month_str = switch (month_day.month) {
                .jan => "Jan",
                .feb => "Feb",
                .mar => "Mar",
                .apr => "Apr",
                .may => "May",
                .jun => "Jun",
                .jul => "Jul",
                .aug => "Aug",
                .sep => "Sep",
                .oct => "Oct",
                .nov => "Nov",
                .dec => "Dec",
            };

            const header_name = "Date: ";
            try self.writer.writeAll(header_name);

            try self.writer.print("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT\r\n", .{
                day_of_week_str,
                month_day.day_index + 1,
                month_str,
                year_day.year,
                seconds_since_midnight.getHoursIntoDay(),
                seconds_since_midnight.getMinutesIntoHour(),
                seconds_since_midnight.getSecondsIntoMinute(),
            });

            self.bytes_written += comptime (header_name.len + 29 + 2); // the date header is always 29 bytes long + 2 for CRLF
        }

        fn writeServerHeader(self: *Self) !void {
            const header = "Server: znet/0.1.0\r\n";
            try self.writer.writeAll(header);

            self.bytes_written += header.len;
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
