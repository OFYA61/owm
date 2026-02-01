const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

const TOPLEVEL_SPAWN_SIZE_X = 640;
const TOPLEVEL_SPAWN_SIZE_Y = 360;

pub const OwmToplevel = struct {
    server: *owm.Server,
    wlr_xdg_toplevel: *wlr.XdgToplevel,
    wlr_scene_tree: *wlr.SceneTree,
    link: wl.list.Link = undefined,

    x: i32 = 0,
    y: i32 = 0,
    current_output_id: usize,
    box_before_maximize: wlr.Box,

    map_listener: wl.Listener(void) = .init(mapCallback),
    unmap_listener: wl.Listener(void) = .init(unmapCallback),
    commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
    destroy_listener: wl.Listener(void) = .init(destroyCallback),
    request_move_listener: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(requestMoveCallback),
    request_resize_listener: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(requestResizeCallback),
    request_maximize_listener: wl.Listener(void) = .init(requestMaximizeCallback),
    request_fullscreen_listener: wl.Listener(void) = .init(requestFullscreenCallback),

    pub fn create(server: *owm.Server, wlr_xdg_toplevel: *wlr.XdgToplevel) anyerror!void {
        const toplevel = try owm.allocator.create(OwmToplevel);
        errdefer owm.allocator.destroy(toplevel);

        const output = server.outputAt(server.wlr_cursor.x, server.wlr_cursor.y);
        if (output == null) {
            return error.CursorNotOnAnyOutput;
        }

        toplevel.* = .{
            .server = server,
            .wlr_xdg_toplevel = wlr_xdg_toplevel,
            .wlr_scene_tree = try server.wlr_scene.tree.createSceneXdgSurface(wlr_xdg_toplevel.base), // Add a node displaying an xdg_surface and all of it's sub-surfaces to the scene graph.
            .current_output_id = output.?.id,
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

        const geom = output.?.getGeom();
        const spawn_x = geom.x + @divExact(geom.width, 2) - @divExact(TOPLEVEL_SPAWN_SIZE_X, 2);
        const spawn_y = geom.y + @divExact(geom.height, 2) - @divExact(TOPLEVEL_SPAWN_SIZE_Y, 2);
        toplevel.wlr_scene_tree.node.setPosition(spawn_x, spawn_y);
        toplevel.x = spawn_x;
        toplevel.y = spawn_y;
    }

    /// Called when the surface is mapped, or ready to display on screen
    fn mapCallback(listener: *wl.Listener(void)) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("map_listener", listener);
        toplevel.server.toplevels.prepend(toplevel);
        toplevel.server.focusToplevel(toplevel, toplevel.wlr_xdg_toplevel.base.surface);
    }

    /// Called when the surface should no longer be shown
    fn unmapCallback(listener: *wl.Listener(void)) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("unmap_listener", listener);
        if (toplevel.server.grabbed_toplevel == toplevel) {
            toplevel.server.resetCursorMode();
        }

        toplevel.link.remove();
    }

    /// Called when the surface state is committed
    fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("commit_listener", listener);
        if (toplevel.wlr_xdg_toplevel.base.initial_commit) {
            // When an xdg_surface performs an initial commit, the compositor must
            // reply with a configure so the client can map the surface.
            // Configuring the xdg_toplevel with 0,0 size to lets the client pick the
            // dimensions itself.
            _ = toplevel.wlr_xdg_toplevel.setSize(TOPLEVEL_SPAWN_SIZE_X, TOPLEVEL_SPAWN_SIZE_Y);
        }
    }

    fn destroyCallback(listener: *wl.Listener(void)) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("destroy_listener", listener);

        toplevel.map_listener.link.remove();
        toplevel.unmap_listener.link.remove();
        toplevel.commit_listener.link.remove();
        toplevel.destroy_listener.link.remove();
        toplevel.request_move_listener.link.remove();
        toplevel.request_resize_listener.link.remove();
        toplevel.request_maximize_listener.link.remove();
        toplevel.request_fullscreen_listener.link.remove();

        owm.allocator.destroy(toplevel);
    }

    fn requestMoveCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), _: *wlr.XdgToplevel.event.Move) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("request_move_listener", listener);
        const server = toplevel.server;
        server.grabbed_toplevel = toplevel;
        server.cursor_mode = .move;
        server.grab_x = server.wlr_cursor.x - @as(f64, @floatFromInt(toplevel.x));
        server.grab_y = server.wlr_cursor.y - @as(f64, @floatFromInt(toplevel.y));
    }

    fn requestResizeCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("request_resize_listener", listener);
        const server = toplevel.server;

        server.grabbed_toplevel = toplevel;
        server.cursor_mode = .resize;
        server.resize_edges = event.edges;

        const box = toplevel.wlr_xdg_toplevel.base.geometry;

        const border_x = toplevel.x + box.x + if (event.edges.right) box.width else 0;
        const border_y = toplevel.y + box.y + if (event.edges.bottom) box.height else 0;
        server.grab_x = server.wlr_cursor.x - @as(f64, @floatFromInt(border_x)); // Delta X between cursor X and grabbed borders X
        server.grab_y = server.wlr_cursor.y - @as(f64, @floatFromInt(border_y)); // Delta Y between cursor Y and grabbed borders Y

        server.grab_box = box;
        server.grab_box.x += toplevel.x;
        server.grab_box.y += toplevel.y;
    }

    fn requestMaximizeCallback(listener: *wl.Listener(void)) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("request_maximize_listener", listener);
        if (!toplevel.wlr_xdg_toplevel.base.initialized) {
            return;
        }

        if (toplevel.wlr_xdg_toplevel.current.maximized) {
            const box = toplevel.box_before_maximize;
            toplevel.x = box.x;
            toplevel.y = box.y;
            toplevel.wlr_scene_tree.node.setPosition(box.x, box.y);
            _ = toplevel.wlr_xdg_toplevel.setSize(box.width, box.height);
            _ = toplevel.wlr_xdg_toplevel.setMaximized(false);
        } else {
            var located_output: *owm.Output = undefined;
            for (toplevel.server.outputs.items) |output| {
                if (output.id == toplevel.current_output_id) {
                    located_output = output;
                    break;
                }
            }
            const box = located_output.getGeom();
            toplevel.box_before_maximize = .{
                .x = toplevel.x,
                .y = toplevel.y,
                .width = toplevel.wlr_xdg_toplevel.current.width,
                .height = toplevel.wlr_xdg_toplevel.current.height,
            };

            toplevel.x = box.x;
            toplevel.y = box.y;

            toplevel.wlr_scene_tree.node.setPosition(box.x, box.y);
            _ = toplevel.wlr_xdg_toplevel.setSize(box.width, box.height);
            _ = toplevel.wlr_xdg_toplevel.setMaximized(true);
        }

        _ = toplevel.wlr_xdg_toplevel.base.scheduleConfigure();
    }

    fn requestFullscreenCallback(listener: *wl.Listener(void)) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("request_fullscreen_listener", listener);
        if (!toplevel.wlr_xdg_toplevel.base.initialized) {
            return;
        }
        _ = toplevel.wlr_xdg_toplevel.base.scheduleConfigure();
    }
};
