const std = @import("std");
const owm = @import("../owm.zig");

var config: Config = undefined;

pub const OutputConfig = @import("Output.zig").OutputConfig;

pub const Config = struct {
    output: OutputConfig,

    fn init() anyerror!Config {
        owm.log.info("Config - Initializing", .{}, @src());
        return .{
            .output = OutputConfig.init() catch OutputConfig.defaultConfig(),
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

pub fn getOutput() *OutputConfig {
    return &config.output;
}
