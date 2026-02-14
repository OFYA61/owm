const std = @import("std");
const owm = @import("../owm.zig");

const OutputConfig = @import("Output.zig").OutputConfig;

var config: Config = undefined;

pub fn init() anyerror!void {
    config = try Config.init();
}

pub fn deinit() void {
    config.deinit();
}

pub fn getOutput() *OutputConfig {
    return &config.output.value;
}

pub const Config = struct {
    output: std.json.Parsed(OutputConfig),

    fn init() anyerror!Config {
        owm.log.info("Config - Initializing", .{}, @src());
        return .{
            .output = OutputConfig.init(),
        };
    }

    fn deinit(self: *Config) void {
        self.output.deinit();
    }
};
