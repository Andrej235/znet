const znet = @import("znet");
const ClientMessageContract = @import("client/message-contract").MessageContract;

pub const MessageContract = struct {
    pub fn send(context: *znet.Context, name: []const u8, message: []const u8) bool {
        var promise = context.clients.others() catch return false;
        promise.broadcast(ClientMessageContract.onRecieve, .{ name, message }) catch return false;
        return true;
    }
};
