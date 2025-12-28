const zNet = @import("zNet");
const std = @import("std");
const testing = std.testing;

test "server start" {
    const server = zNet.Server(.{ .contracts = &.{TestContract} }).start(std.heap.page_allocator);

    var input_buffer: [1024]u8 = undefined;
    var input_reader: std.Io.Reader = .fixed(&input_buffer);
    var input_writer: std.Io.Writer = .fixed(&input_buffer);

    var output_buffer: [1024]u8 = undefined;
    var output_reader: std.Io.Reader = .fixed(&output_buffer);
    var output_writer: std.Io.Writer = .fixed(&output_buffer);

    try zNet.serializeMessageHeader(&input_writer, .{
        .Request = .{
            .version = 1,
            .msg_type = .Request,
            .request_id = 1,
            .contract_id = 0,
            .method_id = 1,
            .payload_len = 0,
        },
    });

    try zNet.Serializer.serialize(u8, &input_writer, @as(u8, 3));
    try zNet.Serializer.serialize(u16, &input_writer, @as(u16, 5));

    server.call(&input_reader, &output_writer) catch |err| {
        std.debug.print("Error calling handler: {}\n", .{err});
    };

    var deserializer = zNet.Deserializer.init(std.heap.page_allocator);

    const headers = try zNet.deserializeMessageHeader(&output_reader);
    try testing.expect(headers == .Response);
    try testing.expectEqual(headers.Response.request_id, 1);

    const result = try deserializer.deserialize(&output_reader, @typeInfo(@TypeOf(TestContract.anotherFunction)).@"fn".return_type.?);
    try testing.expectEqual(result, 8);
}

const TestContract = struct {
    pub fn testFunction(x: i32) !i32 {
        return 123 * x;
    }

    pub fn anotherFunction(x: u8, y: u16) i32 {
        // std.debug.print("{}, {}\n", .{ x, y });
        return @as(i32, x) + @as(i32, y);
    }
};
