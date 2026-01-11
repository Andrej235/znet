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
const large_string: []const u8 = &([_]u8{0} ** 1024);

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

// Prep
var buffer: [32 * 1024]u8 = undefined; // 32 kB
var writer = std.io.Writer.fixed(&buffer);
var current_offset: usize = 0;

var serialized_u8_val: []const u8 = undefined;
var serialized_u64_val: []const u8 = undefined;
var serialized_i64_val: []const u8 = undefined;
var serialized_f32_val: []const u8 = undefined;
var serialized_f64_val: []const u8 = undefined;
var serialized_bool_val: []const u8 = undefined;
var serialized_small_array: []const u8 = undefined;
var serialized_medium_array: []const u8 = undefined;
var serialized_large_array: []const u8 = undefined;
var serialized_slice: []const u8 = undefined;
var serialized_large_string: []const u8 = undefined;
var serialized_simple_struct: []const u8 = undefined;
var serialized_nested_struct: []const u8 = undefined;
var serialized_optional_int: []const u8 = undefined;
var serialized_optional_none: []const u8 = undefined;
var serialized_pointer_to_value: []const u8 = undefined;
var serialized_optional_pointer: []const u8 = undefined;
var serialized_slice_struct: []const u8 = undefined;
var serialized_tagged_int: []const u8 = undefined;
var serialized_tagged_float: []const u8 = undefined;
var serialized_tagged_bytes: []const u8 = undefined;
var serialized_deep_struct: []const u8 = undefined;

var arena: std.heap.ArenaAllocator = undefined;
var deserializer: znet.Deserializer = undefined;

fn serialize(comptime value: anytype) []const u8 {
    znet.Serializer.serialize(@TypeOf(value), &writer, value) catch unreachable;
    const payload_len = znet.CountingSerializer.serialize(@TypeOf(value), value) catch unreachable;

    if (current_offset + payload_len > buffer.len) unreachable;
    const data = buffer[current_offset .. current_offset + payload_len];
    current_offset += payload_len;

    return data;
}

pub fn main() !void {
    var stdout = std.fs.File.stdout().writerStreaming(&.{});
    const stdout_writer = &stdout.interface;

    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    deserializer = znet.Deserializer.init(arena.allocator());

    serialized_u8_val = serialize(u8_val);
    serialized_u64_val = serialize(u64_val);
    serialized_i64_val = serialize(i64_val);
    serialized_f32_val = serialize(f32_val);
    serialized_f64_val = serialize(f64_val);
    serialized_bool_val = serialize(bool_val);
    serialized_small_array = serialize(small_array);
    serialized_medium_array = serialize(medium_array);
    serialized_large_array = serialize(large_array);
    serialized_slice = serialize(slice);
    serialized_large_string = serialize(large_string);
    serialized_simple_struct = serialize(simple_struct);
    serialized_nested_struct = serialize(nested_struct);
    serialized_optional_int = serialize(optional_int);
    serialized_optional_none = serialize(optional_none);
    serialized_pointer_to_value = serialize(pointer_to_value);
    serialized_optional_pointer = serialize(optional_pointer);
    serialized_slice_struct = serialize(slice_struct);
    serialized_tagged_int = serialize(tagged_int);
    serialized_tagged_float = serialize(tagged_float);
    serialized_tagged_bytes = serialize(tagged_bytes);
    serialized_deep_struct = serialize(deep_struct);

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
    try bench.add("Large String", benchLargeString, .{});

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

inline fn deser(comptime T: type, buf: []const u8) void {
    _ = arena.reset(.retain_capacity);

    var reader = std.io.Reader.fixed(buf);
    const res = deserializer.deserialize(&reader, T) catch unreachable;
    deserializer.destroy(res) catch unreachable;
}

// Scalars
fn benchU8(_: std.mem.Allocator) void {
    deser(@TypeOf(u8_val), serialized_u8_val);
}
fn benchU64(_: std.mem.Allocator) void {
    deser(@TypeOf(u64_val), serialized_u64_val);
}
fn benchI64(_: std.mem.Allocator) void {
    deser(@TypeOf(i64_val), serialized_i64_val);
}
fn benchF32(_: std.mem.Allocator) void {
    deser(@TypeOf(f32_val), serialized_f32_val);
}
fn benchF64(_: std.mem.Allocator) void {
    deser(@TypeOf(f64_val), serialized_f64_val);
}
fn benchBool(_: std.mem.Allocator) void {
    deser(@TypeOf(bool_val), serialized_bool_val);
}

// Arrays & slices
fn benchSmallArray(_: std.mem.Allocator) void {
    deser(@TypeOf(small_array), serialized_small_array);
}
fn benchMediumArray(_: std.mem.Allocator) void {
    deser(@TypeOf(medium_array), serialized_medium_array);
}
fn benchLargeArray(_: std.mem.Allocator) void {
    deser(@TypeOf(large_array), serialized_large_array);
}
fn benchSlice(_: std.mem.Allocator) void {
    deser(@TypeOf(slice), serialized_slice);
}
fn benchLargeString(_: std.mem.Allocator) void {
    deser(@TypeOf(large_string), serialized_large_string);
}

// Structs
fn benchSimpleStruct(_: std.mem.Allocator) void {
    deser(SimpleStruct, serialized_simple_struct);
}
fn benchNestedStruct(_: std.mem.Allocator) void {
    deser(NestedStruct, serialized_nested_struct);
}

// Optionals
fn benchOptionalSome(_: std.mem.Allocator) void {
    deser(@TypeOf(optional_int), serialized_optional_int);
}
fn benchOptionalNone(_: std.mem.Allocator) void {
    deser(@TypeOf(optional_none), serialized_optional_none);
}

// Pointers
fn benchPointer(_: std.mem.Allocator) void {
    deser(@TypeOf(pointer_to_value), serialized_pointer_to_value);
}
fn benchOptionalPointer(_: std.mem.Allocator) void {
    deser(@TypeOf(optional_pointer), serialized_optional_pointer);
}

// Advanced
fn benchSliceStruct(_: std.mem.Allocator) void {
    deser(SliceStruct, serialized_slice_struct);
}
fn benchTaggedInt(_: std.mem.Allocator) void {
    deser(TaggedUnion, serialized_tagged_int);
}
fn benchTaggedFloat(_: std.mem.Allocator) void {
    deser(TaggedUnion, serialized_tagged_float);
}
fn benchTaggedBytes(_: std.mem.Allocator) void {
    deser(TaggedUnion, serialized_tagged_bytes);
}
fn benchDeepStruct(_: std.mem.Allocator) void {
    deser(DeepStruct, serialized_deep_struct);
}
