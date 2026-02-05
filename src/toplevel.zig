const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

const TOPLEVEL_SPAWN_SIZE_X = 640;
const TOPLEVEL_SPAWN_SIZE_Y = 360;
const FOCUS_BORDER_WIDTH = 5;
const FOCUS_BORDER_SIZE_DIFF = FOCUS_BORDER_WIDTH * 2;
const FOCUS_BORDER_COLOR = [4]f32{ 0, 255, 255, 255 }; // cyan

/// Represents a toplevel window in the Wayland compositor.
/// Manages window geometry, input events, and XDG tiling functionality.
pub const Toplevel = struct {
    /// Reference to the server instance that owns this toplevel
    _server: *owm.Server,
    /// Reference to the wlroots XDG toplevel object
    _wlr_xdg_toplevel: *wlr.XdgToplevel,
    /// Reference to the wlroots scene tree for rendering
    _wlr_scene_tree: *wlr.SceneTree,

    /// X coordinate of the toplevel window
    _x: i32 = 0,
    /// Y coordinate of the toplevel window
    _y: i32 = 0,
    /// ID of the output this toplevel is currently on
    current_output_id: usize,
    /// Original geometry before maximizing
    _box_before_maximize: wlr.Box,
    _border_rect: ?*wlr.SceneRect = null,

    /// Listener for surface mapping events
    _map_listener: wl.Listener(void) = .init(mapCallback),
    /// Listener for surface unmapping events
    _unmap_listener: wl.Listener(void) = .init(unmapCallback),
    /// Listener for surface commit events
    _commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
    /// Listener for toplevel destruction events
    _destroy_listener: wl.Listener(void) = .init(destroyCallback),
    /// Listener for move request events
    _request_move_listener: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(requestMoveCallback),
    /// Listener for resize request events
    _request_resize_listener: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(requestResizeCallback),
    /// Listener for maximize request events
    _request_maximize_listener: wl.Listener(void) = .init(requestMaximizeCallback),
    /// Listener for fullscreen request events
    _request_fullscreen_listener: wl.Listener(void) = .init(requestFullscreenCallback),

    pub fn create(server: *owm.Server, wlr_xdg_toplevel: *wlr.XdgToplevel) anyerror!void {
        const toplevel = try owm.allocator.create(Toplevel);
        errdefer owm.allocator.destroy(toplevel);

        const output = server.outputAt(server.wlr_cursor.x, server.wlr_cursor.y);
        if (output == null) {
            return error.CursorNotOnAnyOutput;
        }

        toplevel.* = .{
            ._server = server,
            ._wlr_xdg_toplevel = wlr_xdg_toplevel,
            ._wlr_scene_tree = try server.wlr_scene.tree.createSceneXdgSurface(wlr_xdg_toplevel.base), // Add a node displaying an xdg_surface and all of it's sub-surfaces to the scene graph.
            .current_output_id = output.?.id,
            ._box_before_maximize = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };

        toplevel._wlr_scene_tree.node.data = toplevel;
        wlr_xdg_toplevel.base.data = toplevel._wlr_scene_tree;

        wlr_xdg_toplevel.base.surface.events.map.add(&toplevel._map_listener);
        wlr_xdg_toplevel.base.surface.events.unmap.add(&toplevel._unmap_listener);
        wlr_xdg_toplevel.base.surface.events.commit.add(&toplevel._commit_listener);
        wlr_xdg_toplevel.events.destroy.add(&toplevel._destroy_listener);
        wlr_xdg_toplevel.events.request_move.add(&toplevel._request_move_listener);
        wlr_xdg_toplevel.events.request_resize.add(&toplevel._request_resize_listener);
        wlr_xdg_toplevel.events.request_maximize.add(&toplevel._request_maximize_listener);
        wlr_xdg_toplevel.events.request_fullscreen.add(&toplevel._request_fullscreen_listener);

        const geom = output.?.geom;
        const spawn_x = geom.x + @divExact(geom.width, 2) - @divExact(TOPLEVEL_SPAWN_SIZE_X, 2);
        const spawn_y = geom.y + @divExact(geom.height, 2) - @divExact(TOPLEVEL_SPAWN_SIZE_Y, 2);
        toplevel._wlr_scene_tree.node.setPosition(spawn_x, spawn_y);
        toplevel._x = spawn_x;
        toplevel._y = spawn_y;
    }

    pub fn checkSurfaceMatch(self: *Toplevel, surface: *wlr.Surface) bool {
        return self._wlr_xdg_toplevel.base.surface == surface;
    }

    pub fn setFocus(self: *Toplevel, focus: bool) void {
        _ = self._wlr_xdg_toplevel.setActivated(focus);
        if (focus) {
            const geom = self.getGeom();

            self._wlr_scene_tree.node.raiseToTop();

            const border_rect = self._wlr_scene_tree.createSceneRect(
                geom.width + FOCUS_BORDER_SIZE_DIFF,
                geom.height + FOCUS_BORDER_SIZE_DIFF,
                &FOCUS_BORDER_COLOR,
            ) catch {
                return;
            };
            border_rect.node.setPosition(-FOCUS_BORDER_WIDTH, -FOCUS_BORDER_WIDTH);
            border_rect.node.lowerToBottom();
            self._border_rect = border_rect;
        } else {
            self._border_rect.?.node.destroy();
            self._border_rect = null;
        }
    }

    pub fn setSize(self: *Toplevel, new_width: i32, new_height: i32) void {
        _ = self._wlr_xdg_toplevel.setSize(new_width, new_height);
    }

    pub fn setPos(self: *Toplevel, new_x: c_int, new_y: c_int) void {
        self._x = new_x;
        self._y = new_y;
        self._wlr_scene_tree.node.setPosition(new_x, new_y);
    }

    pub fn getGeom(self: *Toplevel) wlr.Box {
        return self._wlr_xdg_toplevel.base.geometry;
    }
};

/// Called when the surface is mapped, or ready to display on screen
fn mapCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("_map_listener", listener);
    toplevel._server.focusToplevel(toplevel, toplevel._wlr_xdg_toplevel.base.surface);
}

/// Called when the surface should no longer be shown
fn unmapCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("_unmap_listener", listener);
    if (toplevel._server.grabbed_toplevel == toplevel) {
        toplevel._server.resetCursorMode();
    }
}

/// Called when the surface state is committed
fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const toplevel: *Toplevel = @fieldParentPtr("_commit_listener", listener);
    if (toplevel._wlr_xdg_toplevel.base.initial_commit) {
        // When an xdg_surface performs an initial commit, the compositor must
        // reply with a configure so the client can map the surface.
        // Configuring the xdg_toplevel with 0,0 size to lets the client pick the
        // dimensions itself.
        _ = toplevel._wlr_xdg_toplevel.setSize(TOPLEVEL_SPAWN_SIZE_X, TOPLEVEL_SPAWN_SIZE_Y);
    }
    if (toplevel._server.cursor_mode != .resize) {
        return;
    }
    if (toplevel._border_rect) |border_rect| {
        border_rect.setSize(
            toplevel._wlr_xdg_toplevel.base.geometry.width + FOCUS_BORDER_SIZE_DIFF,
            toplevel._wlr_xdg_toplevel.base.geometry.height + FOCUS_BORDER_SIZE_DIFF,
        );
    }
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("_destroy_listener", listener);

    toplevel._map_listener.link.remove();
    toplevel._unmap_listener.link.remove();
    toplevel._commit_listener.link.remove();
    toplevel._destroy_listener.link.remove();
    toplevel._request_move_listener.link.remove();
    toplevel._request_resize_listener.link.remove();
    toplevel._request_maximize_listener.link.remove();
    toplevel._request_fullscreen_listener.link.remove();

    if (toplevel._server.focused_toplevel == toplevel) {
        toplevel._server.focused_toplevel = null;
    }

    owm.allocator.destroy(toplevel);
}

fn requestMoveCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), _: *wlr.XdgToplevel.event.Move) void {
    const toplevel: *Toplevel = @fieldParentPtr("_request_move_listener", listener);
    if (toplevel._wlr_xdg_toplevel.current.maximized) {
        // TODO: make it focused and dragging at this stage
        // TODO: make it positioned so that the cursor is holding it from the middle
        const box = toplevel._box_before_maximize;
        toplevel.setSize(box.width, box.height);
        _ = toplevel._wlr_xdg_toplevel.setMaximized(false);
        return;
    }
    const server = toplevel._server;
    server.grabbed_toplevel = toplevel;
    server.cursor_mode = .move;
    server.grab_x = server.wlr_cursor.x - @as(f64, @floatFromInt(toplevel._x));
    server.grab_y = server.wlr_cursor.y - @as(f64, @floatFromInt(toplevel._y));
}

fn requestResizeCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const toplevel: *Toplevel = @fieldParentPtr("_request_resize_listener", listener);

    const server = toplevel._server;

    server.grabbed_toplevel = toplevel;
    server.cursor_mode = .resize;
    server.resize_edges = event.edges;

    const box = toplevel._wlr_xdg_toplevel.base.geometry;

    const border_x = toplevel._x + box.x + if (event.edges.right) box.width else 0;
    const border_y = toplevel._y + box.y + if (event.edges.bottom) box.height else 0;
    server.grab_x = server.wlr_cursor.x - @as(f64, @floatFromInt(border_x)); // Delta X between cursor X and grabbed borders X
    server.grab_y = server.wlr_cursor.y - @as(f64, @floatFromInt(border_y)); // Delta Y between cursor Y and grabbed borders Y

    server.grab_box = box;
    server.grab_box.x += toplevel._x;
    server.grab_box.y += toplevel._y;
}

fn requestMaximizeCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("_request_maximize_listener", listener);
    if (!toplevel._wlr_xdg_toplevel.base.initialized) {
        return;
    }

    if (toplevel._wlr_xdg_toplevel.current.maximized) {
        const box = toplevel._box_before_maximize;
        toplevel.setPos(box.x, box.y);
        toplevel.setSize(box.width, box.height);
        _ = toplevel._wlr_xdg_toplevel.setMaximized(false);
    } else {
        var located_output: *owm.Output = undefined;
        var output_iterator = toplevel._server.outputs.iterator(.forward);
        while (output_iterator.next()) |output| {
            if (output.id == toplevel.current_output_id) {
                located_output = output;
                break;
            }
        }

        const box = located_output.geom;
        toplevel._box_before_maximize = .{
            .x = toplevel._x,
            .y = toplevel._y,
            .width = toplevel._wlr_xdg_toplevel.current.width,
            .height = toplevel._wlr_xdg_toplevel.current.height,
        };

        toplevel._x = box.x;
        toplevel._y = box.y;

        toplevel._wlr_scene_tree.node.setPosition(box.x, box.y);
        _ = toplevel._wlr_xdg_toplevel.setSize(box.width, box.height);
        _ = toplevel._wlr_xdg_toplevel.setMaximized(true);
    }

    _ = toplevel._wlr_xdg_toplevel.base.scheduleConfigure();
}

fn requestFullscreenCallback(listener: *wl.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("_request_fullscreen_listener", listener);
    if (!toplevel._wlr_xdg_toplevel.base.initialized) {
        return;
    }
    _ = toplevel._wlr_xdg_toplevel.base.scheduleConfigure();
}
