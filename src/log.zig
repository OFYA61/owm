const std = @import("std");
const builtin = @import("builtin");

const owm = @import("root").owm;

const MAX_LOG_FILE_COUNT = 48;

var log_file: std.Io.File = undefined;
var log_file_buffer: [4096]u8 = undefined;
var file_buffered_writer: std.Io.File.Writer = undefined;
var log_mutex: std.Io.Mutex = .{ .state = .init(.unlocked) };
const is_debug = builtin.mode == .Debug;

pub fn init() !void {
    const home = owm.env.getVar("HOME");
    const appDataDir = try std.fs.path.join(owm.alloc, &.{ home, ".local", "share", "owm" });
    defer owm.alloc.free(appDataDir);
    std.Io.Dir.createDirAbsolute(owm.getIo(), appDataDir, .default_dir) catch |err_create_dir| {
        if (err_create_dir != error.PathAlreadyExists) {
            return err_create_dir;
        }
    };

    const logs_dir_path = try std.fs.path.join(owm.alloc, &.{ appDataDir, "logs" });
    defer owm.alloc.free(logs_dir_path);
    std.Io.Dir.createDirAbsolute(owm.getIo(), logs_dir_path, .default_dir) catch |dir_err| {
        if (dir_err != error.PathAlreadyExists) {
            return dir_err;
        }
    };

    try cleanupOldLogs(appDataDir);

    const now = owm.time.nowUnixSecs();
    const file_name = try std.fmt.allocPrint(owm.alloc, "log-{d}.log", .{now});
    defer owm.alloc.free(file_name);

    const full_log_file_path = try std.fs.path.join(owm.alloc, &.{ logs_dir_path, file_name });
    defer owm.alloc.free(full_log_file_path);

    std.debug.print("LOG FILE PATH: {s}\n", .{full_log_file_path});
    log_file = try std.Io.Dir.createFileAbsolute(owm.getIo(), full_log_file_path, .{});
    file_buffered_writer = log_file.writer(owm.getIo(), &log_file_buffer);
}

pub fn deinit() void {
    file_buffered_writer.flush() catch {};
    log_file.close(owm.getIo());
}

pub fn flush() void {
    log_mutex.lock(owm.getIo()) catch {};
    defer log_mutex.unlock(owm.getIo());
    file_buffered_writer.flush() catch {};
}

fn logImpl(
    comptime level: std.log.Level,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!is_debug and level == .debug) return;

    log_mutex.lock(owm.getIo()) catch {};
    defer log_mutex.unlock(owm.getIo());

    const now = owm.time.nowUnixSecs();
    const epoch = std.time.epoch.EpochSeconds{ .secs = now };
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();

    const color_code = switch (level) {
        .err => "\x1b[31m", // Red
        .warn => "\x1b[33m", // Yellow (Orange-ish)
        .info => "\x1b[37m", // White
        .debug => "\x1b[36m", // Cyan (Lighter, softer blue)
    };
    const reset = "\x1b[0m";

    const level_str = switch (level) {
        .err => "[ERROR]",
        .warn => "[WARN] ",
        .info => "[INFO] ",
        .debug => "[DEBUG]",
    };

    // Format: [YYYY-MM-DD HH:MM:SS] [LEVEL] message
    const log_metadata = std.fmt.allocPrint(owm.alloc, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}] {s} ", .{
        year_day.year,              month_day.month.numeric(),     month_day.day_index + 1,
        day_secs.getHoursIntoDay(), day_secs.getMinutesIntoHour(), day_secs.getSecondsIntoMinute(),
        level_str,
    }) catch unreachable;
    defer owm.alloc.free(log_metadata);

    const log_text = std.fmt.allocPrint(owm.alloc, fmt, args) catch unreachable;
    defer owm.alloc.free(log_text);

    const final_log = std.fmt.allocPrint(owm.alloc, "{s} {s}\n", .{ log_metadata, log_text }) catch unreachable;
    defer owm.alloc.free(final_log);

    // Output to Terminal
    std.debug.print("{s}{s}{s}", .{ color_code, final_log, reset });

    // Output to File
    log_file.writeStreamingAll(owm.getIo(), final_log) catch unreachable;
    if (is_debug) {
        file_buffered_writer.flush() catch {};
    }
}

pub fn debug(message: []const u8) void {
    logImpl(.debug, "{s}", .{message});
}

pub fn debugf(comptime fmt: []const u8, args: anytype) void {
    logImpl(.debug, fmt, args);
}

pub fn info(message: []const u8) void {
    logImpl(.info, "{s}", .{message});
}

pub fn infof(comptime fmt: []const u8, args: anytype) void {
    logImpl(.info, fmt, args);
}

pub fn warn(message: []const u8) void {
    logImpl(.warn, "{s}", .{message});
}

pub fn warnf(comptime fmt: []const u8, args: anytype) void {
    logImpl(.warn, fmt, args);
}

pub fn err(message: []const u8) void {
    logImpl(.err, "{s}", .{message});
}

pub fn errf(comptime fmt: []const u8, args: anytype) void {
    logImpl(.err, fmt, args);
}

const LogFile = struct {
    name: []u8,
    mtime: i96,
};

fn cleanupOldLogs(appDataDir: []const u8) !void {
    const dir_path = try std.fs.path.join(owm.alloc, &.{ appDataDir, "logs" });
    defer owm.alloc.free(dir_path);

    var dir = try std.Io.Dir.openDirAbsolute(owm.getIo(), dir_path, .{ .iterate = true });
    defer dir.close(owm.getIo());

    var files: std.ArrayList(LogFile) = .empty;
    defer {
        for (files.items) |file| owm.alloc.free(file.name);
        files.deinit(owm.alloc);
    }

    var it = dir.iterate();
    while (try it.next(owm.getIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;

        const stats = try dir.statFile(owm.getIo(), entry.name, .{});
        try files.append(owm.alloc, LogFile{
            .name = try owm.alloc.dupe(u8, entry.name),
            .mtime = stats.mtime.nanoseconds,
        });
    }

    if (files.items.len <= MAX_LOG_FILE_COUNT - 1) return;

    const ComparisonFn = struct {
        fn call(_: void, l1: LogFile, l2: LogFile) bool {
            return l1.mtime > l2.mtime;
        }
    }.call;

    std.mem.sort(LogFile, files.items, {}, ComparisonFn);

    for (files.items[MAX_LOG_FILE_COUNT - 1 ..]) |file| {
        try dir.deleteFile(owm.getIo(), file.name);
    }
}
