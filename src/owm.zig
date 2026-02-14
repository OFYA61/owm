pub const c_alloc = @import("utils.zig").allocator;
pub const alloc = @import("std").heap.page_allocator;

pub const log = @import("log.zig");
// pub const config = @import("config.zig");
pub const config = @import("config/config.zig");

pub const Keyboard = @import("input.zig").Keyboard;
pub const Output = @import("output.zig").Output;
pub const Popup = @import("popup.zig").Popup;
pub const Toplevel = @import("toplevel.zig").Toplevel;
pub const Server = @import("server.zig").Server;

pub fn init() anyerror!void {
    try log.init();
    try config.init();
}

pub fn deinit() void {
    config.deinit();
    log.deinit();
}
