const std = @import("std");
const posix = std.posix;

const owm = @import("root").owm;
const log = owm.log;

pub fn init() void {
    const sig_ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sig_ign, null);
}

pub fn spawnProcess(command: [:0]const u8) void {
    log.infof("Process: Spawning process '{s}'", .{command});
    spawnProcessWithArgs(&.{ "/bin/sh", "-c", command });
}

pub fn spawnProcessWithArgs(argv: []const []const u8) void {
    _ = std.process.spawn(owm.getIo(), .{
        .argv = argv,
        .environ_map = owm.env.getEnv(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        log.errf("Process: Failed to spawn process with error {}", .{err});
    };
}
