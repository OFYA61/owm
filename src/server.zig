const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("owm.zig");

const MIN_TOPLEVEL_WIDTH = 240;
const MIN_TOPLEVEL_HEIGHT = 135;

pub const Server = struct {
    wl_server: *wl.Server,
    wl_socket: ?[:0]const u8 = null,

    wlr_scene: *wlr.Scene,
    wlr_scene_output_layout: *wlr.SceneOutputLayout,

    wlr_backend: *wlr.Backend,
    wlr_allocator: *wlr.Allocator,
    wlr_renderer: *wlr.Renderer,
    wlr_output_layout: *wlr.OutputLayout,
    outputs: wl.list.Head(owm.Output, .link) = undefined,

    wlr_xdg_shell: *wlr.XdgShell,
    new_toplevel_listener: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevelCallback),
    new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopupCallback),
    new_output_listener: wl.Listener(*wlr.Output) = .init(newOutputCallback),

    wlr_seat: *wlr.Seat,
    focused_toplevel: ?*owm.Toplevel = null,
    new_input_listener: wl.Listener(*wlr.InputDevice) = .init(newInputCallback),
    request_set_cursor_listener: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursorCallback),
    request_set_selection_listener: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelectionCallback),

    wlr_cursor: *wlr.Cursor,
    wlr_cursor_manager: *wlr.XcursorManager,
    grabbed_toplevel: ?*owm.Toplevel = null,
    cursor_mode: enum { passthrough, move, resize } = .passthrough,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},
    cursor_motion_listener: wl.Listener(*wlr.Pointer.event.Motion) = .init(cursorMotionCallback),
    cursor_motion_absolute_listener: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(cursorMotionAbsoluteCallback),
    cursor_button_listener: wl.Listener(*wlr.Pointer.event.Button) = .init(cursorButtonCallback),
    cursor_axis_listener: wl.Listener(*wlr.Pointer.event.Axis) = .init(cursorAxisCallback),
    cursor_frame_listener: wl.Listener(*wlr.Cursor) = .init(cursorFrameCallback),

    pub fn init(self: *Server) anyerror!void {
        wlr.log.init(.info, null);

        const wl_server = try wl.Server.create();

        const event_loop = wl_server.getEventLoop();
        const wlr_backend = try wlr.Backend.autocreate(event_loop, null); // Auto picks the backend (Wayland, X11, DRM+KSM)
        const wlr_renderer = try wlr.Renderer.autocreate(wlr_backend); // Auto picks a renderer (Pixman, GLES2, Vulkan)
        const wlr_output_layout = try wlr.OutputLayout.create(wl_server); // Utility for working with an arrangement of screens in a physical layout
        const wlr_scene = try wlr.Scene.create(); // Abstraction that handles all rendering and damage tracking
        const wlr_allocator = try wlr.Allocator.autocreate(wlr_backend, wlr_renderer); // The bridge between the backend and renderer. It handdles the buffer creeation, allowing wlroots to render onto the screen
        const wlr_scene_output_layout = try wlr_scene.attachOutputLayout(wlr_output_layout);
        const wlr_xdg_shell = try wlr.XdgShell.create(wl_server, 3); // XDG protocol for app windows
        const wlr_seat = try wlr.Seat.create(wl_server, "seat0"); // Input device seat
        const wlr_cursor = try wlr.Cursor.create(); // Mouse
        const wlr_cursor_manager = try wlr.XcursorManager.create(null, 24); // Sources cursor images

        self.* = .{
            .wl_server = wl_server,
            .wlr_backend = wlr_backend,
            .wlr_renderer = wlr_renderer,
            .wlr_allocator = wlr_allocator,
            .wlr_scene = wlr_scene,
            .wlr_output_layout = wlr_output_layout,
            .wlr_scene_output_layout = wlr_scene_output_layout,
            .wlr_xdg_shell = wlr_xdg_shell,
            .wlr_seat = wlr_seat,
            .wlr_cursor = wlr_cursor,
            .wlr_cursor_manager = wlr_cursor_manager,
        };

        try self.wlr_renderer.initServer(wl_server);

        _ = try wlr.Compositor.create(self.wl_server, 6, self.wlr_renderer); // Allows clients to allocate surfaces
        _ = try wlr.Subcompositor.create(self.wl_server); // Allows clients to assign role to subsurfaces
        _ = try wlr.DataDeviceManager.create(self.wl_server); // Handles clipboard

        self.outputs.init();

        self.wlr_backend.events.new_output.add(&self.new_output_listener);

        self.wlr_xdg_shell.events.new_toplevel.add(&self.new_toplevel_listener);
        self.wlr_xdg_shell.events.new_popup.add(&self.new_popup_listener);

        self.wlr_backend.events.new_input.add(&self.new_input_listener);
        self.wlr_seat.events.request_set_cursor.add(&self.request_set_cursor_listener);
        self.wlr_seat.events.request_set_selection.add(&self.request_set_selection_listener);

        self.wlr_cursor.attachOutputLayout(self.wlr_output_layout);
        try self.wlr_cursor_manager.load(1);
        wlr_cursor.events.motion.add(&self.cursor_motion_listener);
        wlr_cursor.events.motion_absolute.add(&self.cursor_motion_absolute_listener);
        wlr_cursor.events.button.add(&self.cursor_button_listener);
        wlr_cursor.events.axis.add(&self.cursor_axis_listener);
        wlr_cursor.events.frame.add(&self.cursor_frame_listener);
    }

    pub fn deinit(self: *Server) void {
        self.wl_server.destroyClients();

        self.new_input_listener.link.remove();
        self.new_output_listener.link.remove();

        self.new_toplevel_listener.link.remove();
        self.new_popup_listener.link.remove();
        self.request_set_cursor_listener.link.remove();
        self.request_set_selection_listener.link.remove();
        self.cursor_motion_listener.link.remove();
        self.cursor_motion_absolute_listener.link.remove();
        self.cursor_button_listener.link.remove();
        self.cursor_axis_listener.link.remove();
        self.cursor_frame_listener.link.remove();

        self.wlr_backend.destroy();
        self.wl_server.destroy();
    }

    pub fn setSocket(self: *Server, socket: [:0]const u8) void {
        self.wl_socket = socket;
    }

    pub fn run(self: *Server) anyerror!void {
        try self.wlr_backend.start();
        std.log.info("Running OWM compositor on WAYLAND_DISPLAY={s}", .{self.wl_socket.?});
        self.wl_server.run();
    }

    pub fn handleKeybind(self: *Server, key: xkb.Keysym) bool {
        switch (@intFromEnum(key)) {
            xkb.Keysym.Escape => self.wl_server.terminate(),
            xkb.Keysym.t => {
                self.spawnChild("ghostty") catch {
                    std.log.err("Failed to spawn cosmic-term", .{});
                };
            },
            xkb.Keysym.f => {
                self.spawnChild("cosmic-files") catch {
                    std.log.err("failed to spawn cosmic-files", .{});
                };
            },
            else => return false,
        }
        return true;
    }

    pub fn focusToplevel(self: *Server, toplevel: *owm.Toplevel, surface: *wlr.Surface) void {
        if (self.focused_toplevel) |prev_toplevel| {
            if (prev_toplevel.checkSurfaceMatch(surface)) return;
            prev_toplevel.setFocus(false);
        }

        toplevel.setFocus(true);

        const wlr_keyboard = self.wlr_seat.getKeyboard() orelse return;
        self.wlr_seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );

        self.focused_toplevel = toplevel;
    }

    fn spawnChild(self: *Server, command: [:0]const u8) anyerror!void {
        var child = std.process.Child.init(
            &[_][]const u8{ "/bin/sh", "-c", command },
            owm.allocator,
        );

        var env_map = try std.process.getEnvMap(owm.allocator);
        defer env_map.deinit();
        try env_map.put("WAYLAND_DISPLAY", self.wl_socket.?);
        child.env_map = &env_map;

        try child.spawn();
    }

    pub fn outputAtCursor(self: *Server) ?*owm.Output {
        return self.outputAt(self.wlr_cursor.x, self.wlr_cursor.y);
    }

    pub fn outputAt(self: *Server, lx: f64, ly: f64) ?*owm.Output {
        var output_iterator = self.outputs.iterator(.forward);
        while (output_iterator.next()) |output| {
            const geom = output.geom;
            const x = @as(f64, @floatFromInt(geom.x));
            const y = @as(f64, @floatFromInt(geom.y));
            const width = @as(f64, @floatFromInt(geom.width));
            const height = @as(f64, @floatFromInt(geom.height));
            if (x <= lx and lx < x + width and y <= ly and ly < y + height) {
                return output;
            }
        }
        return null;
    }

    pub fn resetCursorMode(self: *Server) void {
        self.cursor_mode = .passthrough;
        self.grabbed_toplevel = null;
    }

    const ViewAtResponse = struct {
        sx: f64,
        sy: f64,
        wlr_surface: *wlr.Surface,
        toplevel: *owm.Toplevel,
    };

    fn viewAt(self: *Server, lx: f64, ly: f64) ?ViewAtResponse {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (self.wlr_scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*owm.Toplevel, @ptrCast(@alignCast(n.node.data)))) |toplevel| {
                    return ViewAtResponse{
                        .sx = sx,
                        .sy = sy,
                        .wlr_surface = scene_surface.surface,
                        .toplevel = toplevel,
                    };
                }
            }
        }

        return null;
    }

    fn processCursorMotion(self: *Server, time: u32) void {
        if (self.cursor_mode == .move) {
            const toplevel = self.grabbed_toplevel.?;
            toplevel.setPos(
                @as(i32, @intFromFloat(self.wlr_cursor.x - self.grab_x)),
                @as(i32, @intFromFloat(self.wlr_cursor.y - self.grab_y)),
            );
            return;
        } else if (self.cursor_mode == .resize) {
            const toplevel = self.grabbed_toplevel.?;
            const border_x = @as(i32, @intFromFloat(self.wlr_cursor.x - self.grab_x));
            const border_y = @as(i32, @intFromFloat(self.wlr_cursor.y - self.grab_y));

            var new_left = self.grab_box.x;
            var new_right = self.grab_box.x + self.grab_box.width;
            var new_top = self.grab_box.y;
            var new_bottom = self.grab_box.y + self.grab_box.height;

            if (self.resize_edges.top) {
                new_top = border_y;
                if (new_top + MIN_TOPLEVEL_HEIGHT >= new_bottom) { // Make sure new_top isn't below new_bottom
                    new_top = new_bottom - MIN_TOPLEVEL_HEIGHT;
                }
            } else if (self.resize_edges.bottom) {
                new_bottom = border_y;
                if (new_bottom - MIN_TOPLEVEL_HEIGHT <= new_top) { // Make sure new_bottom isn't above new_top
                    new_bottom = new_top + MIN_TOPLEVEL_HEIGHT;
                }
            }

            if (self.resize_edges.left) {
                new_left = border_x;
                if (new_left + MIN_TOPLEVEL_WIDTH >= new_right) { // Make sure new_left isn't right of new_right
                    new_left = new_right - MIN_TOPLEVEL_WIDTH;
                }
            } else if (self.resize_edges.right) {
                new_right = border_x;
                if (new_right - MIN_TOPLEVEL_WIDTH <= new_left) { // Make sure new_right isn't left of new_left
                    new_right = new_left + MIN_TOPLEVEL_WIDTH;
                }
            }

            const box = toplevel.getGeom();
            const new_x = new_left - box.x;
            const new_y = new_top - box.y;
            toplevel.setPos(new_x, new_y);

            const new_width: i32 = new_right - new_left;
            const new_height: i32 = new_bottom - new_top;
            toplevel.setSize(new_width, new_height);
            return;
        }

        if (self.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |response| {
            self.wlr_seat.pointerNotifyEnter(response.wlr_surface, response.sx, response.sy);
            self.wlr_seat.pointerNotifyMotion(time, response.sx, response.sy);
        } else {
            self.wlr_cursor.setXcursor(self.wlr_cursor_manager, "default");
            self.wlr_seat.pointerClearFocus();
        }
    }

    /// Called when a new display is discovered
    fn newOutputCallback(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Server = @fieldParentPtr("new_output_listener", listener);
        owm.Output.create(server, wlr_output) catch {
            std.log.err("Failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };
    }

    /// Called when a client creates a new toplevel (app window)
    fn newXdgToplevelCallback(listener: *wl.Listener(*wlr.XdgToplevel), wlr_xdg_toplevel: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_toplevel_listener", listener);
        owm.Toplevel.create(server, wlr_xdg_toplevel) catch {
            std.log.err("Failed to allocate new toplevel", .{});
            wlr_xdg_toplevel.sendClose();
            return;
        };
    }

    /// Called when a client create a new popup
    fn newXdgPopupCallback(_: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
        owm.Popup.create(wlr_xdg_popup) catch {
            std.log.err("Failed to allocate new popup", .{});
            return;
        };
    }

    /// Called when a new input device becomes available
    fn newInputCallback(listener: *wl.Listener(*wlr.InputDevice), input_device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input_listener", listener);
        server.wlr_seat.setCapabilities(.{
            .pointer = true,
            .keyboard = true,
        });

        switch (input_device.type) {
            .pointer => {
                server.wlr_cursor.attachInputDevice(input_device);
            },
            .keyboard => {
                _ = owm.Keyboard.create(server, input_device) catch |err| {
                    std.log.err("Failed to allocate keyboard: {}", .{err});
                    return;
                };
            },
            else => {},
        }
    }

    /// Called when a client provides a cursor image
    fn requestSetCursorCallback(listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor), event: *wlr.Seat.event.RequestSetCursor) void {
        const server: *Server = @fieldParentPtr("request_set_cursor_listener", listener);
        if (server.wlr_seat.pointer_state.focused_client) |client| {
            if (client == event.seat_client) { // Make sure the requesting client is focused
                server.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
            }
        }
    }

    /// Called when a client want to set the selection, e.g. copies something.
    fn requestSetSelectionCallback(listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection), event: *wlr.Seat.event.RequestSetSelection) void {
        const server: *Server = @fieldParentPtr("request_set_selection_listener", listener);
        server.wlr_seat.setSelection(event.source, event.serial);
    }

    /// Called when pointer emits relative (_delta_) motion events
    fn cursorMotionCallback(listener: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
        const server: *Server = @fieldParentPtr("cursor_motion_listener", listener);
        server.wlr_cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    /// Called when pointer emits an absolute motion event, e.g. on Wayland or X11 backend, pointer enters the window
    fn cursorMotionAbsoluteCallback(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
        const server: *Server = @fieldParentPtr("cursor_motion_absolute_listener", listener);
        server.wlr_cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    fn cursorButtonCallback(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
        const server: *Server = @fieldParentPtr("cursor_button_listener", listener);
        _ = server.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        if (event.state == .released) {
            if (server.grabbed_toplevel) |toplevel| {
                if (server.outputAtCursor()) |output| {
                    toplevel.current_output = output;
                }
            }
            server.resetCursorMode();
        } else {
            if (server.viewAt(server.wlr_cursor.x, server.wlr_cursor.y)) |result| {
                server.focusToplevel(result.toplevel, result.wlr_surface);
            } else {
                if (server.focused_toplevel) |toplevel| {
                    toplevel.setFocus(false);
                    server.focused_toplevel = null;
                }
            }
        }
    }

    fn cursorAxisCallback(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
        const server: *Server = @fieldParentPtr("cursor_axis_listener", listener);
        server.wlr_seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    /// Frame events are sent after regular pointer events to group multiple events together.
    /// E.g. 2 axis events may hapen at the same time, in which case a farme event won't be sent in between
    fn cursorFrameCallback(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const server: *Server = @fieldParentPtr("cursor_frame_listener", listener);
        server.wlr_seat.pointerNotifyFrame();
    }
};
