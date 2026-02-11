const std = @import("std");
const builtin = @import("builtin");

const logly = @import("logly");

pub var log: *logly.Logger = undefined;

pub fn init() anyerror!void {
    log = try logly.Logger.init(std.heap.page_allocator);

    var config = logly.Config.default();
    if (builtin.mode == .Debug) {
        config.level = .debug;
        config.auto_flush = true;
    } else {
        config.level = .info;
        config.auto_flush = false;
    }
    config.show_filename = true;
    config.show_lineno = true;
    config.show_time = true;
    log.configure(config);

    _ = try log.add(.{
        .path = "logs/owm.log",
        .rotation = "minutely",
        .retention = 60 * 24 * 7,
        .color = false,
    });
}

pub fn deinit() void {
    log.deinit();
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log.debugf(fmt, args, @src()) catch unreachable;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log.infof(fmt, args, @src()) catch unreachable;
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log.errf(fmt, args, @src()) catch unreachable;
}
