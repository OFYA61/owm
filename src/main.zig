const std = @import("std");

const wlr = @import("wlroots");

const owm = @import("owm.zig");

pub fn main() anyerror!void {
    wlr.log.init(.info, null);

    var server: owm.Server = undefined;
    try server.init();
    defer server.deinit();

    var buf: [11]u8 = undefined;
    const wl_socket = try server.wl_server.addSocketAuto(&buf);
    server.setSocket(wl_socket);

    try server.run();
}
