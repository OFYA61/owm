//! Contains utilities used by the config files

const std = @import("std");

const owm = @import("root").owm;
const log = owm.log;

pub const alloc = @import("root").owm.alloc;

pub const FileError = error{
    FailedToCreateDirectory,
    FailedToCreateFile,
    FailedToGetDirectory,
    FailedToOpenFile,
    FailedToReadFile,
    FailedToWriteFile,
    FileDoesNotExist,
    MissingHomeEnvironmentVariable,
};

pub const ParseError = error{
    NotANumber,
    InvalidFormat,
    InvalidModifier,
};

/// Loads the file contents as raw string. The caller is repsonsible for freeing up the memory.
pub fn loadRaw(file_path: []const u8) FileError![]u8 {
    const file = openConfigFile(.read_only, file_path) catch {
        return FileError.FailedToOpenFile;
    };
    defer file.close(owm.getIo());

    const file_end_pos = file.length(owm.getIo()) catch |err| {
        log.errf("Config: Failed to read config file '{s}' with error {}", .{ file_path, err });
        return FileError.FailedToOpenFile;
    };

    const buf: []u8 = owm.alloc.alloc(u8, file_end_pos) catch unreachable;
    _ = file.readPositionalAll(owm.getIo(), buf, 0) catch |err| {
        log.errf("Config: Failed to read config file '{s}' with error {}", .{ file_path, err });
        return FileError.FailedToReadFile;
    };
    return buf;
}

/// Opens the given config file from the root of the config directory.
/// Caller is responsible for closing the file
fn openConfigFile(mode: std.Io.File.OpenMode, relative_path: []const u8) !std.Io.File {
    log.infof("Config: Attempting to open existing file '{s}'", .{relative_path});

    const full_path = getFullConfigFilePath(relative_path);
    defer owm.alloc.free(full_path);

    return std.Io.Dir.openFileAbsolute(owm.getIo(), full_path, .{ .mode = mode }) catch |err| {
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

    std.Io.Dir.accessAbsolute(owm.getIo(), full_path, .{ .read = true }) catch {
        return false;
    };

    return true;
}

/// Ensures that the given file exists, if it doesn not, it creates one with the provided default value
pub fn ensureConfigFileExists(default_value: []const u8, relative_path: []const u8) FileError!enum { created, exists } {
    const full_path = getFullConfigFilePath(relative_path);
    defer owm.alloc.free(full_path);

    const file_check = std.Io.Dir.openFileAbsolute(owm.getIo(), full_path, .{ .mode = .read_only });

    if (file_check) |file| {
        file.close(owm.getIo());
        return .created;
    } else |err| {
        if (err != error.FileNotFound) return {
            log.errf("Config: Failed to open '{s}' with error {}", .{ relative_path, err });
            return FileError.FailedToOpenFile;
        };

        if (std.Io.Dir.path.dirname(full_path)) |dir| {
            std.Io.Dir.createDirAbsolute(owm.getIo(), dir, .default_dir) catch |dir_err| {
                if (dir_err != error.PathAlreadyExists) {
                    return FileError.FailedToCreateDirectory;
                }
                log.warnf("Config: Failed to create directory '{s}', it might already exist", .{dir});
            };
        }

        const file = std.Io.Dir.createFileAbsolute(owm.getIo(), full_path, .{}) catch |err_create| {
            log.errf("Config: Failed to create file '{s}' with error {}", .{ relative_path, err_create });
            return FileError.FailedToCreateFile;
        };
        defer file.close(owm.getIo());

        file.writeStreamingAll(owm.getIo(), default_value) catch {
            log.errf("Config: Failed to write to file '{s}'", .{full_path});
            return FileError.FailedToWriteFile;
        };
    }
    return .exists;
}

pub fn writeRaw(contents: []const u8, relative_path: []const u8) FileError!void {
    const full_path = getFullConfigFilePath(relative_path);
    defer owm.alloc.free(full_path);
    const file = std.Io.Dir.openFileAbsolute(owm.getIo(), full_path, .{ .mode = .write_only }) catch |err_open| {
        log.errf("Config: Failed to open file '{s}' with error {}", .{ relative_path, err_open });
        return FileError.FailedToOpenFile;
    };
    file.writeStreamingAll(owm.getIo(), contents) catch |err_write| {
        log.errf("Config: Failed to write to file '{s}' with error {}", .{ relative_path, err_write });
        return FileError.FailedToWriteFile;
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
fn getFullConfigFilePath(relative_path: []const u8) []u8 {
    const home = owm.env.getHome();
    return std.Io.Dir.path.join(alloc, &.{ home, ".config", "owm", relative_path }) catch @panic("Failed to open file");
}

/// Utility to tokenize an array of characters given a separator character
/// Example usage
/// ```zig
/// const stream_raw: [] u8 = "Some stream";
/// var tokenizer: Tokenizer = .create(stream_raw, ' ');
///
/// while (tokenizer.next()) |token| {
///     // Process token
/// }
/// ```
pub const Tokenizer = struct {
    const Self = @This();

    stream: []u8,
    seperator: u8,
    progress: usize = 0,
    finished: bool = false,

    /// The caller owns the `stream` and only passes a reference to the `Tokenizer`
    /// The `Tokenizer` will NOT free any memory once it's done.
    pub fn create(stream: []u8, seperator: u8) Self {
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
        for (self.stream[self.progress..], self.progress..) |c, i| {
            if (c != self.seperator) {
                continue;
            }

            const ret_value = self.stream[self.progress..i];
            self.progress = i + 1;
            return ret_value;
        }
        self.finished = true;
        return self.stream[self.progress..];
    }
};

/// Removes all whitespace characters from the array and returns an newly allocated array.
/// Caller is responsible for freeing the array after use.
pub fn removeWhiteSpaces(str: []const u8) std.ArrayList(u8) {
    var array: std.ArrayList(u8) = std.ArrayList(u8).initCapacity(owm.alloc, str.len) catch unreachable;
    for (str) |c| {
        switch (c) {
            ' ', '\t', '\r' => continue,
            else => array.append(owm.alloc, c) catch unreachable,
        }
    }
    return array;
}
