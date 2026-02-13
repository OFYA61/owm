const std = @import("std");
const owm = @import("owm.zig");

var config: Config = undefined;

pub fn init() anyerror!void {
    owm.log.info("Reading config", .{}, @src());
    config = try Config.init();
}

pub fn deinit() void {
    config.deinit();
}

pub fn output() *OutputConfig {
    return &config.output.value;
}

pub const Config = struct {
    output: std.json.Parsed(OutputConfig),

    fn init() anyerror!Config {
        const alloc = std.heap.page_allocator;

        return .{
            .output = try OutputConfig.init(alloc),
        };
    }

    fn deinit(self: *Config) void {
        self.output.deinit();
    }
};

pub const OutputConfig = struct {
    arrangements: []Arrangement,

    pub const Arrangement = struct {
        displays: []Displays,

        pub const Displays = struct {
            id: []const u8,
            width: i32,
            height: i32,
            refresh: i32,
            x: i32,
            y: i32,
            active: bool,
        };
    };

    fn init(alloc: std.mem.Allocator) anyerror!std.json.Parsed(OutputConfig) {
        // TODO: create the file and folder if it doesn't exist
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
            return error.MissingHomeEnvironmentVariable;
        };
        defer alloc.free(home);

        const full_path = try std.fs.path.join(alloc, &.{
            home,
            ".config/owm/output.json",
        });
        defer alloc.free(full_path);

        const file = try std.fs.openFileAbsolute(full_path, .{ .mode = .read_only });
        defer file.close();

        // Let `Parsed.deinit()` handle cleaning this one up
        const file_contents = try file.readToEndAlloc(alloc, try file.getEndPos());

        return std.json.parseFromSlice(
            OutputConfig,
            alloc,
            file_contents,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            owm.log.err("Failed to parse output config: {}", .{err}, @src());
            return err;
        };
    }

    pub fn findArrangementForOutputs(self: *OutputConfig, outputs: *std.ArrayList(*owm.Output)) ?Arrangement {
        for (self.arrangements) |arrangement| {
            if (arrangement.displays.len != outputs.items.len) {
                continue;
            }
            var found_arrangement = true;
            for (outputs.items) |o| {
                var found_output = false;
                for (arrangement.displays) |display| {
                    if (std.mem.eql(u8, o.id, display.id)) {
                        found_output = true;
                        break;
                    }
                }
                if (!found_output) {
                    found_arrangement = false;
                    break;
                }
            }
            if (found_arrangement) {
                return arrangement;
            }
        }
        return null;
    }
};
