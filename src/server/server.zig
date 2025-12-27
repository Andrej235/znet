const std = @import("std");
const ServerOptions = @import("server-options.zig").ServerOptions;
const HandlerFn = @import("../handler-fn/handler-fn.zig").HandlerFn;
const createHandlerFn = @import("../handler-fn/create-handler-fn.zig").createHandlerFn;
const deserializeMessageHeader = @import("../message-headers/deserialize-message-header.zig").deserializeMessageHeader;

pub fn Server(comptime options: ServerOptions) type {
    return struct {
        const Self = @This();
        const call_tables = create_call_table(options);

        pub fn start(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
            };
        }

        pub fn call(self: *const Self, reader: std.io.AnyReader, writer: std.io.AnyWriter) !void {
            const header = try deserializeMessageHeader(reader);

            switch (header) {
                .Request => |req_header| {
                    const handler = call_tables[req_header.contract_id][req_header.method_id];
                    try handler(self.allocator, reader, writer);
                },
                .Response => {
                    return error.UnexpectedResponseHeader;
                },
            }
        }

        allocator: std.mem.Allocator,
    };
}

pub fn create_call_table(comptime options: ServerOptions) []const []const HandlerFn {
    comptime {
        var call_table: []const []const HandlerFn = &.{};
        for (options.contracts) |contract| {
            var handlers: []const HandlerFn = &.{};

            const info = @typeInfo(contract);
            if (info != .@"struct") continue;
            const decls = info.@"struct".decls;

            for (decls) |decl| {
                const fn_name = decl.name;
                const fn_impl = @field(contract, fn_name);

                if (@typeInfo(@TypeOf(fn_impl)) != .@"fn") continue;
                handlers = handlers ++ @as([]const HandlerFn, &.{createHandlerFn(fn_impl)});
            }
            call_table = call_table ++ @as([]const []const HandlerFn, &.{handlers});
        }

        return call_table;
    }
}
