const std = @import("std");
const ServerOptions = @import("server-options.zig").ServerOptions;
const HandlerFn = @import("../handler-fn/handler-fn.zig").HandlerFn;
const createHandlerFn = @import("../handler-fn/create-handler-fn.zig").createHandlerFn;

pub const Server = struct {
    pub fn start(comptime options: ServerOptions) Server {
        return Server{
            .call_tables = create_call_table(options),
        };
    }

    call_tables: []const []const HandlerFn,
};

pub fn create_call_table(comptime options: ServerOptions) []const []const HandlerFn {
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
