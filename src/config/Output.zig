const std = @import("std");

const owm = @import("root").owm;
const log = owm.log;

const utils = @import("utils.zig");

const displays_file_path = "output/displays.json";

pub const Display = struct {
    id: []const u8,
    model: []const u8,

    /// Store the given `display` to the list of known dislpays if it's not stored
    pub fn storeInConfig(display: Display) void {
        const displays_json = DisplaysConfig.load() catch return;
        defer displays_json.deinit();
        var found = false;
        for (displays_json.value.displays) |*d| {
            if (std.mem.eql(u8, d.id, display.id)) {
                found = true;
            }
        }

        if (found) {
            return;
        }

        // Create a new Displays struct containing the new display in addition to existing ones
        var displays_list = std.ArrayList(Display).initCapacity(owm.alloc, displays_json.value.displays.len + 1) catch return;
        defer displays_list.deinit(owm.alloc);
        displays_list.appendSlice(owm.alloc, displays_json.value.displays) catch return;
        displays_list.append(owm.alloc, display) catch return;

        // Save the updated displays list
        var updated_displays = DisplaysConfig{
            .displays = displays_list.toOwnedSlice(owm.alloc) catch return,
        };
        defer owm.alloc.free(updated_displays.displays);
        updated_displays.save();
    }
};

const DisplaysConfig = struct {
    displays: []Display,

    fn save(self: *DisplaysConfig) void {
        log.infof("Config: Saving display config to '{s}'", .{displays_file_path});
        const json = utils.intoJsonString(DisplaysConfig, self.*);

        var file = utils.openConfigFile(DisplaysConfig, .write_only, displays_file_path) catch return;
        defer file.close();
        file.writeAll(json) catch {
            log.errf("Config: Failed to save config file '{s}'", .{displays_file_path});
            return;
        };
        log.infof("Config: Saved display config to '{s}'", .{displays_file_path});
    }

    fn load() utils.Error!std.json.Parsed(DisplaysConfig) {
        const file = utils.openConfigFile(DisplaysConfig, .read_only, displays_file_path) catch {
            return utils.Error.FailedToOpenFile;
        };
        defer file.close();

        const file_end_pos = file.getEndPos() catch |err| {
            log.errf("Config: Failed to read config file '{s}' with error {}", .{ displays_file_path, err });
            return utils.Error.FailedToOpenFile;
        };

        const file_contents = file.readToEndAlloc(owm.alloc, file_end_pos) catch |err| {
            log.errf("Config: Failed to read config file '{s}' with error {}", .{ displays_file_path, err });
            return utils.Error.FailedToOpenFile;
        };

        return utils.parseJsonToObject(DisplaysConfig, file_contents) catch |err| {
            log.errf("Config: Failed to read config file '{s}' with error {}", .{ displays_file_path, err });
            return utils.Error.FailedToOpenFile;
        };
    }

    fn defaultConfig() DisplaysConfig {
        return .{ .displays = &.{} };
    }

    pub fn defaultConfigJson() []const u8 {
        return utils.intoJsonString(DisplaysConfig, defaultConfig());
    }
};
