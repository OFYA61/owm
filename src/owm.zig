pub const c_alloc = @import("utils.zig").allocator;
pub const alloc = @import("std").heap.page_allocator;

pub const log = @import("log.zig");
pub const config = @import("config/config.zig");

pub const Keyboard = @import("Keyboard.zig");
pub const Output = @import("Output.zig");
pub const Popup = @import("Popup.zig");
pub const Toplevel = @import("Toplevel.zig");
pub const Server = @import("Server.zig");

var socket_buf: [11]u8 = undefined;
/// Wayland Server Instance
pub var server: Server = undefined;

pub fn init() anyerror!void {
    try log.init();
    try config.init();
    try server.init();

    const wl_socket = try server.wl_server.addSocketAuto(&socket_buf);
    server.setSocket(wl_socket);
}

pub fn run() anyerror!void {
    return server.run();
}

pub fn deinit() void {
    server.deinit();
    config.deinit();
    log.deinit();
}
