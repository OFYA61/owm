pub const owm = @import("owm.zig");

const std = @import("std");
const posix = std.posix;

pub fn main() anyerror!void {
    const sig_ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sig_ign, null);

    try owm.init();
    defer owm.deinit();
    try owm.run();
}
