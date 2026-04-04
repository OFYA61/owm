const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;
const log = owm.log;

wlr_xwayland_surface: *wlr.XwaylandSurface,
wlr_scene_tree: ?*wlr.SceneTree = null,

request_configure_listener: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(requestConfigureCallback),
map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
associate_listener: wl.Listener(void) = .init(associateCallback),
dissociate_listener: wl.Listener(void) = .init(dissociateCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),

pub fn create(wlr_xwayland_surface: *wlr.XwaylandSurface) client.Error!*Self {
    var self = try owm.c_alloc.create(Self);
    errdefer owm.c_alloc.destroy(self);

    self.* = .{
        .wlr_xwayland_surface = wlr_xwayland_surface,
    };

    self.wlr_xwayland_surface.events.request_configure.add(&self.request_configure_listener);
    self.wlr_xwayland_surface.events.associate.add(&self.associate_listener);
    self.wlr_xwayland_surface.events.dissociate.add(&self.dissociate_listener);
    self.wlr_xwayland_surface.events.destroy.add(&self.destroy_listener);

    return self;
}

fn requestConfigureCallback(listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure), configure: *wlr.XwaylandSurface.event.Configure) void {
    const xwayland_override: *Self = @fieldParentPtr("request_configure_listener", listener);
    if (xwayland_override.wlr_xwayland_surface.surface == null or !xwayland_override.wlr_xwayland_surface.surface.?.mapped) {
        xwayland_override.wlr_xwayland_surface.configure(configure.x, configure.y, configure.width, configure.height);
        return;
    }
}

fn associateCallback(listener: *wl.Listener(void)) void {
    const xwayland_override: *Self = @fieldParentPtr("associate_listener", listener);
    if (xwayland_override.wlr_xwayland_surface.surface == null) {
        log.err("Self: Got associate callback without a valid surface");
        return;
    }

    const surface = xwayland_override.wlr_xwayland_surface.surface.?;
    surface.events.map.add(&xwayland_override.map_listener);
    surface.events.unmap.add(&xwayland_override.unmap_listener);
}

fn dissociateCallback(listener: *wl.Listener(void)) void {
    const xwayland_override: *Self = @fieldParentPtr("dissociate_listener", listener);

    xwayland_override.map_listener.link.remove();
    xwayland_override.unmap_listener.link.remove();
}

fn mapCallback(listener: *wl.Listener(void)) void {
    const xwayland_override: *Self = @fieldParentPtr("map_listener", listener);
    const surface = xwayland_override.wlr_xwayland_surface.surface.?;

    surface.events.commit.add(&xwayland_override.commit_listener);

    xwayland_override.wlr_scene_tree = owm.server.scene.layers.override_redirect.createSceneSubsurfaceTree(surface) catch {
        log.err("XWayland: Failed to create subsurface for menu");
        return;
    };
    xwayland_override.wlr_scene_tree.?.node.raiseToTop();
    xwayland_override.wlr_xwayland_surface.activate(true);
    xwayland_override.wlr_scene_tree.?.node.setPosition(0, 0);
}

fn unmapCallback(listener: *wl.Listener(void)) void {
    const xwayland_override: *Self = @fieldParentPtr("unmap_listener", listener);

    xwayland_override.commit_listener.link.remove();
    xwayland_override.wlr_scene_tree.?.node.destroy();
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), wlr_surface: *wlr.Surface) void {
    const xwayland_override: *Self = @fieldParentPtr("commit_listener", listener);
    _ = xwayland_override;
    _ = wlr_surface;
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const xwayland_override: *Self = @fieldParentPtr("destroy_listener", listener);

    xwayland_override.request_configure_listener.link.remove();
    xwayland_override.associate_listener.link.remove();
    xwayland_override.dissociate_listener.link.remove();
    xwayland_override.destroy_listener.link.remove();

    owm.c_alloc.destroy(xwayland_override);
}
