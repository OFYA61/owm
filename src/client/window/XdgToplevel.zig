const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;
const log = owm.log;
const Window = owm.client.window.Window;

pub const SPAWN_SIZE_X = 640;
pub const SPAWN_SIZE_Y = 360;

wlr_xdg_toplevel: *wlr.XdgToplevel,
current_output: *owm.server.Output,
box_before_maximize: wlr.Box,
wlr_scene_tree: *wlr.SceneTree,
x: i32 = 0,
y: i32 = 0,

new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newPopupCallback),
map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),
request_move_listener: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(requestMoveCallback),
request_resize_listener: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(requestResizeCallback),
request_maximize_listener: wl.Listener(void) = .init(requestMaximizeCallback),
request_fullscreen_listener: wl.Listener(void) = .init(requestFullscreenCallback),

pub fn create(xdg_toplevel_window: *Window, wlr_xdg_toplevel: *wlr.XdgToplevel) client.Error!Self {
    const output = owm.SERVER.outputAtCursor() orelse return client.Error.CursorNotOnOutput;

    const scene_tree = output.scene.getCurrentWorkspaceRoot().createSceneXdgSurface(wlr_xdg_toplevel.base) catch {
        log.err("Failed to create scene tree for XdgToplevel");
        return client.Error.FailedToCreateSceneTree;
    };

    errdefer scene_tree.node.link.remove();

    scene_tree.node.data = xdg_toplevel_window;

    return .{
        .wlr_xdg_toplevel = wlr_xdg_toplevel,
        .current_output = output,
        .box_before_maximize = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .wlr_scene_tree = scene_tree,
    };
}

pub fn setup(self: *Self) void {
    self.wlr_xdg_toplevel.base.events.new_popup.add(&self.new_popup_listener);
    self.wlr_xdg_toplevel.base.surface.events.map.add(&self.map_listener);
    self.wlr_xdg_toplevel.base.surface.events.unmap.add(&self.unmap_listener);
    self.wlr_xdg_toplevel.base.surface.events.commit.add(&self.commit_listener);
    self.wlr_xdg_toplevel.events.destroy.add(&self.destroy_listener);
    self.wlr_xdg_toplevel.events.request_move.add(&self.request_move_listener);
    self.wlr_xdg_toplevel.events.request_resize.add(&self.request_resize_listener);
    self.wlr_xdg_toplevel.events.request_maximize.add(&self.request_maximize_listener);
    self.wlr_xdg_toplevel.events.request_fullscreen.add(&self.request_fullscreen_listener);

    const spawn_coords = self.current_output.getCenterPosForWindow(SPAWN_SIZE_X, SPAWN_SIZE_Y);
    self.setPos(spawn_coords.x, spawn_coords.y);
}

pub fn getWlrSurface(self: *Self) *wlr.Surface {
    return self.wlr_xdg_toplevel.base.surface;
}

pub fn checkSurfaceMatch(self: *Self, surface: *wlr.Surface) bool {
    return self.wlr_xdg_toplevel.base.surface == surface;
}

pub fn setFocus(self: *Self, focus: bool) void {
    _ = self.wlr_xdg_toplevel.setActivated(focus);
    if (focus) {
        self.wlr_scene_tree.node.raiseToTop();
        self.current_output.scene.raiseWindowToTopOfWorkspace(Window.from(self));
    }
}

pub inline fn getPos(self: *Self) owm.math.Vec2(i32) {
    return .{
        .x = self.x,
        .y = self.y,
    };
}

pub fn setPos(self: *Self, new_x: i32, new_y: i32) void {
    self.x = new_x;
    self.y = new_y;
    self.wlr_scene_tree.node.setPosition(new_x, new_y);
}

pub fn setSize(self: *Self, new_width: i32, new_height: i32) void {
    _ = self.wlr_xdg_toplevel.setSize(new_width, new_height);
}

pub fn getGeom(self: *Self) wlr.Box {
    return self.wlr_xdg_toplevel.base.geometry;
}

pub fn toggleMaximize(self: *Self) void {
    if (self.wlr_xdg_toplevel.current.maximized) {
        const box = self.box_before_maximize;
        self.setSize(box.width, box.height);
        self.setPos(box.x, box.y);
        _ = self.wlr_xdg_toplevel.setMaximized(false);
    } else {
        const output_work_area = self.current_output.work_area;
        self.box_before_maximize = .{
            .x = self.x,
            .y = self.y,
            .width = self.wlr_xdg_toplevel.current.width,
            .height = self.wlr_xdg_toplevel.current.height,
        };

        self.x = output_work_area.x;
        self.y = output_work_area.y;

        self.setPos(output_work_area.x, output_work_area.y);
        _ = self.wlr_xdg_toplevel.setSize(output_work_area.width, output_work_area.height);
        _ = self.wlr_xdg_toplevel.setMaximized(true);
    }

    _ = self.wlr_xdg_toplevel.base.scheduleConfigure();
}

fn newPopupCallback(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const toplevel: *Self = @fieldParentPtr("new_popup_listener", listener);
    _ = client.Popup.create(
        wlr_xdg_popup,
        toplevel.wlr_scene_tree,
        toplevel.wlr_scene_tree,
        toplevel.current_output,
    ) catch |err| {
        log.errf("Failed to create XDG Popup for toplevel {}", .{err});
        return;
    };
}

/// Called when the surface is mapped, or ready to display on screen
fn mapCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Self = @fieldParentPtr("map_listener", listener);
    const xdg_toplevel_window = Window.from(toplevel);
    toplevel.current_output.scene.addWindowToCurrentWorkspace(xdg_toplevel_window);
    owm.SERVER.seat.focusWindow(xdg_toplevel_window);
}

/// Called when the surface should no longer be shown
fn unmapCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Self = @fieldParentPtr("unmap_listener", listener);
    const xdg_toplevel_window = Window.from(toplevel);
    if (owm.SERVER.seat.grabbed_window == xdg_toplevel_window) {
        owm.SERVER.seat.resetCursorMode();
    }
    xdg_toplevel_window.link.remove();
}

/// Called when the surface state is committed
fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const toplevel: *Self = @fieldParentPtr("commit_listener", listener);
    if (toplevel.wlr_xdg_toplevel.base.initial_commit) {
        // When an xdg_surface performs an initial commit, the compositor must
        // reply with a configure so the window can map the surface.
        // Configuring the xdg_toplevel with 0,0 size to lets the window pick the
        // dimensions itself.
        _ = toplevel.wlr_xdg_toplevel.setSize(SPAWN_SIZE_X, SPAWN_SIZE_Y);
    }
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Self = @fieldParentPtr("destroy_listener", listener);

    toplevel.new_popup_listener.link.remove();
    toplevel.map_listener.link.remove();
    toplevel.unmap_listener.link.remove();
    toplevel.commit_listener.link.remove();
    toplevel.destroy_listener.link.remove();
    toplevel.request_move_listener.link.remove();
    toplevel.request_resize_listener.link.remove();
    toplevel.request_maximize_listener.link.remove();
    toplevel.request_fullscreen_listener.link.remove();

    const xdg_toplevel_window = Window.from(toplevel);
    owm.SERVER.seat.clearFocusIfFocusedWindow(xdg_toplevel_window);

    owm.c_alloc.destroy(xdg_toplevel_window);
}

fn requestMoveCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), _: *wlr.XdgToplevel.event.Move) void {
    const toplevel: *Self = @fieldParentPtr("request_move_listener", listener);
    const xdg_toplevel_window = Window.from(toplevel);
    if (toplevel.wlr_xdg_toplevel.current.maximized) {
        const box = toplevel.box_before_maximize;
        toplevel.setSize(box.width, box.height);
        _ = toplevel.wlr_xdg_toplevel.setMaximized(false);
        const cursor_pos = owm.SERVER.seat.getCursorPos().intoInt(c_int);
        const new_x = cursor_pos.x - @divFloor(box.width, 2);
        const new_y = cursor_pos.y - 3;
        toplevel.setPos(new_x, new_y);
    }

    owm.SERVER.seat.requestMove(xdg_toplevel_window);
}

fn requestResizeCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const toplevel: *Self = @fieldParentPtr("request_resize_listener", listener);
    const xdg_toplevel_window = Window.from(toplevel);
    owm.SERVER.seat.requestResize(xdg_toplevel_window, event.edges);
}

fn requestMaximizeCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Self = @fieldParentPtr("request_maximize_listener", listener);
    if (!toplevel.wlr_xdg_toplevel.base.initialized) {
        return;
    }

    toplevel.toggleMaximize();
}

fn requestFullscreenCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Self = @fieldParentPtr("request_fullscreen_listener", listener);
    if (!toplevel.wlr_xdg_toplevel.base.initialized) {
        return;
    }
    _ = toplevel.wlr_xdg_toplevel.base.scheduleConfigure();
}
