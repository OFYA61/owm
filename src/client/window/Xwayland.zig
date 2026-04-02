const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;
const log = owm.log;
const window = owm.client.window;

wlr_xwayland_surface: *wlr.XwaylandSurface,
current_output: *owm.Output,
wlr_scene_tree: ?*wlr.SceneTree = null,
x: i32 = 0,
y: i32 = 0,

request_configure_listener: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(requestConfigureCallback),
map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
request_move_listener: wl.Listener(void) = .init(requestMoveCallback),
request_resize_listener: wl.Listener(*wlr.XwaylandSurface.event.Resize) = .init(requestResizeCallback),
associate_listener: wl.Listener(void) = .init(associateCallback),
dissociate_listener: wl.Listener(void) = .init(dissociateCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),

pub fn create(wlr_xwayland_surface: *wlr.XwaylandSurface) owm.client.Error!Self {
    const output = owm.server.outputAtCursor() orelse return owm.client.Error.CursorNotOnOutput;

    return .{
        .wlr_xwayland_surface = wlr_xwayland_surface,
        .current_output = output,
    };
}

pub fn setup(self: *Self) void {
    self.wlr_xwayland_surface.events.request_configure.add(&self.request_configure_listener);
    self.wlr_xwayland_surface.events.associate.add(&self.associate_listener);
    self.wlr_xwayland_surface.events.dissociate.add(&self.dissociate_listener);
    self.wlr_xwayland_surface.events.request_move.add(&self.request_move_listener);
    self.wlr_xwayland_surface.events.request_resize.add(&self.request_resize_listener);
    self.wlr_xwayland_surface.events.destroy.add(&self.destroy_listener);
}

pub fn setFocus(self: *Self, focus: bool) void {
    self.wlr_xwayland_surface.activate(focus);
}

pub fn toggleMaximize(self: *Self) void {
    // TODO: finish maximze code
    _ = self;
}

pub fn setPos(self: *Self, new_x: i32, new_y: i32) void {
    if (self.wlr_scene_tree) |scene_tree| {
        self.x = new_x;
        self.y = new_y;
        scene_tree.node.setPosition(new_x, new_y);
    }
}

pub fn setSize(self: *Self, new_width: u16, new_height: u16) void {
    self.wlr_xwayland_surface.configure(
        @as(i16, @intCast(self.x)),
        @as(i16, @intCast(self.y)),
        new_width,
        new_height,
    );
}

pub fn getGeom(self: *Self) wlr.Box {
    return .{
        .x = self.x,
        .y = self.y,
        .width = @as(i32, @intCast(self.wlr_xwayland_surface.width)),
        .height = @as(i32, @intCast(self.wlr_xwayland_surface.height)),
    };
}

fn requestConfigureCallback(listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure), configure: *wlr.XwaylandSurface.event.Configure) void {
    const xwayland: *Self = @fieldParentPtr("request_configure_listener", listener);
    if (xwayland.wlr_xwayland_surface.surface == null or !xwayland.wlr_xwayland_surface.surface.?.mapped) {
        xwayland.wlr_xwayland_surface.configure(configure.x, configure.y, configure.width, configure.height);
        return;
    }

    xwayland.wlr_xwayland_surface.configure(
        @as(i16, @intCast(xwayland.x)),
        @as(i16, @intCast(xwayland.y)),
        configure.width,
        configure.height,
    );
}

fn associateCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("associate_listener", listener);
    if (xwayland.wlr_xwayland_surface.surface == null) {
        log.err("Self: Got associate callback without a valid surface");
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

    xwayland.wlr_scene_tree = owm.server.scene_tree_apps.createSceneSubsurfaceTree(surface) catch {
        log.err("XWayland: Failed to create subsurface");
        return;
    };
    xwayland.wlr_xwayland_surface.activate(true);
    xwayland.setPos(xwayland.wlr_scene_tree.?.node.x, xwayland.wlr_scene_tree.?.node.y);

    const xwayland_window = window.Window.from(xwayland);
    xwayland.wlr_scene_tree.?.node.data = xwayland_window;
    owm.server.windows.prepend(xwayland_window);
    owm.server.focusWindow(xwayland_window);
}

fn unmapCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("unmap_listener", listener);

    const xwayland_window = window.Window.from(xwayland);

    xwayland.commit_listener.link.remove();
    xwayland_window.link.remove();
    xwayland.wlr_scene_tree.?.node.destroy();
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), wlr_surface: *wlr.Surface) void {
    const xwayland: *Self = @fieldParentPtr("commit_listener", listener);
    _ = xwayland;
    _ = wlr_surface;
}

fn requestMoveCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("request_move_listener", listener);
    const xwayland_window = window.Window.from(xwayland);

    if (xwayland.wlr_xwayland_surface.surface == null or !xwayland.wlr_xwayland_surface.surface.?.mapped) {
        return;
    }

    // TODO: handle moving while maximized
    // 1. Unmaximize
    // 2. Set to previous position

    owm.server.grabbed_window = xwayland_window;
    owm.server.cursor_mode = .move;
    owm.server.grab_x = owm.server.wlr_cursor.x - @as(f64, @floatFromInt(xwayland.x));
    owm.server.grab_y = owm.server.wlr_cursor.y - @as(f64, @floatFromInt(xwayland.y));
}

fn requestResizeCallback(listener: *wl.Listener(*wlr.XwaylandSurface.event.Resize), event: *wlr.XwaylandSurface.event.Resize) void {
    const xwayland: *Self = @fieldParentPtr("request_resize_listener", listener);
    const xwayland_window = window.Window.from(xwayland);

    if (xwayland.wlr_xwayland_surface.surface == null or !xwayland.wlr_xwayland_surface.surface.?.mapped) {
        return;
    }

    const edges: wlr.Edges = @bitCast(event.edges);

    owm.server.grabbed_window = xwayland_window;
    owm.server.cursor_mode = .resize;
    owm.server.resize_edges = edges;

    const box: wlr.Box = .{
        .x = xwayland.x,
        .y = xwayland.y,
        .width = xwayland.wlr_xwayland_surface.width,
        .height = xwayland.wlr_xwayland_surface.height,
    };

    const border_x = xwayland.x + box.x + if (edges.right) box.width else 0;
    const border_y = xwayland.y + box.y + if (edges.bottom) box.height else 0;
    owm.server.grab_x = owm.server.wlr_cursor.x - @as(f64, @floatFromInt(border_x)); // Delta X between cursor X and grabbed borders X
    owm.server.grab_y = owm.server.wlr_cursor.y - @as(f64, @floatFromInt(border_y)); // Delta Y between cursor Y and grabbed borders Y

    owm.server.grab_box = box;
    owm.server.grab_box.x += xwayland.x;
    owm.server.grab_box.y += xwayland.y;
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const xwayland: *Self = @fieldParentPtr("destroy_listener", listener);

    xwayland.request_configure_listener.link.remove();
    xwayland.associate_listener.link.remove();
    xwayland.dissociate_listener.link.remove();
    xwayland.request_move_listener.link.remove();
    xwayland.request_resize_listener.link.remove();
    xwayland.destroy_listener.link.remove();

    owm.c_alloc.destroy(window.Window.from(xwayland));
}
