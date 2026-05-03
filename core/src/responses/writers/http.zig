const std = @import("std");
const http = @import("../../http/http.zig");

const HttpResponse = @import("../http.zig").HttpResponse;
const Serializer = @import("../../serialization/serializer.zig");
const RouteMethodBitmap = @import("../../router/route_method_bitmap.zig").RouteMethodBitmap;

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
            try self.writeConnectionHeader(response.connection);
            try self.writeCacheHeaders(response.cache_config);
            try self.writeAllowedMethodsHeader(response.allowed_methods);
            try self.writeBody(response.body, response.content_type);

            return self.bytes_written;
        }

        fn writeStatusLine(self: *Self, version: http.Version, status_code: http.StatusCode) !void {
            const version_str = version.toString();
            const status_code_str = status_code.toString();

            try self.writer.writeAll(version_str);
            try self.writer.writeByte(' ');
            try self.writer.writeAll(status_code_str);
            try self.writer.writeAll("\r\n");

            self.bytes_written += version_str.len + 1 + status_code_str.len + 2;
        }

        fn writeDateHeader(self: *Self) !void {
            const header_name = "Date: ";
            try self.writer.writeAll(header_name);
            try self.writeDate(@intCast(std.time.timestamp()));
            try self.writer.writeAll("\r\n");

            self.bytes_written += comptime (header_name.len + 2); // the date header is always 29 bytes long + 2 for CRLF
        }

        /// Writes a date in the format specified by RFC 7231, e.g. "Sun, 06 Nov 1994 08:49:37 GMT"
        /// Adds 29 to bytes_written, since the date is always 29 bytes long
        fn writeDate(self: *Self, seconds_since_epoch: u64) !void {
            const seconds = std.time.epoch.EpochSeconds{ .secs = seconds_since_epoch };
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

            try self.writer.print("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
                day_of_week_str,
                month_day.day_index + 1,
                month_str,
                year_day.year,
                seconds_since_midnight.getHoursIntoDay(),
                seconds_since_midnight.getMinutesIntoHour(),
                seconds_since_midnight.getSecondsIntoMinute(),
            });

            self.bytes_written += 29; // the date is always 29 bytes long
        }

        fn writeServerHeader(self: *Self) !void {
            const header = "Server: znet/0.1.0\r\n";
            try self.writer.writeAll(header);

            self.bytes_written += header.len;
        }

        fn writeCacheHeaders(self: *Self, cache_config: ?http.CacheConfig) !void {
            if (cache_config) |cfg| {
                if (cfg.mode == .no_store) {
                    const header = "Cache-Control: no-store\r\n";
                    try self.writer.writeAll(header);
                    self.bytes_written += header.len + 2; // +2 for CRLF
                    return;
                }

                const header_name = "Cache-Control: ";
                try self.writer.writeAll(header_name);

                var first_directive = true;
                var directives_written_bytes: usize = 0;

                if (cfg.visibility != .none) {
                    const visibility_str = cfg.visibility.toString();
                    try self.writer.writeAll(visibility_str);

                    directives_written_bytes += visibility_str.len;
                    first_directive = false;
                }

                if (cfg.max_age) |max_age| {
                    if (!first_directive) {
                        try self.writer.writeAll(", ");
                        self.bytes_written += 2;
                    }

                    var buff: [64]u8 = undefined;
                    const max_age_str = std.fmt.bufPrint(buff[0..], "max-age={d}", .{max_age}) catch {
                        return error.MaxAgeTooLarge;
                    };

                    try self.writer.writeAll(max_age_str);
                    directives_written_bytes += max_age_str.len;
                    first_directive = false;
                }

                if (cfg.s_maxage) |s_maxage| {
                    if (!first_directive) {
                        try self.writer.writeAll(", ");
                        self.bytes_written += 2;
                    }

                    var buff: [64]u8 = undefined;
                    const s_maxage_str = std.fmt.bufPrint(buff[0..], "s-maxage={d}", .{s_maxage}) catch {
                        return error.SMaxAgeTooLarge;
                    };

                    try self.writer.writeAll(s_maxage_str);
                    directives_written_bytes += s_maxage_str.len;
                    first_directive = false;
                }

                if (cfg.immutable) {
                    if (cfg.max_age == null and cfg.s_maxage == null) {
                        return error.ImmutableMustHaveMaxAge;
                    }

                    if (!first_directive) {
                        try self.writer.writeAll(", ");
                        self.bytes_written += 2;
                    }

                    const immutable_str = "immutable";
                    try self.writer.writeAll(immutable_str);
                    directives_written_bytes += immutable_str.len;
                    first_directive = false;
                }

                if (cfg.no_cache) {
                    if (!first_directive) {
                        try self.writer.writeAll(", ");
                        self.bytes_written += 2;
                    }

                    const no_cache_str = "no-cache";
                    try self.writer.writeAll(no_cache_str);
                    directives_written_bytes += no_cache_str.len;
                    first_directive = false;
                }

                try self.writer.writeAll("\r\n");
                self.bytes_written += header_name.len + directives_written_bytes + 2; // +2 for CRLF

                if (cfg.etag) |etag| {
                    const etag_header_name = "ETag: ";
                    try self.writer.writeAll(etag_header_name);
                    try self.writer.writeByte('"');
                    try self.writer.writeAll(etag);
                    try self.writer.writeByte('"');
                    try self.writer.writeAll("\r\n");

                    self.bytes_written += etag_header_name.len + etag.len + 2 + 2; // +2 for the quotes around the etag, +2 for CRLF
                }

                if (cfg.last_modified) |last_modified| {
                    const last_modified_header_name = "Last-Modified: ";
                    try self.writer.writeAll(last_modified_header_name);
                    try self.writeDate(@intCast(last_modified));
                    try self.writer.writeAll("\r\n");

                    self.bytes_written += last_modified_header_name.len + 2;
                }
            } else {
                // If no cache config is provided, default to no caching
                const header = "Cache-Control: no-store\r\n";
                try self.writer.writeAll(header);
                self.bytes_written += header.len;
            }
        }

        fn writeAllowedMethodsHeader(self: *Self, allowed_methods: ?RouteMethodBitmap) !void {
            if (allowed_methods) |methods| {
                const header_name = "Allow: ";
                try self.writer.writeAll(header_name);

                var first = true;
                var bytes_written_for_methods: usize = 0;
                var it = methods.iterator();

                while (it.next()) |method| {
                    std.debug.print("method: {}\n", .{method});
                    if (!first) {
                        try self.writer.writeAll(", ");
                        self.bytes_written += 2;
                    }

                    const method_str = method.toString();
                    try self.writer.writeAll(method_str);
                    bytes_written_for_methods += method_str.len;

                    first = false;
                }

                try self.writer.writeAll("\r\n");
                self.bytes_written += header_name.len + bytes_written_for_methods + 2; // +2 for CRLF
            }
        }

        fn writeConnectionHeader(self: *Self, connection: http.Connection) !void {
            const header_name = "Connection: ";
            const header_value = connection.toString();

            try self.writer.writeAll(header_name);
            try self.writer.writeAll(header_value);
            try self.writer.writeAll("\r\n");

            self.bytes_written += header_name.len + header_value.len + 2;
        }

        /// Writes headers needed for the response body, ends headers with an additional CRLF, and writes the body itself
        /// This should only be called after writing all other headers
        fn writeBody(self: *Self, body: TBody, content_type: http.ResponseContentType) !void {
            if (comptime @TypeOf(body) == void) {
                const content_length_header_name = "Content-Length: 0\r\n\r\n";
                try self.writer.writeAll(content_length_header_name);
                self.bytes_written += content_length_header_name.len;
                return;
            }

            const content_type_header_name = "Content-Type: ";
            const content_type_str = content_type.toStringUtf8();

            const content_length_header_name = "Content-Length: ";
            const content_length = try Serializer.countForContentType(TBody, content_type, body);

            var content_length_str_buffer: [64]u8 = undefined;
            const content_length_str = std.fmt.bufPrint(content_length_str_buffer[0..], "{}", .{content_length}) catch {
                return error.ContentLengthTooLarge;
            };

            try self.writer.writeAll(content_type_header_name);
            try self.writer.writeAll(content_type_str);
            try self.writer.writeAll("\r\n");
            try self.writer.writeAll(content_length_header_name);
            try self.writer.writeAll(content_length_str);
            try self.writer.writeAll("\r\n\r\n");

            try Serializer.toContentType(TBody, content_type, self.writer, body);

            self.bytes_written += content_type_header_name.len + content_type_str.len + 2 + content_length_header_name.len + content_length_str.len + 4 + content_length;
        }
    };
}
