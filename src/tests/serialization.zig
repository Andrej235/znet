const std = @import("std");
const zNet = @import("zNet");
const testing = std.testing;

// var stdout_buffer: [256]u8 = undefined;
//     var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
//     const stdout = &stdout_writer.interface;
//     try stdout.flush();

pub const Vector = struct {
    x: f32,
    y: f32,
    z: f32,
};

const TestStruct = struct {
    a: i32,
    b: []const u8,
    c: Vector,
};

test "int s/d" {
    try testing.expectEqual(12345, roundTrip(comptime_int, 12345));

    try testing.expectEqual(12345, roundTrip(i32, 12345));
    try testing.expectEqual(123456789, roundTrip(i32, 123456789));
    try testing.expectEqual(123456789123, roundTrip(i64, 123456789123));
    try testing.expectEqual(123456789123, roundTrip(i72, 123456789123));
    try testing.expectEqual(123456789123456789, roundTrip(i64, 123456789123456789));
    try testing.expectEqual(123456789123456789123456789123456789123456789123456789123456789, roundTrip(i256, 123456789123456789123456789123456789123456789123456789123456789));

    try testing.expectEqual(12345, roundTrip(u32, 12345));
    try testing.expectEqual(123456789, roundTrip(u32, 123456789));
    try testing.expectEqual(123456789123, roundTrip(u64, 123456789123));
    try testing.expectEqual(123456789123456789, roundTrip(u64, 123456789123456789));
    try testing.expectEqual(123456789123456789123456789123456789123456789123456789123456789, roundTrip(u256, 123456789123456789123456789123456789123456789123456789123456789));
}

test "float s/d" {
    // TODO: comptime float loses precision
    try testing.expectEqual(12345, roundTrip(comptime_float, 12345));
    // try testing.expectEqual(0.000000000001, roundTrip(comptime_float, 0.000000000001));
    // try testing.expectEqual(123.0001231248, roundTrip(comptime_float, 123.0001231248));
    // try testing.expectEqual(12345.6789, roundTrip(comptime_float, 12345));

    try testing.expectEqual(12345, roundTrip(f32, 12345));
    try testing.expectEqual(0.1, roundTrip(f16, 0.1));
    try testing.expectEqual(0.01, roundTrip(f16, 0.01));
    try testing.expectEqual(123.5, roundTrip(f16, 123.5));

    try testing.expectEqual(12345, roundTrip(f32, 12345));
    try testing.expectEqual(1234567, roundTrip(f32, 1234567));
    try testing.expectEqual(0.1, roundTrip(f32, 0.1));
    try testing.expectEqual(0.01, roundTrip(f32, 0.01));
    try testing.expectEqual(0.001, roundTrip(f32, 0.001));
    try testing.expectEqual(0.000000000001, roundTrip(f32, 0.000000000001));
    try testing.expectEqual(123.123456789, roundTrip(f32, 123.123456789));

    try testing.expectEqual(123456789, roundTrip(f64, 123456789));
    try testing.expectEqual(0.1, roundTrip(f64, 0.1));
    try testing.expectEqual(0.01, roundTrip(f64, 0.01));
    try testing.expectEqual(0.000000000001, roundTrip(f64, 0.000000000001));
    try testing.expectEqual(123.123456789, roundTrip(f64, 123.123456789));

    try testing.expectEqual(12345678912345, roundTrip(f128, 12345678912345));
    try testing.expectEqual(0.1, roundTrip(f128, 0.1));
    try testing.expectEqual(0.01, roundTrip(f128, 0.01));
    try testing.expectEqual(0.000000000001, roundTrip(f128, 0.000000000001));
    try testing.expectEqual(123.123456789, roundTrip(f128, 123.123456789));
}

test "struct s/d" {
    try testing.expectEqualDeep(
        Vector{ .x = 123, .y = 12.534, .z = 5934.123 },
        roundTripInfer(Vector{ .x = 123, .y = 12.534, .z = 5934.123 }),
    );

    try testing.expectEqualDeep(
        TestStruct{ .a = 12345, .b = "Hello, Zig!", .c = Vector{ .x = 1.23, .y = 4.56, .z = 7.89 } },
        roundTripInfer(TestStruct{ .a = 12345, .b = "Hello, Zig!", .c = Vector{ .x = 1.23, .y = 4.56, .z = 7.89 } }),
    );
}

var deserializer = zNet.Deserializer.init(std.heap.page_allocator);

fn roundTrip(comptime T: type, comptime data: T) T {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    const writer = fbs.writer();
    const reader = fbs.reader();

    zNet.Serializer.serialize(writer, data) catch unreachable;
    fbs.reset(); // reset position before reading
    const deserialized: T = deserializer.deserialize(reader, T) catch unreachable;
    return deserialized;
}

fn roundTripInfer(comptime data: anytype) @TypeOf(data) {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    const writer = fbs.writer();
    const reader = fbs.reader();

    zNet.Serializer.serialize(writer, data) catch unreachable;
    fbs.reset(); // reset position before reading
    const deserialized: @TypeOf(data) = deserializer.deserialize(reader, @TypeOf(data)) catch unreachable;
    return deserialized;
}
