pub const Popup = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

var idx: usize = 0;

id: usize,
wlr_xdg_popup: *wlr.XdgPopup,
wlr_scene_tree: *wlr.SceneTree,
parent: owm.ManagedWindow,

commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
reposition_listener: wl.Listener(void) = .init(repositionCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),

pub fn create(
    wlr_xdg_popup: *wlr.XdgPopup,
    parent: *owm.ManagedWindow,
) error{
    FailedToCreateSceneTree,
    OutOfMemory,
}!*Popup {
    defer idx += 1;
    const xdg_surface = wlr_xdg_popup.base;
    var scene_tree: *wlr.SceneTree = undefined;

    switch (parent.window) {
        .Toplevel => |toplevel| {
            scene_tree = toplevel.wlr_scene_tree.createSceneXdgSurface(xdg_surface) catch {
                owm.log.err("Failed to create scene tree for popup");
                return error.FailedToCreateSceneTree;
            };
        },
        .LayerSurface => |layer_surface| {
            scene_tree = layer_surface.wlr_scene_layer_surface.tree.createSceneXdgSurface(xdg_surface) catch {
                owm.log.err("Failed to create scene tree for popup");
                return error.FailedToCreateSceneTree;
            };
        },
    }

    xdg_surface.data = scene_tree;

    const popup = try owm.c_alloc.create(Popup);
    errdefer owm.c_alloc.destroy(popup);

    popup.* = .{
        .id = idx,
        .wlr_xdg_popup = wlr_xdg_popup,
        .wlr_scene_tree = scene_tree,
        .parent = parent.*,
    };

    xdg_surface.surface.events.commit.add(&popup.commit_listener);
    wlr_xdg_popup.events.reposition.add(&popup.reposition_listener);
    wlr_xdg_popup.events.destroy.add(&popup.destroy_listener);

    return popup;
}

fn unconstrain(self: *Popup) void {
    var unconstrainBox: wlr.Box = undefined;
    switch (self.parent.window) {
        .Toplevel => |toplevel| {
            unconstrainBox = toplevel.current_output.area;
            unconstrainBox.x -= toplevel.x;
            unconstrainBox.y -= toplevel.y;
        },
        .LayerSurface => |layer_surface| {
            unconstrainBox = layer_surface.output.area;
            unconstrainBox.x -= layer_surface.x;
            unconstrainBox.y -= layer_surface.y;
        },
    }
    self.wlr_xdg_popup.unconstrainFromBox(&unconstrainBox);
}

/// Called when a new surface state is commited
fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const popup: *Popup = @fieldParentPtr("commit_listener", listener);
    if (popup.wlr_xdg_popup.base.initial_commit) {
        popup.unconstrain();
        _ = popup.wlr_xdg_popup.base.scheduleConfigure();
    }
}

fn repositionCallback(listener: *wl.Listener(void)) void {
    const popup: *Popup = @fieldParentPtr("reposition_listener", listener);
    popup.unconstrain();
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const popup: *Popup = @fieldParentPtr("destroy_listener", listener);

    popup.commit_listener.link.remove();
    popup.reposition_listener.link.remove();
    popup.destroy_listener.link.remove();

    owm.c_alloc.destroy(popup);
}
