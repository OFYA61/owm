//! Config module, responsible for loading and exposing methods for reading the configs

pub const keybinds = @import("Keybinds.zig");
pub const output = @import("Output.zig");
pub const startup = @import("Startup.zig");

pub fn init() !void {
    try keybinds.init();
}

pub fn deinit() void {
    keybinds.deinit();
}
