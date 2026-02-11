const owm = @import("owm.zig");

const config = @import("config.zig");

pub fn main() anyerror!void {
    try owm.init();
    defer owm.deinit();

    var server: owm.Server = undefined;
    try server.init();
    defer server.deinit();

    var buf: [11]u8 = undefined;
    const wl_socket = try server.wl_server.addSocketAuto(&buf);
    server.setSocket(wl_socket);

    try server.run();
}
