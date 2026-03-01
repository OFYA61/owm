const ManagedWindow = @This();

const owm = @import("owm.zig");
const wlr = @import("wlroots");

window: union(enum) {
    Toplevel: *owm.Toplevel,
    LayerSurface: *owm.LayerSurface,
    Popup: *owm.Popup,
},

pub fn fromOpaquePtr(ptr: ?*anyopaque) ?*ManagedWindow {
    return @as(?*ManagedWindow, @ptrCast(@alignCast(ptr)));
}

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

pub fn popup(pu: *owm.Popup) ManagedWindow {
    return .{
        .window = .{
            .Popup = pu,
        },
    };
}

pub fn getUnconstrainBox(self: ManagedWindow) wlr.Box {
    var unconstrainBox: wlr.Box = undefined;
    switch (self.window) {
        .Toplevel => |tl| {
            unconstrainBox = tl.current_output.area;
            unconstrainBox.x -= tl.x;
            unconstrainBox.y -= tl.y;
        },
        .LayerSurface => |ls| {
            unconstrainBox = ls.output.area;
            unconstrainBox.x -= ls.x;
            unconstrainBox.y -= ls.y;
        },
        .Popup => |pu| {
            unconstrainBox = pu.parent.getUnconstrainBox();
        },
    }

    return unconstrainBox;
}
