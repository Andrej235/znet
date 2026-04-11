const http = @import("../http/http.zig");

pub fn HttpResponse(TBody: type) type {
    return struct {
        version: http.Version,
        status_code: http.StatusCode,

        connection: http.Connection,

        content_type: http.ResponseContentType,
        body: TBody,

        cache_config: ?http.CacheConfig = null,

        pub fn init(status_code: http.StatusCode, connection: http.Connection, accepts: ?[]const u8, body: TBody) HttpResponse(TBody) {
            const response_content_type = if (accepts) |a| (http.ResponseContentType.fromAcceptHeader(a) orelse http.ResponseContentType.json) else http.ResponseContentType.json;

            return @This(){
                .version = http.Version.http11,
                .status_code = status_code,

                .connection = connection,

                .content_type = response_content_type,
                .body = body,

                .cache_config = null,
            };
        }
    };
}
