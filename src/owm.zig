pub const c_alloc = @import("utils.zig").allocator;
pub const alloc = @import("std").heap.page_allocator;

// pub var log: *@import("logly").Logger = undefined;
pub const log = @import("log.zig");

pub const Keyboard = @import("input.zig").Keyboard;
pub const Output = @import("output.zig").Output;
pub const Popup = @import("popup.zig").Popup;
pub const Toplevel = @import("toplevel.zig").Toplevel;
pub const Server = @import("server.zig").Server;
