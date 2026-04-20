//! Contains utilities used by the config files

const std = @import("std");

const owm = @import("root").owm;
const log = owm.log;

pub const alloc = @import("root").owm.alloc;

pub const Error = error{
    FailedToCreateDirectory,
    FailedToCreateFile,
    FailedToGetDirectory,
    FailedToOpenFile,
    FailedToReadFile,
    FailedToWriteFile,
    MissingHomeEnvironmentVariable,
};

/// Loads the file contents as raw string. The caller is repsonsible for freeing up the memory.
pub fn loadRaw(file_path: []const u8) Error![]u8 {
    const file = openConfigFile(.read_only, file_path) catch {
        return Error.FailedToOpenFile;
    };
    defer file.close();

    const file_end_pos = file.getEndPos() catch |err| {
        log.errf("Config: Failed to read config file '{s}' with error {}", .{ file_path, err });
        return Error.FailedToOpenFile;
    };

    return file.readToEndAlloc(owm.alloc, file_end_pos) catch |err| {
        log.errf("Config: Failed to read config file '{s}' with error {}", .{ file_path, err });
        return Error.FailedToReadFile;
    };
}

/// Loads and parses the provided config `file_path` into the given type `T` from JSON. If does not exist
/// creates a default cconfig file with the provided `default_value`.
pub fn load(comptime T: type, file_path: []const u8) Error!std.json.Parsed(T) {
    const file = openConfigFile(.read_only, file_path) catch {
        return Error.FailedToOpenFile;
    };
    defer file.close();

    const file_end_pos = file.getEndPos() catch |err| {
        log.errf("Config: Failed to read config file '{s}' with error {}", .{ file_path, err });
        return Error.FailedToOpenFile;
    };

    const file_contents = file.readToEndAlloc(owm.alloc, file_end_pos) catch |err| {
        log.errf("Config: Failed to read config file '{s}' with error {}", .{ file_path, err });
        return Error.FailedToReadFile;
    };

    return parseJsonToObject(T, file_contents) catch |err| {
        log.errf("Config: Failed to read config file '{s}' with error {}", .{ file_path, err });
        return Error.FailedToOpenFile;
    };
}

/// Saves the given `object` into the provided `file_path` as a JSON object
pub fn save(comptime T: type, object: T, file_path: []const u8) void {
    log.infof("Config: Saving config to '{s}'", .{file_path});
    const json = intoJsonString(T, object);

    var file = openConfigFile(.write_only, file_path) catch return;
    defer file.close();
    file.writeAll(json) catch {
        log.errf("Config: Failed to save config file '{s}'", .{file_path});
        return;
    };
    log.infof("Config: Saved config to '{s}'", .{file_path});
}

/// Opens the given config file from the root of the config directory.
/// Caller is responsible for closing the file
fn openConfigFile(mode: std.fs.File.OpenMode, relative_path: []const u8) !std.fs.File {
    log.infof("Config: Attempting to open existing file '{s}'", .{relative_path});

    const full_path = getFullConfigFilePath(relative_path);
    defer owm.alloc.free(full_path);

    return std.fs.openFileAbsolute(full_path, .{ .mode = mode }) catch |err| {
        log.errf(
            "Config: Unexpected error when trying to open {s} config file '{}'",
            .{
                relative_path,
                err,
            },
        );
        return err;
    };
}

pub fn checkConfigFileExists(relative_path: []const u8) bool {
    const full_path = getFullConfigFilePath(relative_path);
    defer owm.alloc.free(full_path);

    std.fs.accessAbsolute(full_path, .{ .mode = .read_only }) catch {
        return false;
    };

    return true;
}

/// Ensures that the given file exists, if it doesn not, it creates one with the provided default value
pub fn ensureConfigFileExists(default_value: []const u8, relative_path: []const u8) Error!void {
    const full_path = getFullConfigFilePath(relative_path);
    defer owm.alloc.free(full_path);

    const file_check = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only });

    if (file_check) |file| {
        file.close();
        return;
    } else |err| {
        if (err != error.FileNotFound) return {
            log.errf("Config: Failed to open '{s}' with error {}", .{ relative_path, err });
            return Error.FailedToOpenFile;
        };

        if (std.fs.path.dirname(full_path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |dir_err| {
                if (dir_err != error.PathAlreadyExists) {
                    return Error.FailedToCreateDirectory;
                }
                log.warnf("Config: Failed to create directory '{s}', it might already exist", .{dir});
            };
        }

        const file = std.fs.createFileAbsolute(full_path, .{}) catch |err_create| {
            log.errf("Config: Failed to create file '{s}' with error {}", .{ relative_path, err_create });
            return Error.FailedToCreateFile;
        };
        defer file.close();

        file.writeAll(default_value) catch {
            log.errf("Config: Failed to write to file '{s}'", .{full_path});
            return Error.FailedToWriteFile;
        };
    }
}

/// Given a `relative_path` from the root of the config directory, returns the full path of the config file.
/// Caller must deallocate the memory after the fact
///
/// ```zig
/// // Usage
/// const full_path = getFullConfigFilePath("output/displays.json");
/// defer owm.alloc.free(full_path);
/// ```
fn getFullConfigFilePath(relative_path: []const u8) []u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch unreachable;
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".config", "owm", relative_path }) catch unreachable;
}

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

/// Utility to tokenize an array of characters given a separator character
/// Example usage
/// ```zig
/// const stream_raw: [] u8 = "Some stream";
///
/// var stream = std.ArrayList(u8).initCapacity(alloc, stream_raw.len) catch unreachable;
/// stream.deinit(alloc);
/// stream.appendSlice(alloc, stream_raw) catch unreachable;
/// var tokenizer: Tokenizer = .create(&stream, ' ');
///
/// while (tokenizer.next()) |token| {
///     // Process token
/// }
/// ```
pub const Tokenizer = struct {
    const Self = @This();

    stream: *std.ArrayList(u8),
    seperator: u8,
    config_progress: usize = 0,
    finished: bool = false,

    /// The caller own the `stream` and only passes a reference to the `Tokenizer`
    pub fn create(stream: *std.ArrayList(u8), seperator: u8) Self {
        return .{
            .stream = stream,
            .seperator = seperator,
        };
    }

    /// Returns the next token in the stream, if at the end, returns `null`.
    pub fn next(self: *Self) ?[]u8 {
        if (self.finished) {
            return null;
        }
        for (self.stream.items[self.config_progress..], self.config_progress..) |c, i| {
            if (c != self.seperator) {
                continue;
            }

            const ret_value = self.stream.items[self.config_progress..i];
            self.config_progress = i + 1;
            return ret_value;
        }
        self.finished = true;
        return self.stream.items[self.config_progress..];
    }
};
