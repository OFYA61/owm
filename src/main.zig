const std = @import("std");

const wlr = @import("wlroots");

const OwmServer = @import("server.zig").OwmServer;

pub fn main() anyerror!void {
    wlr.log.init(.info, null);

    var server: OwmServer = undefined;
    try server.init();
    defer server.deinit();

    var buf: [11]u8 = undefined;
    const wl_socket = try server.wl_server.addSocketAuto(&buf);
    server.setSocket(wl_socket);

    try server.run();
}
