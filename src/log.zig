const std = @import("std");
const builtin = @import("builtin");

const logly = @import("logly");

const MAX_LOG_FILE_COUNT = 48;

var log: *logly.Logger = undefined;

pub fn init() anyerror!void {
    const alloc = std.heap.page_allocator;
    const appDataDir = try std.fs.getAppDataDir(alloc, "owm");
    try cleanupOldLogs(alloc, appDataDir);
    log = try logly.Logger.init(std.heap.page_allocator);

    const file_name = try std.fmt.allocPrint(alloc, "logs/log-{d}.log", .{std.time.milliTimestamp()});
    const full_log_file_path = try std.fs.path.join(alloc, &.{ appDataDir, file_name });

    var config = logly.Config.default();
    if (builtin.mode == .Debug) {
        config.level = .debug;
        config.auto_flush = true;
        config.show_filename = true;
        config.show_lineno = true;
    } else {
        config.level = .info;
        config.auto_flush = false;
        config.show_filename = false;
        config.show_lineno = false;
    }
    config.show_time = true;
    log.configure(config);

    _ = try log.add(.{
        .path = full_log_file_path,
        .rotation = "hourly",
        .retention = 24,
        .color = false,
    });
}

const LogFile = struct {
    name: []u8,
    mtime: i128,
};

fn cleanupOldLogs(alloc: std.mem.Allocator, appDataDir: []const u8) !void {
    const dir_path = try std.fs.path.join(alloc, &.{ appDataDir, "logs" });
    var dir = try std.fs.cwd().makeOpenPath(dir_path, .{ .iterate = true });
    defer dir.close();

    var files: std.ArrayList(LogFile) = .empty;
    defer files.deinit(alloc);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".log")) {
            continue;
        }

        const stats = try dir.statFile(entry.name);
        try files.append(alloc, LogFile{
            .name = try alloc.dupe(u8, entry.name),
            .mtime = stats.mtime,
        });
    }

    if (files.items.len <= MAX_LOG_FILE_COUNT - 1) {
        return;
    }

    const ComparisonFn = struct {
        fn call(_: void, l1: LogFile, l2: LogFile) bool {
            return l1.mtime > l2.mtime;
        }
    }.call;
    std.mem.sort(LogFile, files.items, {}, ComparisonFn);
    for (files.items[MAX_LOG_FILE_COUNT - 1 ..]) |file| {
        try dir.deleteFile(file.name);
    }
}

pub fn deinit() void {
    log.deinit();
}

pub fn debug(comptime fmt: []const u8, args: anytype, src: ?std.builtin.SourceLocation) void {
    log.debugf(fmt, args, src) catch unreachable;
}

pub fn info(comptime fmt: []const u8, args: anytype, src: ?std.builtin.SourceLocation) void {
    log.infof(fmt, args, src) catch |e| {
        std.debug.print("{}", .{e});
    };
}

pub fn err(comptime fmt: []const u8, args: anytype, src: ?std.builtin.SourceLocation) void {
    log.errf(fmt, args, src) catch unreachable;
}
