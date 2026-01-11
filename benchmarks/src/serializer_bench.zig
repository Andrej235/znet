const std = @import("std");
const zbench = @import("zbench");
const znet = @import("znet");

// ---------------- Scalars ----------------

const u8_val: u8 = 42;
const u64_val: u64 = 0xdeadbeefdeadbeef;
const i64_val: i64 = -123456789;
const f32_val: f32 = 3.14159;
const f64_val: f64 = 2.718281828459045;
const bool_val: bool = true;

// ---------------- Arrays & slices ----------------

const small_array: [8]u32 = [_]u32{1} ** 8;
const medium_array: [64]u16 = [_]u16{2} ** 64;
const large_array: [1024]u8 = [_]u8{0} ** 1024;

const slice_backing: [128]u32 = [_]u32{5} ** 128;
const slice: []const u32 = slice_backing[0..];

// ---------------- Structs ----------------

const SimpleStruct = struct {
    a: u32,
    b: i64,
    c: bool,
};

const simple_struct = SimpleStruct{
    .a = 1,
    .b = -2,
    .c = true,
};

const NestedStruct = struct {
    header: SimpleStruct,
    values: [16]u16,
    ratio: f32,
};

const nested_struct = NestedStruct{
    .header = simple_struct,
    .values = [_]u16{9} ** 16,
    .ratio = 0.75,
};

// ---------------- Optionals ----------------

const optional_int: ?u32 = 1234;
const optional_none: ?u32 = null;

// ---------------- Pointers ----------------

var pointed_value: u64 = 9999;
const pointer_to_value: *const u64 = &pointed_value;
const optional_pointer: ?*const u64 = &pointed_value;

// ---------------- Slices inside structs ----------------

const SliceStruct = struct {
    len: usize,
    data: []const u32,
};

const slice_struct = SliceStruct{
    .len = slice.len,
    .data = slice,
};

// ---------------- Tagged union ----------------

const TaggedUnion = union(enum) {
    int: i64,
    float: f64,
    bytes: [16]u8,
};

const tagged_int = TaggedUnion{ .int = 42 };
const tagged_float = TaggedUnion{ .float = 1.234 };
const tagged_bytes = TaggedUnion{ .bytes = [_]u8{7} ** 16 };

// ---------------- Deep structure ----------------

const DeepStruct = struct {
    id: u32,
    payload: TaggedUnion,
    meta: SliceStruct,
    flag: bool,
    name: []const u8,
};

const deep_struct = DeepStruct{
    .id = 77,
    .payload = tagged_bytes,
    .meta = slice_struct,
    .flag = true,
    .name = &([1]u8{'A'} ** 1024),
};

// =======================================================

pub fn main() !void {
    var stdout = std.fs.File.stdout().writerStreaming(&.{});
    const stdout_writer = &stdout.interface;

    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    // Scalars
    try bench.add("u8", benchU8, .{});
    try bench.add("u64", benchU64, .{});
    try bench.add("i64", benchI64, .{});
    try bench.add("f32", benchF32, .{});
    try bench.add("f64", benchF64, .{});
    try bench.add("bool", benchBool, .{});

    // Arrays & slices
    try bench.add("Small array", benchSmallArray, .{});
    try bench.add("Medium array", benchMediumArray, .{});
    try bench.add("Large array", benchLargeArray, .{});
    try bench.add("Slice", benchSlice, .{});

    // Structs
    try bench.add("Simple struct", benchSimpleStruct, .{});
    try bench.add("Nested struct", benchNestedStruct, .{});

    // Optionals
    try bench.add("Optional value (some)", benchOptionalSome, .{});
    try bench.add("Optional value (none)", benchOptionalNone, .{});

    // Pointers
    try bench.add("Pointer", benchPointer, .{});
    try bench.add("Optional pointer", benchOptionalPointer, .{});

    // Advanced
    try bench.add("Slice struct", benchSliceStruct, .{});
    try bench.add("Tagged union (int)", benchTaggedInt, .{});
    try bench.add("Tagged union (float)", benchTaggedFloat, .{});
    try bench.add("Tagged union (bytes)", benchTaggedBytes, .{});
    try bench.add("Deep struct", benchDeepStruct, .{});

    try stdout_writer.writeAll("\n");
    try bench.run(stdout_writer);
}

// ================= Bench functions =================

var write_buffer: [8192]u8 = undefined;

inline fn ser(comptime T: type, v: T) void {
    var writer = std.io.Writer.fixed(&write_buffer);
    _ = znet.Serializer.serialize(T, &writer, v) catch unreachable;
}

// Scalars
fn benchU8(_: std.mem.Allocator) void {
    ser(@TypeOf(u8_val), u8_val);
}
fn benchU64(_: std.mem.Allocator) void {
    ser(@TypeOf(u64_val), u64_val);
}
fn benchI64(_: std.mem.Allocator) void {
    ser(@TypeOf(i64_val), i64_val);
}
fn benchF32(_: std.mem.Allocator) void {
    ser(@TypeOf(f32_val), f32_val);
}
fn benchF64(_: std.mem.Allocator) void {
    ser(@TypeOf(f64_val), f64_val);
}
fn benchBool(_: std.mem.Allocator) void {
    ser(@TypeOf(bool_val), bool_val);
}

// Arrays & slices
fn benchSmallArray(_: std.mem.Allocator) void {
    ser(@TypeOf(small_array), small_array);
}
fn benchMediumArray(_: std.mem.Allocator) void {
    ser(@TypeOf(medium_array), medium_array);
}
fn benchLargeArray(_: std.mem.Allocator) void {
    ser(@TypeOf(large_array), large_array);
}
fn benchSlice(_: std.mem.Allocator) void {
    ser(@TypeOf(slice), slice);
}

// Structs
fn benchSimpleStruct(_: std.mem.Allocator) void {
    ser(SimpleStruct, simple_struct);
}
fn benchNestedStruct(_: std.mem.Allocator) void {
    ser(NestedStruct, nested_struct);
}

// Optionals
fn benchOptionalSome(_: std.mem.Allocator) void {
    ser(@TypeOf(optional_int), optional_int);
}
fn benchOptionalNone(_: std.mem.Allocator) void {
    ser(@TypeOf(optional_none), optional_none);
}

// Pointers
fn benchPointer(_: std.mem.Allocator) void {
    ser(@TypeOf(pointer_to_value), pointer_to_value);
}
fn benchOptionalPointer(_: std.mem.Allocator) void {
    ser(@TypeOf(optional_pointer), optional_pointer);
}

// Advanced
fn benchSliceStruct(_: std.mem.Allocator) void {
    ser(SliceStruct, slice_struct);
}
fn benchTaggedInt(_: std.mem.Allocator) void {
    ser(TaggedUnion, tagged_int);
}
fn benchTaggedFloat(_: std.mem.Allocator) void {
    ser(TaggedUnion, tagged_float);
}
fn benchTaggedBytes(_: std.mem.Allocator) void {
    ser(TaggedUnion, tagged_bytes);
}
fn benchDeepStruct(_: std.mem.Allocator) void {
    ser(DeepStruct, deep_struct);
}
