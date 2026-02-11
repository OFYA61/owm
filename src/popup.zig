const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

pub const Popup = struct {
    wlr_xdg_popup: *wlr.XdgPopup,
    wlr_scene_tree: *wlr.SceneTree,

    commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
    destroy_listener: wl.Listener(void) = .init(destroyCallback),

    pub fn create(wlr_xdg_popup: *wlr.XdgPopup) anyerror!void {
        const xdg_surface = wlr_xdg_popup.base;
        // Add to the scene graph so that it gets rendered.
        const parent = wlr.XdgSurface.tryFromWlrSurface(wlr_xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
            return;
        };
        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            owm.log.err("failed to allocate xdg popup node", .{});
            return;
        };
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
};

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
