//! Config module, responsible for loading and exposing methods for reading the configs

pub const output = @import("Output.zig");
pub const keybinds = @import("Keybinds.zig");

pub fn init() !void {
    try keybinds.init();
}
