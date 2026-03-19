const XWaylandWindow = @This();

const owm = @import("owm.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

wlr_xwayland_surface: *wlr.XwaylandSurface,
wlr_scene_tree: ?*wlr.SceneTree = null,
managed_window: owm.ManagedWindow,
current_output: *owm.Output,

x: i32 = 0,
y: i32 = 0,

request_configure_listener: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(requestConfigureCallback),
map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
associate_listener: wl.Listener(void) = .init(associateCallback),
dissociate_listener: wl.Listener(void) = .init(dissociateCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),

pub fn create(wlr_xwayland_surface: *wlr.XwaylandSurface) error{ OutOfMemory, CursorNotOnOutput }!*XWaylandWindow {
    const xwayland_window = try owm.c_alloc.create(XWaylandWindow);
    errdefer owm.c_alloc.destroy(xwayland_window);

    const output = owm.server.outputAtCursor() orelse return error.CursorNotOnOutput;

    xwayland_window.* = .{
        .wlr_xwayland_surface = wlr_xwayland_surface,
        .managed_window = owm.ManagedWindow.xWaylandWindow(xwayland_window),
        .current_output = output,
    };
    wlr_xwayland_surface.events.request_configure.add(&xwayland_window.request_configure_listener);
    wlr_xwayland_surface.events.associate.add(&xwayland_window.associate_listener);
    wlr_xwayland_surface.events.dissociate.add(&xwayland_window.dissociate_listener);
    wlr_xwayland_surface.events.destroy.add(&xwayland_window.destroy_listener);

    return xwayland_window;
}

fn requestConfigureCallback(listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure), configure: *wlr.XwaylandSurface.event.Configure) void {
    const xwayland_window: *XWaylandWindow = @fieldParentPtr("request_configure_listener", listener);
    if (xwayland_window.wlr_xwayland_surface.surface == null or !xwayland_window.wlr_xwayland_surface.surface.?.mapped) {
        xwayland_window.wlr_xwayland_surface.configure(configure.x, configure.y, configure.width, configure.height);
        return;
    }
}

fn associateCallback(listener: *wl.Listener(void)) void {
    const xwayland_window: *XWaylandWindow = @fieldParentPtr("associate_listener", listener);
    if (xwayland_window.wlr_xwayland_surface.surface == null) {
        owm.log.err("XWaylandWindow: Got associate callback without a valid surface");
        return;
    }

    const surface = xwayland_window.wlr_xwayland_surface.surface.?;
    surface.events.map.add(&xwayland_window.map_listener);
    surface.events.unmap.add(&xwayland_window.unmap_listener);
}

fn dissociateCallback(listener: *wl.Listener(void)) void {
    const xwayland_window: *XWaylandWindow = @fieldParentPtr("dissociate_listener", listener);

    xwayland_window.map_listener.link.remove();
    xwayland_window.unmap_listener.link.remove();
}

fn mapCallback(listener: *wl.Listener(void)) void {
    const xwayland_window: *XWaylandWindow = @fieldParentPtr("map_listener", listener);
    const surface = xwayland_window.wlr_xwayland_surface.surface.?;

    surface.events.commit.add(&xwayland_window.commit_listener);

    if (xwayland_window.wlr_xwayland_surface.override_redirect) {
        owm.log.debug("XWaylandWindow: Creating subsurface for menu");
        xwayland_window.wlr_scene_tree = owm.server.scene_tree_apps.createSceneSubsurfaceTree(surface) catch {
            owm.log.err("XWaylandWindow: Failed to create subsurface for menu");
            return;
        };
        xwayland_window.wlr_scene_tree.?.node.raiseToTop();
    } else {
        owm.log.debug("XWaylandWindow: Creating subsurface for app");
        xwayland_window.wlr_scene_tree = owm.server.scene_tree_apps.createSceneSubsurfaceTree(surface) catch {
            owm.log.err("XWaylandWindow: Failed to create subsurface for app");
            return;
        };
    }
    xwayland_window.wlr_scene_tree.?.node.setPosition(
        xwayland_window.wlr_xwayland_surface.x,
        xwayland_window.wlr_xwayland_surface.y,
    );
    xwayland_window.wlr_xwayland_surface.activate(true);
    xwayland_window.x = xwayland_window.wlr_scene_tree.?.node.x;
    xwayland_window.y = xwayland_window.wlr_scene_tree.?.node.y;
    xwayland_window.wlr_scene_tree.?.node.data = &xwayland_window.managed_window;
}

fn unmapCallback(listener: *wl.Listener(void)) void {
    const xwayland_window: *XWaylandWindow = @fieldParentPtr("unmap_listener", listener);

    xwayland_window.commit_listener.link.remove();
    xwayland_window.wlr_scene_tree.?.node.destroy();
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), wlr_surface: *wlr.Surface) void {
    const xwayland_window: *XWaylandWindow = @fieldParentPtr("commit_listener", listener);
    _ = xwayland_window;
    _ = wlr_surface;
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const xwayland_window: *XWaylandWindow = @fieldParentPtr("destroy_listener", listener);

    xwayland_window.request_configure_listener.link.remove();
    xwayland_window.associate_listener.link.remove();
    xwayland_window.dissociate_listener.link.remove();
    xwayland_window.destroy_listener.link.remove();

    owm.c_alloc.destroy(xwayland_window);
}
