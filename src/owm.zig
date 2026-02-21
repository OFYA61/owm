//! Acts as the root module of the project

const std = @import("std");

/// Use for wlroots related allocations
pub const c_alloc = std.heap.c_allocator;
pub const alloc = std.heap.page_allocator;

pub const log = @import("log.zig");
pub const config = @import("config/config.zig");

pub const Keyboard = @import("Keyboard.zig");
pub const LayerSurface = @import("LayerSurface.zig");
pub const ManagedWindow = @import("ManagedWindow.zig");
pub const Output = @import("Output.zig");
pub const Popup = @import("Popup.zig");
pub const Toplevel = @import("Toplevel.zig");

/// Wayland server instance
pub var server: @import("Server.zig") = undefined;

pub fn init() anyerror!void {
    try log.init();
    try config.init();
    try server.init();
}

pub fn run() anyerror!void {
    return server.run();
}

pub fn deinit() void {
    server.deinit();
    config.deinit();
    log.deinit();
}
