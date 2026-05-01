const std = @import("std");
const posix = std.posix;

pub fn timeSinceStart() posix.timespec {
    var time: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &time))) {
        .SUCCESS => return time,
        else => @panic("CLOCK_MONOTONIC not supported"),
    }
}

pub fn timeSinceEpoch() posix.timespec {
    var time: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.REALTIME, &time))) {
        .SUCCESS => return time,
        else => @panic("CLOCK_REALTIME not supported"),
    }
}

pub fn nowUnixSecs() u64 {
    const now = timeSinceEpoch();
    return @intCast(now.sec);
}
