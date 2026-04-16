const http = @import("../http/http.zig");
const RouteMethodBitmap = @import("../router/route_method_bitmap.zig").RouteMethodBitmap;

pub fn HttpResponse(TBody: type) type {
    return struct {
        version: http.Version,
        status_code: http.StatusCode,

        connection: http.Connection,

        content_type: http.ResponseContentType,
        body: TBody,

        cache_config: ?http.CacheConfig = null,
        allowed_methods: ?RouteMethodBitmap = null,

        pub fn init(status_code: http.StatusCode, connection: http.Connection, accepts: ?[]const u8, body: TBody) HttpResponse(TBody) {
            const response_content_type = if (accepts) |a| (http.ResponseContentType.fromAcceptHeader(a) orelse http.ResponseContentType.json) else http.ResponseContentType.json;

            return @This(){
                .version = http.Version.http11,
                .status_code = status_code,

                .connection = connection,

                .content_type = response_content_type,
                .body = body,
            };
        }

        pub fn withCache(self: HttpResponse(TBody), cache_config: http.CacheConfig) HttpResponse(TBody) {
            var copy = self;
            copy.cache_config = cache_config;
            return copy;
        }

        pub fn withAllowedMethods(self: HttpResponse(TBody), allowed_methods: RouteMethodBitmap) HttpResponse(TBody) {
            var copy = self;
            copy.allowed_methods = allowed_methods;
            return copy;
        }
    };
}
