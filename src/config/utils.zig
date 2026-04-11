//! Contains utilities used by the config files

const std = @import("std");

const owm = @import("root").owm;
const log = owm.log;

pub const alloc = @import("root").owm.alloc;

pub fn intoJsonString(comptime T: type, object: T) []const u8 {
    const json = std.json.fmt(
        object,
        .{ .whitespace = .indent_tab },
    );
    return std.fmt.allocPrint(alloc, "{f}", .{json}) catch unreachable;
}

pub fn parseJsonToObject(comptime T: type, slice: []const u8) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    return std.json.parseFromSlice(
        T,
        alloc,
        slice,
        .{ .ignore_unknown_fields = true },
    );
}

pub const Error = error{
    FailedToCreateDirectory,
    FailedToGetDirectory,
    FailedToOpenFile,
};

/// Opens the given config file from the root of the config directory.
/// If it doesn't exist, it'll create one with the default value provided by the
/// `defaultConfigJson` function from `T`. Caller is responsible for closing the file
///
/// ```zig
/// // Usage
/// const file = openConfigFile(MyStruct, .read_only, "config_file.json");
/// defer file.close();
/// ```
pub fn openConfigFile(comptime T: type, mode: std.fs.File.OpenMode, file_path: []const u8) !std.fs.File {
    log.infof("Config: Attempting to open file '{s}'", .{file_path});

    const home = try std.process.getEnvVarOwned(owm.alloc, "HOME");
    defer owm.alloc.free(home);
    const full_path = try getFullConfigFilePath(file_path);
    defer owm.alloc.free(full_path);

    return std.fs.openFileAbsolute(full_path, .{ .mode = mode }) catch |err| {
        if (err != error.FileNotFound) {
            log.errf("Config: Unexpected error when trying to open {s} config file", .{file_path});
            return err;
        }

        const dir = std.fs.path.dirname(full_path) orelse {
            return Error.FailedToGetDirectory;
        };
        std.fs.makeDirAbsolute(dir) catch {
            log.warnf("Config: Failed to create directory '{s}', it might already exist", .{dir});
        };

        log.infof("Config: File '{s}' does not exist, creating file with default config", .{file_path});
        const file = std.fs.createFileAbsolute(full_path, .{}) catch |err2| {
            log.errf("Config: Failed to create file '{s}' with error {}", .{ file_path, err2 });
            return err2;
        };
        _ = try file.write(T.defaultConfigJson());
        file.close();

        return std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch |err2| {
            log.errf("Config: Failed to open '{s}' with error {}", .{ file_path, err2 });
            return err2;
        };
    };
}

/// Given a `relative_path` from the root of the config directory, returns the full path of the config file.
/// Caller must deallocate the memory after the fact
///
/// ```zig
/// // Usage
/// const full_path = getFullConfigFilePath("output/displays.json");
/// defer owm.alloc.free(full_path);
/// ```
fn getFullConfigFilePath(relative_path: []const u8) ![]u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
        return error.MissingHomeEnvironmentVariable;
    };
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &.{ home, ".config", "owm", relative_path });
}
