const std = @import("std");
const owm = @import("../owm.zig");
const utils = @import("utils.zig");
const alloc = utils.alloc;

pub const OutputConfig = struct {
    arrangements: std.ArrayList(Arrangement),

    pub const Arrangement = struct {
        displays: std.ArrayList(Display),

        pub const Display = struct {
            id: []const u8,
            width: i32,
            height: i32,
            refresh: i32,
            x: i32,
            y: i32,
            active: bool,
        };
    };

    pub fn init() anyerror!OutputConfig {
        const raw = try OutputConfigRaw.init();
        defer raw.deinit();
        var arrangements: std.ArrayList(Arrangement) = try .initCapacity(alloc, raw.value.arrangements.len);
        errdefer arrangements.deinit(alloc);

        for (raw.value.arrangements) |*raw_arrangement| {
            var displays: std.ArrayList(Arrangement.Display) = try .initCapacity(alloc, raw_arrangement.displays.len);
            errdefer displays.deinit(alloc);
            for (raw_arrangement.displays) |*raw_display| {
                try displays.append(alloc, Arrangement.Display{
                    .id = raw_display.id,
                    .width = raw_display.width,
                    .height = raw_display.height,
                    .refresh = raw_display.refresh,
                    .x = raw_display.x,
                    .y = raw_display.y,
                    .active = raw_display.active,
                });
            }

            try arrangements.append(alloc, Arrangement{ .displays = displays });
        }

        return OutputConfig{ .arrangements = arrangements };
    }

    pub fn deinit(self: *OutputConfig) void {
        for (self.arrangements.items) |*arrangement| {
            arrangement.displays.deinit(alloc);
        }
        self.arrangements.deinit(alloc);
    }

    pub fn defaultConfig() OutputConfig {
        return OutputConfig{ .arrangements = .empty };
    }

    pub fn findArrangementForOutputs(self: *OutputConfig, outputs: *std.ArrayList(*owm.Output)) ?Arrangement {
        for (self.arrangements.items) |arrangement| {
            if (arrangement.displays.items.len != outputs.items.len) {
                continue;
            }
            var found_arrangement = true;
            for (outputs.items) |o| {
                var found_output = false;
                for (arrangement.displays.items) |display| {
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
    pub fn addNewArrangement(self: *OutputConfig, new_arrangement: Arrangement) !void {
        self.arrangements.append(alloc, new_arrangement) catch |err| {
            owm.log.errf("Config - Output - Failed to add new arrangement {}", .{err});
            return err;
        };

        const raw_arrangements = try alloc.alloc(OutputConfigRaw.ArrangementRaw, self.arrangements.items.len);
        for (self.arrangements.items, 0..) |*arr, i| {
            const raw_displays = try alloc.alloc(OutputConfigRaw.ArrangementRaw.DisplayRaw, arr.displays.items.len);

            for (arr.displays.items, 0..) |disp, j| {
                raw_displays[j] = .{
                    .id = disp.id,
                    .width = disp.width,
                    .height = disp.height,
                    .refresh = disp.refresh,
                    .x = disp.x,
                    .y = disp.y,
                    .active = disp.active,
                };
            }
            raw_arrangements[i] = .{ .displays = raw_displays };
        }

        var output_config_raw = OutputConfigRaw{ .arrangements = raw_arrangements };
        output_config_raw.save() catch {
            owm.log.err("Config - Output - Failed to save new config");
        };

        for (raw_arrangements) |arr| {
            alloc.free(arr.displays);
        }
        alloc.free(raw_arrangements);
    }
};

const OutputConfigRaw = struct {
    arrangements: []ArrangementRaw,

    pub const ArrangementRaw = struct {
        displays: []DisplayRaw,

        pub const DisplayRaw = struct {
            id: []const u8,
            width: i32,
            height: i32,
            refresh: i32,
            x: i32,
            y: i32,
            active: bool,
        };
    };

    pub fn init() anyerror!std.json.Parsed(OutputConfigRaw) {
        const file = openConfigFile(.read_only) catch |err| {
            owm.log.errf("Config - Output - Failed to open config file with error: {}, using default configuration", .{err});
            return err;
        };
        defer file.close();

        const file_end_pos = file.getEndPos() catch |err| {
            owm.log.errf("Config - Output - Failed to read config file with error: {}, using default configuration", .{err});
            return err;
        };
        // Let `Parsed.deinit()` handle cleaning up `file_contents`
        const file_contents = file.readToEndAlloc(alloc, file_end_pos) catch |err| {
            owm.log.errf("Config - Output - Failed to read config file with error: {}, using default configuration", .{err});
            return err;
        };

        return utils.parseJsonSlice(OutputConfigRaw, file_contents) catch |err| {
            owm.log.errf("Config - Output - Failed to parse output config with error: {}, using default configuration", .{err});
            return err;
        };
    }

    pub fn save(self: *OutputConfigRaw) anyerror!void {
        owm.log.info("Config - Output - Saving new config");
        const json = std.fmt.allocPrint(
            alloc,
            "{f}",
            .{std.json.fmt(self, .{ .whitespace = .indent_tab })},
        ) catch unreachable;

        var file = try openConfigFile(.write_only);
        try file.writeAll(json);
        owm.log.info("Config - Output - Saved new config");
    }

    fn openConfigFile(mode: std.fs.File.OpenMode) anyerror!std.fs.File {
        owm.log.info("Config - Output - Attempting to open output.json");

        const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
            return error.MissingHomeEnvironmentVariable;
        };
        defer alloc.free(home);
        const full_path = try std.fs.path.join(alloc, &.{
            home,
            ".config/owm/output.json",
        });
        defer alloc.free(full_path);

        return std.fs.openFileAbsolute(full_path, .{ .mode = mode }) catch |err| {
            if (err != error.FileNotFound) {
                owm.log.err("Config - Output - Unexpected error when trying to open output.json config file");
                return err;
            }

            owm.log.info("Config - Output - output.json does not exist, creating file with default config");
            const file = std.fs.createFileAbsolute(full_path, .{}) catch unreachable;
            _ = try file.write(defaultConfigJson());
            file.close();

            return std.fs.openFileAbsolute(full_path, .{ .mode = .read_only });
        };
    }

    fn defaultConfig() OutputConfigRaw {
        return OutputConfigRaw{ .arrangements = &.{} };
    }

    fn defaultConfigJson() []const u8 {
        const json = std.json.fmt(
            defaultConfig(),
            .{ .whitespace = .indent_tab },
        );
        return std.fmt.allocPrint(alloc, "{f}", .{json}) catch unreachable;
    }
};
