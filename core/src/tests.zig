test "Run all tests" {
    _ = @import("serialization/tests.zig");
    _ = @import("app/host/parse_host.zig");
}
