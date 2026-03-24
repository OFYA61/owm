const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;

wlr_xwayland_surface: *wlr.XwaylandSurface,
current_output: *owm.Output,

request_configure_listener: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(requestConfigureCallback),
map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
associate_listener: wl.Listener(void) = .init(associateCallback),
dissociate_listener: wl.Listener(void) = .init(dissociateCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),

pub fn create(wlr_xwayland_surface: *wlr.XwaylandSurface) client.Error!Self {
    const output = owm.server.outputAtCursor() orelse return client.Error.CursorNotOnOutput;

    return .{
        .wlr_xwayland_surface = wlr_xwayland_surface,
        .current_output = output,
    };
}

pub fn setup(self: *Self) void {
    self.wlr_xwayland_surface.events.request_configure.add(&self.request_configure_listener);
    self.wlr_xwayland_surface.events.associate.add(&self.associate_listener);
    self.wlr_xwayland_surface.events.dissociate.add(&self.dissociate_listener);
    self.wlr_xwayland_surface.events.destroy.add(&self.destroy_listener);
}

fn requestConfigureCallback(listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure), configure: *wlr.XwaylandSurface.event.Configure) void {
    const xwayland: *Self = @fieldParentPtr("request_configure_listener", listener);
    if (xwayland.wlr_xwayland_surface.surface == null or !xwayland.wlr_xwayland_surface.surface.?.mapped) {
        xwayland.wlr_xwayland_surface.configure(configure.x, configure.y, configure.width, configure.height);
        return;
    }
}

fn associateCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("associate_listener", listener);
    if (xwayland.wlr_xwayland_surface.surface == null) {
        owm.log.err("Self: Got associate callback without a valid surface");
        return;
    }

    const surface = xwayland.wlr_xwayland_surface.surface.?;
    surface.events.map.add(&xwayland.map_listener);
    surface.events.unmap.add(&xwayland.unmap_listener);
}

fn dissociateCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("dissociate_listener", listener);

    xwayland.map_listener.link.remove();
    xwayland.unmap_listener.link.remove();
}

fn mapCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("map_listener", listener);
    const surface = xwayland.wlr_xwayland_surface.surface.?;

    surface.events.commit.add(&xwayland.commit_listener);

    const xwayland_client = client.Client.from(xwayland);

    if (xwayland.wlr_xwayland_surface.override_redirect) {
        owm.log.debug("Self: Creating subsurface for menu");
        xwayland_client.wlr_scene_tree = owm.server.scene_tree_apps.createSceneSubsurfaceTree(surface) catch {
            owm.log.err("Self: Failed to create subsurface for menu");
            return;
        };
        xwayland_client.wlr_scene_tree.node.raiseToTop();
    } else {
        owm.log.debug("Self: Creating subsurface for app");
        xwayland_client.wlr_scene_tree = owm.server.scene_tree_apps.createSceneSubsurfaceTree(surface) catch {
            owm.log.err("Self: Failed to create subsurface for app");
            return;
        };
    }
    xwayland.wlr_xwayland_surface.activate(true);
    xwayland_client.setPos(xwayland_client.wlr_scene_tree.node.x, xwayland_client.wlr_scene_tree.node.y);
    xwayland_client.wlr_scene_tree.node.data = xwayland_client;
}

fn unmapCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("unmap_listener", listener);

    const xwayland_client = client.Client.from(xwayland);

    xwayland.commit_listener.link.remove();
    xwayland_client.wlr_scene_tree.node.destroy();
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), wlr_surface: *wlr.Surface) void {
    const xwayland: *Self = @fieldParentPtr("commit_listener", listener);
    _ = xwayland;
    _ = wlr_surface;
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("destroy_listener", listener);

    xwayland.request_configure_listener.link.remove();
    xwayland.associate_listener.link.remove();
    xwayland.dissociate_listener.link.remove();
    xwayland.destroy_listener.link.remove();

    owm.c_alloc.destroy(client.Client.from(xwayland));
}
