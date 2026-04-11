//! Config module, responsible for loading and exposing methods for reading the configs

const std = @import("std");
const owm = @import("../owm.zig");

var config: Config = undefined;

pub const Output = @import("Output.zig");
pub const OutputConfigOld = @import("OutputOld.zig").OutputConfig;

pub const Config = struct {
    output: OutputConfigOld,

    fn init() anyerror!Config {
        owm.log.info("Config - Initializing");
        return .{
            .output = OutputConfigOld.init() catch OutputConfigOld.defaultConfig(),
        };
    }

    fn deinit(self: *Config) void {
        self.output.deinit();
    }
};

pub fn init() anyerror!void {
    config = try Config.init();
}

pub fn deinit() void {
    config.deinit();
}

pub fn getOutputOld() *OutputConfigOld {
    return &config.output;
}
