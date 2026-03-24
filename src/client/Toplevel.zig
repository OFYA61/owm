const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;

pub const SPAWN_SIZE_X = 640;
pub const SPAWN_SIZE_Y = 360;

wlr_xdg_toplevel: *wlr.XdgToplevel,
current_output: *owm.Output,
box_before_maximize: wlr.Box,

new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newPopupCallback),
map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),
request_move_listener: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(requestMoveCallback),
request_resize_listener: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(requestResizeCallback),
request_maximize_listener: wl.Listener(void) = .init(requestMaximizeCallback),
request_fullscreen_listener: wl.Listener(void) = .init(requestFullscreenCallback),

pub fn create(wlr_xdg_toplevel: *wlr.XdgToplevel) client.Client.Error!Self {
    const output = owm.server.outputAtCursor() orelse return client.Client.Error.CursorNotOnOutput;
    return .{
        .wlr_xdg_toplevel = wlr_xdg_toplevel,
        .current_output = output,
        .box_before_maximize = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
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
        client.Client.from(self).wlr_scene_tree.node.raiseToTop();
    }
}

pub fn setSize(self: *Self, new_width: i32, new_height: i32) void {
    _ = self.wlr_xdg_toplevel.setSize(new_width, new_height);
}

pub fn getGeom(self: *Self) wlr.Box {
    return self.wlr_xdg_toplevel.base.geometry;
}

pub fn toggleMaximize(self: *Self) void {
    var toplevel_client = client.Client.from(self);
    if (self.wlr_xdg_toplevel.current.maximized) {
        const box = self.box_before_maximize;
        self.setSize(box.width, box.height);
        toplevel_client.setPos(box.x, box.y);
        _ = self.wlr_xdg_toplevel.setMaximized(false);
    } else {
        const output_work_area = self.current_output.work_area;
        self.box_before_maximize = .{
            .x = toplevel_client.x,
            .y = toplevel_client.y,
            .width = self.wlr_xdg_toplevel.current.width,
            .height = self.wlr_xdg_toplevel.current.height,
        };

        toplevel_client.x = output_work_area.x;
        toplevel_client.y = output_work_area.y;

        toplevel_client.setPos(output_work_area.x, output_work_area.y);
        _ = self.wlr_xdg_toplevel.setSize(output_work_area.width, output_work_area.height);
        _ = self.wlr_xdg_toplevel.setMaximized(true);
    }

    _ = self.wlr_xdg_toplevel.base.scheduleConfigure();
}

fn newPopupCallback(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const toplevel: *Self = @fieldParentPtr("new_popup_listener", listener);
    _ = client.Client.newPopup(wlr_xdg_popup, client.Client.from(toplevel)) catch |err| {
        owm.log.errf("Failed to create XDG Popup for toplevel {}", .{err});
        return;
    };
}

/// Called when the surface is mapped, or ready to display on screen
fn mapCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Self = @fieldParentPtr("map_listener", listener);
    const toplevel_client = client.Client.from(toplevel);
    owm.server.app_clients.prepend(toplevel_client);
    owm.server.focusClient(toplevel_client);
}

/// Called when the surface should no longer be shown
fn unmapCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Self = @fieldParentPtr("unmap_listener", listener);
    const toplevel_client = client.Client.from(toplevel);
    if (owm.server.grabbed_client == toplevel_client) {
        owm.server.resetCursorMode();
    }
    toplevel_client.link.remove();
}

/// Called when the surface state is committed
fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const toplevel: *Self = @fieldParentPtr("commit_listener", listener);
    if (toplevel.wlr_xdg_toplevel.base.initial_commit) {
        // When an xdg_surface performs an initial commit, the compositor must
        // reply with a configure so the client can map the surface.
        // Configuring the xdg_toplevel with 0,0 size to lets the client pick the
        // dimensions itself.
        _ = toplevel.wlr_xdg_toplevel.setSize(SPAWN_SIZE_X, SPAWN_SIZE_Y);
    }
    if (owm.server.cursor_mode != .resize) {
        return;
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

    if (owm.server.focused_client == client.Client.from(toplevel)) {
        owm.server.focused_client = null;
    }

    owm.c_alloc.destroy(client.Client.from(toplevel));
}

fn requestMoveCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), _: *wlr.XdgToplevel.event.Move) void {
    const toplevel: *Self = @fieldParentPtr("request_move_listener", listener);
    const toplevel_client = client.Client.from(toplevel);
    if (toplevel.wlr_xdg_toplevel.current.maximized) {
        const box = toplevel.box_before_maximize;
        toplevel.setSize(box.width, box.height);
        _ = toplevel.wlr_xdg_toplevel.setMaximized(false);
        const new_x = @as(c_int, @intFromFloat(owm.server.wlr_cursor.x)) - @divFloor(box.width, 2);
        const new_y = @as(c_int, @intFromFloat(owm.server.wlr_cursor.y)) - 3;
        toplevel_client.setPos(new_x, new_y);
    }

    owm.server.grabbed_client = toplevel_client;
    owm.server.cursor_mode = .move;
    owm.server.grab_x = owm.server.wlr_cursor.x - @as(f64, @floatFromInt(toplevel_client.x));
    owm.server.grab_y = owm.server.wlr_cursor.y - @as(f64, @floatFromInt(toplevel_client.y));
}

fn requestResizeCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const toplevel: *Self = @fieldParentPtr("request_resize_listener", listener);
    const toplevel_client = client.Client.from(toplevel);

    owm.server.grabbed_client = toplevel_client;
    owm.server.cursor_mode = .resize;
    owm.server.resize_edges = event.edges;

    const box = toplevel.wlr_xdg_toplevel.base.geometry;

    const border_x = toplevel_client.x + box.x + if (event.edges.right) box.width else 0;
    const border_y = toplevel_client.y + box.y + if (event.edges.bottom) box.height else 0;
    owm.server.grab_x = owm.server.wlr_cursor.x - @as(f64, @floatFromInt(border_x)); // Delta X between cursor X and grabbed borders X
    owm.server.grab_y = owm.server.wlr_cursor.y - @as(f64, @floatFromInt(border_y)); // Delta Y between cursor Y and grabbed borders Y

    owm.server.grab_box = box;
    owm.server.grab_box.x += toplevel_client.x;
    owm.server.grab_box.y += toplevel_client.y;
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
