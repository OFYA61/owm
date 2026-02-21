const ManagedWindow = @This();

const owm = @import("owm.zig");

window: union(enum) {
    Toplevel: *owm.Toplevel,
    LayerSurface: *owm.LayerSurface,
},

pub fn toplevel(tl: *owm.Toplevel) ManagedWindow {
    return .{
        .window = .{
            .Toplevel = tl,
        },
    };
}

pub fn layerSurface(ls: *owm.LayerSurface) ManagedWindow {
    return .{
        .window = .{
            .LayerSurface = ls,
        },
    };
}
