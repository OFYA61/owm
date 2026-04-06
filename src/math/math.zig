pub fn Vec2(comptime T: type) type {
    switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => {},
        else => @compileError("The given type is not a number"),
    }

    return struct {
        const Self = @This();
        x: T,
        y: T,

        pub fn intoInt(self: *const Self, comptime NT: type) Vec2(NT) {
            switch (@typeInfo(T)) {
                .float, .comptime_float => {},
                else => @compileError("Cannot call this method on non-float vectors"),
            }

            return .{
                .x = @as(NT, @intFromFloat(self.x)),
                .y = @as(NT, @intFromFloat(self.y)),
            };
        }

        pub fn intoFloat(self: *const Self, comptime NT: type) Vec2(NT) {
            switch (@typeInfo(T)) {
                .int, .comptime_int => {},
                else => @compileError("Cannot call this method on non-int vectors"),
            }

            return .{
                .x = @as(NT, @floatFromInt(self.x)),
                .y = @as(NT, @floatFromInt(self.y)),
            };
        }
    };
}
