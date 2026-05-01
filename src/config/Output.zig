//! Config submodule responsible for managing and accessing display output configuration

const std = @import("std");

const owm = @import("root").owm;
const log = owm.log;

const utils = @import("utils.zig");

const config_folder_path = "output";
pub const Arrangement = std.StringHashMap(DisplaySettings);
pub const DisplaySettings = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    refresh: i32,
    enabled: bool,

    fn fromConfigStr(config_str: []u8) utils.ParseError!DisplaySettings {
        var setting_tokenizer: utils.Tokenizer = .create(config_str, ',');
        const resolution_raw = setting_tokenizer.next() orelse {
            log.err("Config: Invalid display settings string, could not find resolution settings");
            return utils.ParseError.InvalidFormat;
        };
        const position_raw = setting_tokenizer.next() orelse {
            log.err("Config: Invalid display settings string, could not find poisition settings");
            return utils.ParseError.InvalidFormat;
        };
        const refresh_raw = setting_tokenizer.next() orelse {
            log.err("Config: Invalid display settings string, could not find refresh rate");
            return utils.ParseError.InvalidFormat;
        };
        const enabled_raw = setting_tokenizer.next() orelse {
            log.err("Config: Invalid display settings string, could not find if display is enabled or not");
            return utils.ParseError.InvalidFormat;
        };

        var resolution_tokenizer: utils.Tokenizer = .create(resolution_raw, 'x');
        const width_str = resolution_tokenizer.next() orelse {
            log.err("Config: Invalid display settings string, missing width");
            return utils.ParseError.InvalidFormat;
        };
        const width: i32 = std.fmt.parseInt(i32, width_str, 10) catch {
            log.errf("Config: Invalid dispay width string '{s}'", .{width_str});
            return utils.ParseError.NotANumber;
        };
        const height_str = resolution_tokenizer.next() orelse {
            log.err("Config: Invalid display settings string, missing height");
            return utils.ParseError.InvalidFormat;
        };
        const height: i32 = std.fmt.parseInt(i32, height_str, 10) catch {
            log.errf("Config: Invalid dispay height string '{s}'", .{height_str});
            return utils.ParseError.NotANumber;
        };

        var position_tokenizer: utils.Tokenizer = .create(position_raw, 'x');
        const x_str = position_tokenizer.next() orelse {
            log.err("Config: Invalid display settings string, missing x position");
            return utils.ParseError.InvalidFormat;
        };
        const x: i32 = std.fmt.parseInt(i32, x_str, 10) catch {
            log.errf("Config: Invalid display x position string '{s}'", .{x_str});
            return utils.ParseError.NotANumber;
        };
        const y_str = position_tokenizer.next() orelse {
            log.err("Config: Invalid display settings string, missing y position");
            return utils.ParseError.InvalidFormat;
        };
        const y: i32 = std.fmt.parseInt(i32, y_str, 10) catch {
            log.errf("Config: Invalid display y position string '{s}'", .{y_str});
            return utils.ParseError.NotANumber;
        };

        const refresh: i32 = std.fmt.parseInt(i32, refresh_raw, 10) catch {
            log.errf("Config: Invalid display refresh rate string '{s}'", .{refresh_raw});
            return utils.ParseError.NotANumber;
        };

        var enabled: bool = undefined;
        if (enabled_raw.len == 1 and enabled_raw[0] == '0') {
            enabled = false;
        } else {
            enabled = true;
        }

        return .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .refresh = refresh,
            .enabled = enabled,
        };
    }

    /// Caller is responsible for freeing up the return values memory allocation
    fn toConfigStr(self: *DisplaySettings) []const u8 {
        return std.fmt.allocPrint(
            owm.alloc,
            "{}x{}, {}x{}, {}, {s}",
            .{
                self.width,
                self.height,
                self.x,
                self.y,
                self.refresh,
                if (self.enabled) "1" else "0",
            },
        ) catch unreachable;
    }
};

/// Returns back an arrangement if one exists.
/// The caller is resposnible for calling the `freeArangement` function to cleanup the memory after the fact.
pub fn getArrangement(id: []const u8) (utils.ParseError || utils.FileError)!Arrangement {
    const file_path = getArrangementFilePath(id);
    defer owm.alloc.free(file_path);

    if (!utils.checkConfigFileExists(file_path)) {
        return utils.FileError.FileDoesNotExist;
    }

    const arrangement_raw = utils.loadRaw(file_path) catch |err| {
        log.errf("Config: Failed to load config file '{s}' with error {}", .{ file_path, err });
        return utils.FileError.FailedToReadFile;
    };
    defer owm.alloc.free(arrangement_raw);

    var arrangement: Arrangement = .init(owm.alloc);
    errdefer {
        var iter = arrangement.iterator();
        while (iter.next()) |entry| {
            owm.alloc.free(entry.key_ptr.*);
        }
        arrangement.deinit();
    }

    var arrangement_raw_truncated = utils.removeWhiteSpaces(arrangement_raw);
    defer arrangement_raw_truncated.deinit(owm.alloc);

    var arrangement_line_tokenizer: utils.Tokenizer = .create(arrangement_raw_truncated.items, '\n');
    while (arrangement_line_tokenizer.next()) |display_settings_line| {
        if (display_settings_line.len == 0) continue;
        log.debugf("Config: Processing display settings line: {s}", .{display_settings_line});

        var display_settings_line_tokenizer: utils.Tokenizer = .create(display_settings_line, '=');
        const display_id = display_settings_line_tokenizer.next() orelse {
            log.err("Config: Expected to find display ID token, but got none");
            continue;
        };
        const display_settings_raw = display_settings_line_tokenizer.next() orelse {
            log.err("Config: Expected to find display settings after '=', but found nothing");
            continue;
        };

        const display_settings = DisplaySettings.fromConfigStr(display_settings_raw) catch |err| {
            log.errf("Config: Failed to parse display settings string '{s} with error {}", .{ display_settings_raw, err });
            continue;
        };
        const display_id_cpy = owm.alloc.dupe(u8, display_id) catch unreachable; // This is needed because this hash map implementation does NOT own the keys memory
        log.debugf("Config: Display settings for '{s}'", .{display_id_cpy});
        arrangement.put(display_id_cpy, display_settings) catch unreachable;
    }

    return arrangement;
}

pub fn freeArrangement(arrangement: *Arrangement) void {
    var iter = arrangement.iterator();
    while (iter.next()) |entry| {
        owm.alloc.free(entry.key_ptr.*);
    }
    arrangement.deinit();
}

pub fn storeArrangement(id: []const u8, arrangement: Arrangement) void {
    const file_path = getArrangementFilePath(id);
    defer owm.alloc.free(file_path);
    _ = utils.ensureConfigFileExists("", file_path) catch {
        log.errf("Config: Failed to check if file '{s}' exists", .{file_path});
        return;
    };

    var arrangement_stream = std.ArrayList(u8).empty;
    defer arrangement_stream.deinit(owm.alloc);
    var iterator = arrangement.iterator();
    while (iterator.next()) |entry| {
        const display_settings_str = entry.value_ptr.toConfigStr();
        defer owm.alloc.free(display_settings_str);

        const arrangement_config_str = std.fmt.allocPrint(
            owm.alloc,
            "{s} = {s}\n",
            .{
                entry.key_ptr.*,
                display_settings_str,
            },
        ) catch unreachable;
        defer owm.alloc.free(arrangement_config_str);
        arrangement_stream.appendSlice(owm.alloc, arrangement_config_str) catch unreachable;
    }
    utils.writeRaw(arrangement_stream.items, file_path) catch |err| {
        log.errf("Config: Failed to write to config file '{s}' with error {}", .{ file_path, err });
        return;
    };
}

inline fn getArrangementFilePath(id: []const u8) []const u8 {
    return std.fs.path.join(owm.alloc, &.{ config_folder_path, id }) catch unreachable;
}

const displays_file_path = "output/displays";
pub const Display = struct {
    id: []const u8,
    model: []const u8,

    /// Caller is responsible for freeing up the allocated memory
    fn toConfigStr(self: *Display) []const u8 {
        return std.fmt.allocPrint(owm.alloc, "{s}, {s}", .{ self.id, self.model }) catch unreachable;
    }
};

pub fn storeDisplay(id: []const u8, model: []const u8) void {
    _ = utils.ensureConfigFileExists(
        "",
        displays_file_path,
    ) catch |err| {
        log.errf("Config: Failed to enure config file '{s}' exists with error {}", .{ displays_file_path, err });
        return;
    };

    const displays_raw = utils.loadRaw(displays_file_path) catch {
        log.errf("Config: Failed to load config file '{s}'", .{displays_file_path});
        return;
    };
    defer owm.alloc.free(displays_raw);

    var displays_tokenizer = utils.Tokenizer.create(displays_raw, '\n');
    while (displays_tokenizer.next()) |display_token| {
        var display_tokenizer = utils.Tokenizer.create(display_token, ',');
        const stored_id = display_tokenizer.next() orelse {
            log.err("Config: Expected a display ID token, but got nothing");
            return;
        };
        if (std.mem.eql(u8, id, stored_id)) {
            log.infof("Config: Display with id '{s}' is already stored", .{id});
            return;
        }
    }

    var new_display = Display{ .id = id, .model = model };
    const new_display_raw = new_display.toConfigStr();
    defer owm.alloc.free(new_display_raw);

    var new_display_config_str = std.ArrayList(u8).initCapacity(owm.alloc, displays_raw.len + new_display_raw.len + 1) catch unreachable;
    defer new_display_config_str.deinit(owm.alloc);

    new_display_config_str.appendSlice(owm.alloc, displays_raw) catch unreachable;
    if (new_display_config_str.items.len > 0) {
        new_display_config_str.append(owm.alloc, '\n') catch unreachable;
    }
    new_display_config_str.appendSlice(owm.alloc, new_display_raw) catch unreachable;

    utils.writeRaw(new_display_config_str.items, displays_file_path) catch |err| {
        log.errf("Config: Failed to write to config file '{s}' with error {}", .{ displays_file_path, err });
        return;
    };
}
