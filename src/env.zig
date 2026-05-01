const std = @import("std");

const owm = @import("root").owm;

var env: std.process.Environ.Map = undefined;

pub fn init(i: *const std.process.Init) !void {
    env = i.minimal.environ.createMap(owm.alloc) catch @panic("How the heck does this PC not have enough RAM to hold the environment map in memory?");
}

pub fn deinit() void {
    env.deinit();
}

pub fn getHome() []const u8 {
    return env.get("HOME") orelse unreachable;
}

pub fn putVar(key: []const u8, value: []const u8) void {
    env.put(key, value) catch @panic("How the heck does this PC not have enough RAM to hold an additional environment variable?");
}

pub fn getVar(key: []const u8) []const u8 {
    return env.get(key) orelse unreachable;
}

pub fn getEnv() *std.process.Environ.Map {
    return &env;
}
