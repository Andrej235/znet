const std = @import("std");

const App = @import("app.zig").App;

const Errors = error{
    NetworkFailure,
    Timeout,
    Unknown,
};

pub fn main() !void {
    const client = createClient(.{
        .contracts = &.{ AuthContract, TaskContract },
    });
    client.connect();

    client.contracts.Auth.login(.{ "admin", "password" }) catch |err| {
        std.debug.print("Login error: {}\n", .{err});
    };

    const taskId = client.contracts.Task.createTask(.{ "My Task", "This is a test task." }) catch |err| {
        std.debug.print("CreateTask error: {}\n", .{err});
        return;
    };

    client.contracts.Task.deleteTask(.{taskId}) catch |err| {
        std.debug.print("DeleteTask error: {}\n", .{err});
    };

    client.disconnect();
}

fn functionDecls(comptime T: type) []const u8 {
    const ti = @typeInfo(T).@"struct";

    comptime var names: []const u8 = &.{};

    inline for (ti.decls) |decl| {
        const val = @field(T, decl.name);
        if (@typeInfo(@TypeOf(val)) == .@"fn") {
            names = names ++ ", " ++ decl.name;
        }
    }

    return names;
}

const MyStruct = struct {
    pub fn helloWorld() void {
        std.debug.print("Hello, World!\n", .{});
    }

    pub fn foo(x: i32) i32 {
        return x + 1;
    }
};

const AuthContract = struct {
    pub fn login(username: []const u8, password: []const u8) Errors!void {
        if (!std.mem.eql(u8, username, "admin") or !std.mem.eql(u8, password, "password")) {
            std.debug.print("Wrong Credentials\n", .{});
        } else {
            std.debug.print("login successful\n", .{});
        }
    }

    pub fn logout() void {
        std.debug.print("logout\n", .{});
    }
};

const TaskContract = struct {
    pub fn createTask(title: []const u8, description: []const u8) Errors!u32 {
        std.debug.print("Creating task: {s} - {s}\n", .{ title, description });
        return 1;
    }

    pub fn deleteTask(taskId: u32) Errors!void {
        std.debug.print("Deleting task with ID: {d}\n", .{taskId});
    }
};

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
    const return_type = return_type: switch (type_info) {
        .@"fn" => |fn_info| {
            break :return_type (fn_info.return_type orelse void);
        },
        else => @compileError("WrapContractMethodType only supports function types"),
    };

    return *const fn (anytype) return_type;
}

fn WrapContractMethod(comptime method: anytype) WrapContractMethodType(method) {
    const new_method_type_info = @typeInfo(WrapContractMethodType(method));
    const NewReturnType = switch (new_method_type_info) {
        .@"fn" => |fn_info| fn_info.return_type orelse void,
        .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
            .@"fn" => |fn_info| fn_info.return_type orelse void,
            else => @compileError("Unexpected pointer child type info"),
        },
        else => @compileError("Unexpected type info"),
    };

    return struct {
        fn invoke(args: anytype) NewReturnType {
            std.debug.print("---> Contract method wrapper says: \"Hello World!\"\n", .{});
            return @call(.auto, method, args);
        }
    }.invoke;
}

const ClientOptions = struct {
    contracts: []const type,
};

fn ContractsWrapper(comptime options: ClientOptions) type {
    var contract_wrapper_fields: [options.contracts.len]std.builtin.Type.StructField = undefined;
    for (options.contracts, 0..) |Contract, idx| {
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

fn Client(comptime options: ClientOptions) type {
    const Contracts = ContractsWrapper(options);

    const BaseType = struct {
        fn connect(_: @This()) void {
            std.debug.print("connecting... \n", .{});
        }

        fn disconnect(_: @This()) void {
            std.debug.print("disconnecting... \n", .{});
        }

        contracts: Contracts,
    };

    return BaseType;
}

fn createClient(comptime options: ClientOptions) Client(options) {
    const Contracts = ContractsWrapper(options);

    var client: Client(options) = undefined;
    var contracts_instance: Contracts = undefined;

    inline for (@typeInfo(Contracts).@"struct".fields, 0..) |field, idx| {
        const Contract = options.contracts[idx];
        const wrapped_contract = wrapContract(Contract);
        @field(contracts_instance, field.name) = wrapped_contract;
    }

    client.contracts = contracts_instance;
    return client;
}
