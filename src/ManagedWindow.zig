const ManagedWindow = @This();

const owm = @import("owm.zig");
const wlr = @import("wlroots");

window: union(enum) {
    Toplevel: *owm.Toplevel,
    LayerSurface: *owm.LayerSurface,
    Popup: *owm.Popup,
    XWaylandWindow: *owm.XWaylandWindow,
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

pub fn xWaylandWindow(xww: *owm.XWaylandWindow) ManagedWindow {
    return .{
        .window = .{
            .XWaylandWindow = xww,
        },
    };
}

pub fn getUnconstrainBox(self: *ManagedWindow) wlr.Box {
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
        .XWaylandWindow => |xww| {
            unconstrainBox = xww.current_output.area;
            unconstrainBox.x -= xww.x;
            unconstrainBox.y -= xww.y;
        },
    }

    return unconstrainBox;
}

pub fn getSceneTree(self: *ManagedWindow) error{SceneTreeNotFound}!*wlr.SceneTree {
    var scene_tree: *wlr.SceneTree = undefined;
    switch (self.window) {
        .Toplevel => |tl| {
            scene_tree = tl.wlr_scene_tree;
        },
        .LayerSurface => |ls| {
            scene_tree = ls.wlr_scene_layer_surface.tree;
        },
        .Popup => |pu| {
            scene_tree = pu.wlr_scene_tree;
        },
        .XWaylandWindow => |xww| {
            scene_tree = xww.wlr_scene_tree orelse return error.SceneTreeNotFound;
        },
    }

    return scene_tree;
}
