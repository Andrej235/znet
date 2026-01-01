const std = @import("std");
const ClientOptions = @import("client-options.zig").ClientOptions;
const WrapContractMethodType = @import("server-contract-method-wrapper.zig").WrapContractMethodType;
const wrapContractMethod = @import("server-contract-method-wrapper.zig").wrapContractMethod;

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

pub fn ContractsWrapper(comptime TClient: type, comptime options: ClientOptions) type {
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

pub fn createContracts(comptime TClient: type, comptime options: ClientOptions) ContractsWrapper(TClient, options) {
    const Contracts = ContractsWrapper(TClient, options);

    var contracts_instance: Contracts = undefined;

    inline for (@typeInfo(Contracts).@"struct".fields, 0..) |field, idx| {
        const Contract = options.server_contracts[idx];
        const wrapped_contract = wrapContract(TClient, Contract, idx);
        @field(contracts_instance, field.name) = wrapped_contract;
    }

    return contracts_instance;
}
