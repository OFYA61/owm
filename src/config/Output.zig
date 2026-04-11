//! Config submodule responsible for managing and accessing display output configuration

const std = @import("std");

const owm = @import("root").owm;
const log = owm.log;

const utils = @import("utils.zig");

const arrangements_folder_path = "output";
pub const Arrangement = std.json.ArrayHashMap(DisplayArrangementSettings);
pub const DisplayArrangementSettings = struct {
    width: i32,
    height: i32,
    refresh: i32,
    x: i32,
    y: i32,
    active: bool,
};

/// Returns back an arrangement if one exists.
/// The caller is resposnible for calling `.deinit()`.
pub fn getArrangement(id: []const u8) ?std.json.Parsed(Arrangement) {
    const file_path = getArrangementFilePath(id);
    defer owm.alloc.free(file_path);

    if (!utils.checkConfigFileExists(file_path)) {
        return null;
    }

    return utils.load(Arrangement, file_path) catch unreachable;
}

pub fn storeArrangement(id: []const u8, arrangement: Arrangement) void {
    const file_path = getArrangementFilePath(id);
    defer owm.alloc.free(file_path);
    utils.ensureConfigFileExists(Arrangement, arrangement, file_path) catch return;
    utils.save(Arrangement, arrangement, file_path);
}

inline fn getArrangementFilePath(id: []const u8) []const u8 {
    const file_name = std.mem.join(owm.alloc, "", &[_][]const u8{ id, ".json" }) catch unreachable;
    defer owm.alloc.free(file_name);
    return std.fs.path.join(owm.alloc, &.{ arrangements_folder_path, file_name }) catch unreachable;
}

const displays_file_path = "output/displays.json";
pub const Display = struct {
    id: []const u8,
    model: []const u8,
};
const DisplaysConfig = []Display;
const defualt_displays_config: DisplaysConfig = &.{};

pub fn storeDisplay(id: []const u8, model: []const u8) void {
    utils.ensureConfigFileExists(DisplaysConfig, defualt_displays_config, displays_file_path) catch return;
    const displays_json = utils.load(DisplaysConfig, displays_file_path) catch return;
    defer displays_json.deinit();
    var found = false;
    for (displays_json.value) |*d| {
        if (std.mem.eql(u8, d.id, id)) {
            found = true;
        }
    }

    if (found) {
        return;
    }

    const display = Display{ .id = id, .model = model };

    var updated_displays_list = owm.alloc.alloc(Display, displays_json.value.len + 1) catch return;
    defer owm.alloc.free(updated_displays_list);
    @memcpy(updated_displays_list[0..displays_json.value.len], displays_json.value);
    updated_displays_list[displays_json.value.len] = display;
    utils.save(DisplaysConfig, updated_displays_list, displays_file_path);
}
