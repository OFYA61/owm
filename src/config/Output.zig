const std = @import("std");

const owm = @import("root").owm;
const log = owm.log;

const utils = @import("utils.zig");

const arrangements_folder_path = "output";
const displays_file_path = "output/displays.json";

pub const Arrangement = std.json.ArrayHashMap(DisplayArrangementSettings);
pub const DisplayArrangementSettings = struct {
    width: i32,
    height: i32,
    refresh: i32,
    x: i32,
    y: i32,
    active: bool,
};

pub fn storeArrangement(id: []const u8, _: Arrangement) void {
    const arrangement_file_name = std.mem.join(owm.alloc, &[_][]const u8{ id, ".json" });
    defer owm.alloc.free(arrangement_file_name);

    // const arrangement_file_path = std.fs.path.join(owm.alloc, &.{ arrangements_folder_path, arrangement_file_name });
    // utils.openConfigFile("");
}

pub const DisplaysConfig = []Display;
pub const defualt_displays_config: DisplaysConfig = &.{};
pub const Display = struct {
    id: []const u8,
    model: []const u8,

    /// Store the given `display` to the list of known dislpays if it's not stored
    pub fn storeInConfig(display: Display) void {
        const displays_json = utils.load(DisplaysConfig, displays_file_path, defualt_displays_config) catch return;
        defer displays_json.deinit();
        var found = false;
        for (displays_json.value) |*d| {
            if (std.mem.eql(u8, d.id, display.id)) {
                found = true;
            }
        }

        if (found) {
            return;
        }

        var updated_displays_list = owm.alloc.alloc(Display, displays_json.value.len + 1) catch return;
        defer owm.alloc.free(updated_displays_list);
        @memcpy(updated_displays_list[0..displays_json.value.len], displays_json.value);
        updated_displays_list[displays_json.value.len] = display;
        utils.save(DisplaysConfig, updated_displays_list, displays_file_path);
    }
};
