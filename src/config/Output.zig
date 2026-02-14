const std = @import("std");
const owm = @import("../owm.zig");
const utils = @import("utils.zig");
const alloc = utils.alloc;

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

    pub fn init() std.json.Parsed(OutputConfig) {
        const file = openConfigFile() catch |err| {
            owm.log.err("Config - Output - Failed to open config file with error: {}, using default configuration", .{err}, @src());
            return defaultConfigJsonParsed();
        };
        defer file.close();

        const file_end_pos = file.getEndPos() catch |err| {
            owm.log.err("Config - Output - Failed to read config file with error: {}, using default configuration", .{err}, @src());
            return defaultConfigJsonParsed();
        };
        // Let `Parsed.deinit()` handle cleaning up `file_contents`
        const file_contents = file.readToEndAlloc(alloc, file_end_pos) catch |err| {
            owm.log.err("Config - Output - Failed to read config file with error: {}, using default configuration", .{err}, @src());
            return defaultConfigJsonParsed();
        };

        return utils.parseJsonSlice(OutputConfig, file_contents) catch |err| {
            owm.log.err("Config - Output - Failed to parse output config with error: {}, using default configuration", .{err}, @src());
            return defaultConfigJsonParsed();
        };
    }

    fn openConfigFile() anyerror!std.fs.File {
        owm.log.info("Config - Output - Attempting to read output.json", .{}, @src());

        const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
            return error.MissingHomeEnvironmentVariable;
        };
        defer alloc.free(home);
        const full_path = try std.fs.path.join(alloc, &.{
            home,
            ".config/owm/output.json",
        });
        defer alloc.free(full_path);

        return std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch |err| {
            if (err != error.FileNotFound) {
                owm.log.err("Config - Output - Unexpected error when trying to open output.json config file", .{}, @src());
                return err;
            }

            owm.log.info("Config - Output - output.json does not exist, creating file with default config", .{}, @src());
            const file = std.fs.createFileAbsolute(full_path, .{}) catch unreachable;
            _ = try file.write(defaultConfigJson());
            file.close();

            return std.fs.openFileAbsolute(full_path, .{ .mode = .read_only });
        };
    }

    fn defaultConfig() OutputConfig {
        return OutputConfig{ .arrangements = &.{} };
    }

    fn defaultConfigJson() []const u8 {
        const j = std.json.fmt(
            defaultConfig(),
            .{ .whitespace = .indent_tab },
        );
        return std.fmt.allocPrint(alloc, "{f}", .{j}) catch unreachable;
    }

    fn defaultConfigJsonParsed() std.json.Parsed(OutputConfig) {
        return utils.parseJsonSlice(OutputConfig, defaultConfigJson()) catch unreachable;
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

    /// Use to add new output arrangements when an unknown output configuration has shown up
    pub fn addNewArrangement(self: *OutputConfig, new_arrangement: Arrangement) void {
        const new_length = self.arrangements.len + 1;

        const new_memory = alloc.realloc(self.arrangements, new_length);

        self.arrangements = new_memory;
        self.arrangements[new_length - 1] = new_arrangement;
    }
};
