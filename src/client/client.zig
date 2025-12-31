const std = @import("std");
const posix = @import("std").posix;

const ClientOptions = @import("client-options.zig").ClientOptions;

const serializeHeaders = @import("../message-headers/serialize-message-headers.zig").serializeMessageHeaders;
const deserializeMessageHeaders = @import("../message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;
const Serializer = @import("../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../serializer/counting-serializer.zig").Serializer;
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;

const app_version: u8 = @import("../app-version.zig").app_version;

pub fn Client(comptime options: ClientOptions) type {
    return struct {
        const Self = @This();

        contracts: ContractsWrapper(Self, options),
        allocator: std.mem.Allocator,

        send_buffer: []u8,
        receive_buffer: []u8,
        read_pos: usize = 0,
        reader: std.io.Reader,

        socket: posix.socket_t = undefined,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const send_buffer = try allocator.alloc(u8, 1024);
            const receive_buffer = try allocator.alloc(u8, 1024);

            return Self{
                .contracts = createContracts(Self, options),
                .allocator = allocator,

                .send_buffer = send_buffer,
                .receive_buffer = receive_buffer,
                .reader = std.io.Reader.fixed(receive_buffer),
            };
        }

        pub fn connect(self: *Self, address: std.net.Address) !void {
            self.socket = try posix.socket(
                address.any.family,
                posix.SOCK.STREAM,
                posix.IPPROTO.TCP,
            );

            try posix.connect(self.socket, &address.any, address.getOsSockLen());
        }

        pub fn disconnect(_: Self) void {
            std.debug.print("disconnecting... \n", .{});
        }

        pub fn call(self: *Self, comptime contract_id: u16, comptime method_id: u16, args: anytype) anyerror!IdsToReturnType(options, contract_id, method_id) {
            const payload_len = try CountingSerializer.serialize(@TypeOf(args), args);

            var writer: std.Io.Writer = .fixed(self.send_buffer);

            try serializeHeaders(&writer, .{
                .Request = .{
                    .version = app_version,
                    .contract_id = contract_id,
                    .method_id = method_id,
                    .msg_type = .Request,
                    .request_id = 123,
                    .payload_len = payload_len,
                },
            });

            try Serializer.serialize(@TypeOf(args), &writer, args);

            const total_len = payload_len + 14; // header size
            try writeAll(self.socket, self.send_buffer[0..total_len]);

            const response = try self.readMessage(self.socket);
            var reader = std.io.Reader.fixed(response);

            _ = try deserializeMessageHeaders(&reader);
            var deserializer = Deserializer.init(self.allocator);
            const data = try deserializer.deserialize(&reader, IdsToReturnType(options, contract_id, method_id));
            std.debug.print("{any}\n", .{data});

            return data;
        }

        fn writeAll(socket: posix.socket_t, data: []const u8) !void {
            var sent: usize = 0;
            while (sent < data.len) {
                sent += try posix.write(socket, data[sent..]);
            }
        }

        fn readMessage(self: *Self, socket: posix.socket_t) ![]u8 {
            while (true) {
                // loop until we have a full message to process
                if (try self.bufferedMessage()) |msg|
                    return msg;

                // read more data from the socket, fills up the buffer from pos to the end
                const n = try posix.read(socket, self.receive_buffer[self.read_pos..]);
                if (n == 0) // no more data, connection closed or EOF
                    return error.Closed;

                self.read_pos += n;
            }
        }

        fn bufferedMessage(self: *Self) !?[]u8 {
            if (self.read_pos < 10) {
                // not enough data to read the header
                return null;
            }

            const header = try deserializeMessageHeaders(&self.reader);
            const payload_len = header.Response.payload_len;

            const message_len = payload_len + 10;

            if (self.read_pos < message_len) {
                // not enough data to read the full message
                return null;
            }

            // copy out the full message before shifting the buffer
            const msg = self.receive_buffer[0..message_len];

            // shift remaining data to the front of the buffer
            @memmove(self.receive_buffer[0 .. self.read_pos - message_len], self.receive_buffer[message_len..self.read_pos]);
            self.read_pos -= message_len;
            self.reader.seek = 0;

            return msg;
        }
    };
}

fn IdsToReturnType(comptime options: ClientOptions, comptime contract_id: u16, comptime method_id: u16) type {
    const Contract = options.server_contracts[contract_id];

    const contract_info = @typeInfo(Contract);
    switch (contract_info) {
        .@"struct" => |struct_info| {
            inline for (struct_info.decls, 0..) |decl, i| {
                const method = @field(Contract, decl.name);
                const methodType = @TypeOf(method);
                if (@typeInfo(methodType) != .@"fn")
                    i -= 1;

                if (i == method_id) {
                    const fn_info = @typeInfo(methodType).@"fn";
                    return fn_info.return_type orelse void;
                }
            }

            @compileError("Invalid method_id");
        },
        else => @compileError("Expected struct type for contract"),
    }
}

fn WrapContractType(comptime TClient: type, comptime Contract: type) type {
    const type_info = @typeInfo(Contract);
    switch (type_info) {
        .@"struct" => |struct_info| {
            var newFields: [struct_info.decls.len]std.builtin.Type.StructField = undefined;

            inline for (struct_info.decls, 0..) |decl, i| {
                const method = @field(Contract, decl.name);
                const methodType = @TypeOf(method);
                if (@typeInfo(methodType) == .@"fn") {
                    newFields[i] = std.builtin.Type.StructField{
                        .name = decl.name,
                        .type = WrapContractMethodType(TClient, method),
                        .alignment = @alignOf(WrapContractMethodType(TClient, method)),
                        .is_comptime = false,
                        .default_value_ptr = null,
                    };
                }
            }

            return @Type(.{
                .@"struct" = .{
                    .layout = struct_info.layout,
                    .is_tuple = struct_info.is_tuple,
                    .decls = &.{},
                    .fields = &newFields,
                    .backing_integer = struct_info.backing_integer,
                },
            });
        },
        else => @compileError("WrapContractType only supports struct types"),
    }
}

fn wrapContract(comptime TClient: type, comptime Contract: type, comptime contract_id: u16) WrapContractType(TClient, Contract) {
    const WrappedType = WrapContractType(TClient, Contract);
    var wrapped_instance: WrappedType = undefined;

    inline for (@typeInfo(Contract).@"struct".decls, 0..) |decl, method_id| {
        const method = @field(Contract, decl.name);
        switch (@typeInfo(@TypeOf(method))) {
            .@"fn" => {
                const wrapped_method = wrapContractMethod(TClient, method, contract_id, method_id);
                @field(wrapped_instance, decl.name) = wrapped_method;
            },
            else => {},
        }
    }

    return wrapped_instance;
}

fn WrapContractMethodType(comptime TClient: type, comptime method: anytype) type {
    const type_info = @typeInfo(@TypeOf(method));
    const fn_info = switch (type_info) {
        .@"fn" => |@"fn"| @"fn",
        .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
            .@"fn" => |fn_info| fn_info,
            else => @compileError("WrapContractMethodType only supports function types"),
        },
        else => @compileError("WrapContractMethodType only supports function types"),
    };

    const return_type = fn_info.return_type orelse void;

    var arg_fields: [fn_info.params.len]std.builtin.Type.StructField = undefined;
    inline for (fn_info.params, 0..) |param, idx| {
        arg_fields[idx] = std.builtin.Type.StructField{
            .name = std.fmt.comptimePrint("{}", .{idx}),
            .type = param.type.?,
            .alignment = @alignOf(param.type.?),
            .is_comptime = false,
            .default_value_ptr = null,
        };
    }

    const argument = @Type(.{
        .@"struct" = .{
            .is_tuple = true,
            .backing_integer = null,
            .layout = .auto,
            .decls = &.{},
            .fields = &arg_fields,
        },
    });

    return *const fn (client: *TClient, args: argument) anyerror!return_type;
}

fn wrapContractMethod(comptime TClient: type, comptime method: anytype, comptime contract_id: u16, comptime method_id: u16) WrapContractMethodType(TClient, method) {
    const new_fn_info = @typeInfo(@typeInfo(WrapContractMethodType(TClient, method)).pointer.child).@"fn";

    return struct {
        fn invoke(client: *TClient, args: new_fn_info.params[1].type.?) (new_fn_info.return_type orelse void) {
            return try client.call(contract_id, method_id, args); // todo: handle expected errors

            // const payload_len = try CountingSerializer.serialize(@TypeOf(args), input_writer, args);

            // try serializeHeaders(input_writer, .{
            //     .Request = .{
            //         .version = app_version,
            //         .contract_id = contract_id,
            //         .method_id = method_id,
            //         .msg_type = .Request,
            //         .request_id = 123,
            //         .payload_len = payload_len,
            //     },
            // });

            // try Serializer.serialize(@TypeOf(args), input_writer, args);

            // std.debug.print("---> Contract method wrapper says: \"Hello World!\"\n", .{});
            // return @call(.auto, method, args); // todo: replace with actual remote call
        }
    }.invoke;
}

fn ContractsWrapper(comptime TClient: type, comptime options: ClientOptions) type {
    var contract_wrapper_fields: [options.server_contracts.len]std.builtin.Type.StructField = undefined;
    for (options.server_contracts, 0..) |Contract, idx| {
        const full_type_name = @typeName(Contract);

        var start_index = std.mem.indexOfScalar(u8, full_type_name, '.') orelse 0;
        if (start_index != 0)
            start_index += 1;

        var end_index = full_type_name.len;
        if (std.mem.endsWith(u8, full_type_name, "Contract"))
            end_index -= "Contract".len;

        const base_name: [:0]const u8 =
            std.fmt.comptimePrint("{s}", .{full_type_name[start_index..end_index]});

        contract_wrapper_fields[idx] = std.builtin.Type.StructField{
            .name = base_name,
            .type = WrapContractType(TClient, Contract),
            .alignment = @alignOf(WrapContractType(TClient, Contract)),
            .is_comptime = false,
            .default_value_ptr = null,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .backing_integer = null,
            .decls = &.{},
            .fields = &contract_wrapper_fields,
            .is_tuple = false,
            .layout = .auto,
        },
    });
}

fn createContracts(comptime TClient: type, comptime options: ClientOptions) ContractsWrapper(TClient, options) {
    const Contracts = ContractsWrapper(TClient, options);

    var contracts_instance: Contracts = undefined;

    inline for (@typeInfo(Contracts).@"struct".fields, 0..) |field, idx| {
        const Contract = options.server_contracts[idx];
        const wrapped_contract = wrapContract(TClient, Contract, idx);
        @field(contracts_instance, field.name) = wrapped_contract;
    }

    return contracts_instance;
}
