pub const Popup = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

wlr_xdg_popup: *wlr.XdgPopup,
wlr_scene_tree: *wlr.SceneTree,

commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),

pub fn create(wlr_xdg_popup: *wlr.XdgPopup) anyerror!void {
    const xdg_surface = wlr_xdg_popup.base;
    var scene_tree: *wlr.SceneTree = undefined;

    // Add to the scene graph so that it gets rendered.
    if (wlr_xdg_popup.parent) |xdg_popup_parent| { // Spawned by a XDG toplevel
        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup_parent) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
            return;
        };
        scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            owm.log.err("Failed to allocate XDG popup node");
            return;
        };
    } else { // Most likely spawned by a status bar
        scene_tree = owm.server.scene_tree_apps.createSceneXdgSurface(xdg_surface) catch {
            owm.log.err("Failed to allocate XDG popup node");
            return;
        };
    }

    xdg_surface.data = scene_tree;

    const popup = try owm.c_alloc.create(Popup);
    errdefer owm.c_alloc.destroy(popup);

    popup.* = .{
        .wlr_xdg_popup = wlr_xdg_popup,
        .wlr_scene_tree = scene_tree,
    };

    xdg_surface.surface.events.commit.add(&popup.commit_listener);
    wlr_xdg_popup.events.destroy.add(&popup.destroy_listener);
}

/// Called when a new surface state is commited
fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const popup: *Popup = @fieldParentPtr("commit_listener", listener);
    if (popup.wlr_xdg_popup.base.initial_commit) {
        _ = popup.wlr_xdg_popup.base.scheduleConfigure();
    }
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const popup: *Popup = @fieldParentPtr("destroy_listener", listener);

    popup.commit_listener.link.remove();
    popup.destroy_listener.link.remove();

    owm.c_alloc.destroy(popup);
}
