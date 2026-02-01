const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

pub const Popup = struct {
    _wlr_xdg_popup: *wlr.XdgPopup,

    _commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
    _destroy_listener: wl.Listener(void) = .init(destroyCallback),

    pub fn create(wlr_xdg_popup: *wlr.XdgPopup) anyerror!void {
        const xdg_surface = wlr_xdg_popup.base;
        // Add to the scene graph so that it gets rendered.
        const parent = wlr.XdgSurface.tryFromWlrSurface(wlr_xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
            return;
        };
        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to allocate xdg popup node", .{});
            return;
        };
        xdg_surface.data = scene_tree;

        const popup = try owm.allocator.create(Popup);
        errdefer owm.allocator.destroy(popup);

        popup.* = .{
            ._wlr_xdg_popup = wlr_xdg_popup,
        };

        xdg_surface.surface.events.commit.add(&popup._commit_listener);
        wlr_xdg_popup.events.destroy.add(&popup._destroy_listener);
    }
};

/// Called when a new surface state is commited
fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const popup: *Popup = @fieldParentPtr("_commit_listener", listener);
    if (popup._wlr_xdg_popup.base.initial_commit) {
        _ = popup._wlr_xdg_popup.base.scheduleConfigure();
    }
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const popup: *Popup = @fieldParentPtr("_destroy_listener", listener);

    popup._commit_listener.link.remove();
    popup._destroy_listener.link.remove();

    owm.allocator.destroy(popup);
}
