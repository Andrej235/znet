pub const app_version: u8 = @import("app_version.zig").app_version;

pub const http = @import("http/http.zig");

pub const Options = @import("options.zig").Options;
pub const Logger = @import("logger/logger.zig").Logger;

pub const Serializer = @import("serialization/binary/serializer.zig").Serializer;
pub const Deserializer = @import("serialization/binary/deserializer.zig").Deserializer;

pub const Client = @import("client/client.zig").Client;
pub const Server = @import("server/server.zig").Server;

pub const App = @import("app/app.zig").App;
pub const Host = @import("app/host/host.zig").Host;
pub const Scope = @import("app/scope/scope.zig").Scope;
pub const Action = @import("app/action/action.zig").Action;

pub const Path = @import("app/params/path_param.zig").Path;
pub const Query = @import("app/params/query_param.zig").Query;
pub const Body = @import("app/params/body_param.zig").Body;

pub const DIContainer = @import("dependency_injection/container.zig").Container;
pub const DIService = @import("dependency_injection/service.zig").Service;
