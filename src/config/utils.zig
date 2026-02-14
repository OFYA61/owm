const std = @import("std");

pub const alloc = std.heap.page_allocator;

pub fn parseJsonSlice(comptime T: type, slice: []const u8) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    return std.json.parseFromSlice(
        T,
        alloc,
        slice,
        .{ .ignore_unknown_fields = true },
    );
}
