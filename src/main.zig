pub const owm = @import("owm.zig");

const std = @import("std");

pub fn main(init: std.process.Init) anyerror!void {
    try owm.init(&init);
    defer owm.deinit();
    try owm.run();
}
