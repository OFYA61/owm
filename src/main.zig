const owm = @import("owm.zig");

pub fn main() anyerror!void {
    try owm.init();
    defer owm.deinit();
    try owm.run();
}
