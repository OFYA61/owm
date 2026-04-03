pub fn Vec2(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}
