//! Acts as the root module of the project

const std = @import("std");

/// Used for wlroots related allocations
pub const c_alloc = std.heap.c_allocator;
pub const alloc = std.heap.page_allocator;

pub const client = @import("client/client.zig");
pub const config = @import("config/config.zig");
pub const log = @import("log/log.zig");
pub const math = @import("math/math.zig");
pub const server = @import("server/server.zig");

/// Wayland server instance
pub var SERVER: server.Server = undefined;

pub fn init() anyerror!void {
    try log.init();
    try config.init();
    try SERVER.init();
}

pub fn run() anyerror!void {
    return SERVER.run();
}

pub fn deinit() void {
    SERVER.deinit();
    log.deinit();
}
