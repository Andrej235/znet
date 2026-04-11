const StatusCode = @import("../http/status_code.zig").StatusCode;

const ResponseContentType = @import("../requests/http.zig").ResponseContentType;
const HttpVersion = @import("../requests/http.zig").HttpVersion;

pub fn HttpResponse(TBody: type) type {
    return struct {
        version: HttpVersion,
        status_code: StatusCode,
        content_type: ResponseContentType,
        body: TBody,

        pub fn init(status_code: StatusCode, accepts: ?[]const u8, body: TBody) HttpResponse(TBody) {
            const response_content_type = if (accepts) |a| (ResponseContentType.fromAcceptHeader(a) orelse ResponseContentType.json) else ResponseContentType.json;

            return @This(){
                .version = HttpVersion.http11,
                .status_code = status_code,
                .content_type = response_content_type,
                .body = body,
            };
        }
    };
}
