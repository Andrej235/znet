const Http = @import("./http.zig").HttpResponse;

pub fn Response(TBody: type) type {
    return union(enum) {
        http: Http(TBody),
    };
}
