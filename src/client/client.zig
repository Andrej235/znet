const std = @import("std");
const posix = @import("std").posix;

const ClientOptions = @import("client-options.zig").ClientOptions;

pub fn Client(comptime options: ClientOptions) type {
    return struct {
        const Self = @This();

        contracts: ContractsWrapper(options),

        socket: posix.socket_t = undefined,

        pub fn init() Self {
            return createClient(options);
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
    };
}

fn WrapContractType(comptime Contract: type) type {
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
                        .type = WrapContractMethodType(method),
                        .alignment = @alignOf(WrapContractMethodType(method)),
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

fn wrapContract(comptime Contract: type) WrapContractType(Contract) {
    const WrappedType = WrapContractType(Contract);
    var wrapped_instance: WrappedType = undefined;

    inline for (@typeInfo(Contract).@"struct".decls) |decl| {
        const method = @field(Contract, decl.name);
        switch (@typeInfo(@TypeOf(method))) {
            .@"fn" => {
                const wrapped_method = WrapContractMethod(method);
                @field(wrapped_instance, decl.name) = wrapped_method;
            },
            else => {},
        }
    }

    return wrapped_instance;
}

fn WrapContractMethodType(comptime method: anytype) type {
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

    return *const fn (argument) return_type;
}

fn WrapContractMethod(comptime method: anytype) WrapContractMethodType(method) {
    const new_fn_info = @typeInfo(@typeInfo(WrapContractMethodType(method)).pointer.child).@"fn";

    return struct {
        fn invoke(args: new_fn_info.params[0].type.?) (new_fn_info.return_type orelse void) {
            std.debug.print("---> Contract method wrapper says: \"Hello World!\"\n", .{});
            return @call(.auto, method, args); // todo: replace with actual remote call
        }
    }.invoke;
}

fn ContractsWrapper(comptime options: ClientOptions) type {
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
            .type = WrapContractType(Contract),
            .alignment = @alignOf(WrapContractType(Contract)),
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

fn createClient(comptime options: ClientOptions) Client(options) {
    var client: Client(options) = undefined;
    client.contracts = createContracts(options);
    return client;
}

fn createContracts(comptime options: ClientOptions) ContractsWrapper(options) {
    const Contracts = ContractsWrapper(options);

    var contracts_instance: Contracts = undefined;

    inline for (@typeInfo(Contracts).@"struct".fields, 0..) |field, idx| {
        const Contract = options.server_contracts[idx];
        const wrapped_contract = wrapContract(Contract);
        @field(contracts_instance, field.name) = wrapped_contract;
    }

    return contracts_instance;
}
