//! Acts as the root module of the project

const std = @import("std");

/// Used for wlroots related allocations
pub const c_alloc = std.heap.c_allocator;
pub const alloc = std.heap.page_allocator;

pub const client = @import("client/client.zig");
pub const config = @import("config/config.zig");
pub const log = @import("log/log.zig");
pub const math = @import("math/math.zig");

pub const Cursor = @import("Cursor.zig");
pub const Keyboard = @import("Keyboard.zig");
pub const Output = @import("Output.zig");

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
