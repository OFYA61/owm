//! Acts as the root module of the project

const std = @import("std");

pub const env = @import("env.zig");
pub const log = @import("log.zig");
pub const math = @import("math.zig");
pub const time = @import("time.zig");

pub const client = @import("client/client.zig");
pub const config = @import("config/config.zig");
pub const server = @import("server/server.zig");

var io: std.Io = undefined;

/// Used for wlroots related allocations
pub const c_alloc = std.heap.c_allocator;
pub const alloc = std.heap.page_allocator;

/// Wayland server instance
pub var SERVER: server.Server = undefined;

pub fn init(i: *const std.process.Init) anyerror!void {
    io = i.io;

    try env.init(i);
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
    env.deinit();
}

pub fn getIo() std.Io {
    return io;
}
