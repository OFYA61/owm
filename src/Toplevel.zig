//! Represents a toplevel window in the Wayland compositor.
//! Manages window geometry, input events, and XDG tiling functionality.
pub const Toplevel = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

const TOPLEVEL_SPAWN_SIZE_X = 640;
const TOPLEVEL_SPAWN_SIZE_Y = 360;
const FOCUS_BORDER_WIDTH = 2;
const FOCUS_BORDER_SIZE_DIFF = FOCUS_BORDER_WIDTH * 2;
const FOCUS_BORDER_COLOR = [4]f32{ 0, 255, 255, 255 }; // cyan

wlr_xdg_toplevel: *wlr.XdgToplevel,
wlr_scene_tree: *wlr.SceneTree,

x: i32 = 0,
y: i32 = 0,
current_output: *owm.Output,
box_before_maximize: wlr.Box,

map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),
request_move_listener: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(requestMoveCallback),
request_resize_listener: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(requestResizeCallback),
request_maximize_listener: wl.Listener(void) = .init(requestMaximizeCallback),
request_fullscreen_listener: wl.Listener(void) = .init(requestFullscreenCallback),

pub fn create(wlr_xdg_toplevel: *wlr.XdgToplevel) anyerror!void {
    const toplevel = try owm.c_alloc.create(Toplevel);
    errdefer owm.c_alloc.destroy(toplevel);

    const output = owm.server.outputAtCursor() orelse return error.CursorNotOnOutput;

    toplevel.* = .{
        .wlr_xdg_toplevel = wlr_xdg_toplevel,
        .wlr_scene_tree = try owm.server.wlr_scene.tree.createSceneXdgSurface(wlr_xdg_toplevel.base), // Add a node displaying an xdg_surface and all of it's sub-surfaces to the scene graph.
        .current_output = output,
        .box_before_maximize = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };

    toplevel.wlr_scene_tree.node.data = toplevel;
    wlr_xdg_toplevel.base.data = toplevel.wlr_scene_tree;

    wlr_xdg_toplevel.base.surface.events.map.add(&toplevel.map_listener);
    wlr_xdg_toplevel.base.surface.events.unmap.add(&toplevel.unmap_listener);
    wlr_xdg_toplevel.base.surface.events.commit.add(&toplevel.commit_listener);
    wlr_xdg_toplevel.events.destroy.add(&toplevel.destroy_listener);
    wlr_xdg_toplevel.events.request_move.add(&toplevel.request_move_listener);
    wlr_xdg_toplevel.events.request_resize.add(&toplevel.request_resize_listener);
    wlr_xdg_toplevel.events.request_maximize.add(&toplevel.request_maximize_listener);
    wlr_xdg_toplevel.events.request_fullscreen.add(&toplevel.request_fullscreen_listener);

    const geom = output.geom;
    const spawn_x = geom.x + @divExact(geom.width, 2) - @divExact(TOPLEVEL_SPAWN_SIZE_X, 2);
    const spawn_y = geom.y + @divExact(geom.height, 2) - @divExact(TOPLEVEL_SPAWN_SIZE_Y, 2);
    toplevel.wlr_scene_tree.node.setPosition(spawn_x, spawn_y);
    toplevel.x = spawn_x;
    toplevel.y = spawn_y;
}

pub fn checkSurfaceMatch(self: *Toplevel, surface: *wlr.Surface) bool {
    return self.wlr_xdg_toplevel.base.surface == surface;
}

pub fn setFocus(self: *Toplevel, focus: bool) void {
    _ = self.wlr_xdg_toplevel.setActivated(focus);
    if (focus) {
        self.wlr_scene_tree.node.raiseToTop();
    }
}

pub fn setSize(self: *Toplevel, new_width: i32, new_height: i32) void {
    _ = self.wlr_xdg_toplevel.setSize(new_width, new_height);
}

pub fn setPos(self: *Toplevel, new_x: c_int, new_y: c_int) void {
    self.x = new_x;
    self.y = new_y;
    self.wlr_scene_tree.node.setPosition(new_x, new_y);
}

pub fn getGeom(self: *Toplevel) wlr.Box {
    return self.wlr_xdg_toplevel.base.geometry;
}

pub fn toggleMaximize(self: *Toplevel) void {
    if (self.wlr_xdg_toplevel.current.maximized) {
        const box = self.box_before_maximize;
        self.setSize(box.width, box.height);
        self.setPos(box.x, box.y);
        _ = self.wlr_xdg_toplevel.setMaximized(false);
    } else {
        const output_geom = self.current_output.geom;
        self.box_before_maximize = .{
            .x = self.x,
            .y = self.y,
            .width = self.wlr_xdg_toplevel.current.width,
            .height = self.wlr_xdg_toplevel.current.height,
        };

        self.x = output_geom.x;
        self.y = output_geom.y;

        self.wlr_scene_tree.node.setPosition(output_geom.x, output_geom.y);
        _ = self.wlr_xdg_toplevel.setSize(output_geom.width, output_geom.height);
        _ = self.wlr_xdg_toplevel.setMaximized(true);
    }

    _ = self.wlr_xdg_toplevel.base.scheduleConfigure();
}

/// Called when the surface is mapped, or ready to display on screen
fn mapCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("map_listener", listener);
    owm.server.focusToplevel(toplevel, toplevel.wlr_xdg_toplevel.base.surface);
}

/// Called when the surface should no longer be shown
fn unmapCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("unmap_listener", listener);
    if (owm.server.grabbed_toplevel == toplevel) {
        owm.server.resetCursorMode();
    }
}

/// Called when the surface state is committed
fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const toplevel: *Toplevel = @fieldParentPtr("commit_listener", listener);
    if (toplevel.wlr_xdg_toplevel.base.initial_commit) {
        // When an xdg_surface performs an initial commit, the compositor must
        // reply with a configure so the client can map the surface.
        // Configuring the xdg_toplevel with 0,0 size to lets the client pick the
        // dimensions itself.
        _ = toplevel.wlr_xdg_toplevel.setSize(TOPLEVEL_SPAWN_SIZE_X, TOPLEVEL_SPAWN_SIZE_Y);
    }
    if (owm.server.cursor_mode != .resize) {
        return;
    }
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("destroy_listener", listener);

    toplevel.map_listener.link.remove();
    toplevel.unmap_listener.link.remove();
    toplevel.commit_listener.link.remove();
    toplevel.destroy_listener.link.remove();
    toplevel.request_move_listener.link.remove();
    toplevel.request_resize_listener.link.remove();
    toplevel.request_maximize_listener.link.remove();
    toplevel.request_fullscreen_listener.link.remove();

    if (owm.server.focused_toplevel == toplevel) {
        owm.server.focused_toplevel = null;
    }

    owm.c_alloc.destroy(toplevel);
}

fn requestMoveCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), _: *wlr.XdgToplevel.event.Move) void {
    const toplevel: *Toplevel = @fieldParentPtr("request_move_listener", listener);
    if (toplevel.wlr_xdg_toplevel.current.maximized) {
        const box = toplevel.box_before_maximize;
        toplevel.setSize(box.width, box.height);
        _ = toplevel.wlr_xdg_toplevel.setMaximized(false);
        const new_x = @as(c_int, @intFromFloat(owm.server.wlr_cursor.x)) - @divFloor(box.width, 2);
        const new_y = @as(c_int, @intFromFloat(owm.server.wlr_cursor.y)) - 3;
        toplevel.setPos(new_x, new_y);
    }
    owm.server.grabbed_toplevel = toplevel;
    owm.server.cursor_mode = .move;
    owm.server.grab_x = owm.server.wlr_cursor.x - @as(f64, @floatFromInt(toplevel.x));
    owm.server.grab_y = owm.server.wlr_cursor.y - @as(f64, @floatFromInt(toplevel.y));
}

fn requestResizeCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const toplevel: *Toplevel = @fieldParentPtr("request_resize_listener", listener);

    owm.server.grabbed_toplevel = toplevel;
    owm.server.cursor_mode = .resize;
    owm.server.resize_edges = event.edges;

    const box = toplevel.wlr_xdg_toplevel.base.geometry;

    const border_x = toplevel.x + box.x + if (event.edges.right) box.width else 0;
    const border_y = toplevel.y + box.y + if (event.edges.bottom) box.height else 0;
    owm.server.grab_x = owm.server.wlr_cursor.x - @as(f64, @floatFromInt(border_x)); // Delta X between cursor X and grabbed borders X
    owm.server.grab_y = owm.server.wlr_cursor.y - @as(f64, @floatFromInt(border_y)); // Delta Y between cursor Y and grabbed borders Y

    owm.server.grab_box = box;
    owm.server.grab_box.x += toplevel.x;
    owm.server.grab_box.y += toplevel.y;
}

fn requestMaximizeCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("request_maximize_listener", listener);
    if (!toplevel.wlr_xdg_toplevel.base.initialized) {
        return;
    }

    toplevel.toggleMaximize();
}

fn requestFullscreenCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("request_fullscreen_listener", listener);
    if (!toplevel.wlr_xdg_toplevel.base.initialized) {
        return;
    }
    _ = toplevel.wlr_xdg_toplevel.base.scheduleConfigure();
}
