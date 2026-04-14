test "Run all tests" {
    _ = @import("serialization/tests.zig");
    _ = @import("app/host/parsed_host.zig");
}
