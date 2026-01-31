const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const gpa = std.heap.c_allocator;

const MIN_TOPLEVEL_WIDTH = 240;
const MIN_TOPLEVEL_HEIGHT = 135;

const OwmServer = struct {
    wl_server: *wl.Server,
    wl_socket: ?[:0]const u8 = null,

    wlr_scene: *wlr.Scene,
    wlr_scene_output_layout: *wlr.SceneOutputLayout,

    wlr_backend: *wlr.Backend,
    wlr_allocator: *wlr.Allocator,
    wlr_renderer: *wlr.Renderer,
    wlr_output_layout: *wlr.OutputLayout,
    outputs: std.ArrayList(*OwmOutput) = .empty,

    wlr_xdg_shell: *wlr.XdgShell,
    toplevels: wl.list.Head(OwmToplevel, .link) = undefined,
    new_toplevel_listener: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevelCallback),
    new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopupCallback),
    new_output_listener: wl.Listener(*wlr.Output) = .init(newOutputCallback),

    wlr_seat: *wlr.Seat,
    keyboards: wl.list.Head(OwmKeyboard, .link) = undefined,
    new_input_listener: wl.Listener(*wlr.InputDevice) = .init(newInputCallback),
    request_set_cursor_listener: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursorCallback),
    request_set_selection_listener: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelectionCallback),

    wlr_cursor: *wlr.Cursor,
    wlr_cursor_manager: *wlr.XcursorManager,
    grabbed_toplevel: ?*OwmToplevel = null,
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

    fn init(self: *OwmServer) anyerror!void {
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

        self.wlr_backend.events.new_output.add(&self.new_output_listener);

        self.wlr_xdg_shell.events.new_toplevel.add(&self.new_toplevel_listener);
        self.wlr_xdg_shell.events.new_popup.add(&self.new_popup_listener);
        self.toplevels.init();

        self.wlr_backend.events.new_input.add(&self.new_input_listener);
        self.wlr_seat.events.request_set_cursor.add(&self.request_set_cursor_listener);
        self.wlr_seat.events.request_set_selection.add(&self.request_set_selection_listener);
        self.keyboards.init();

        self.wlr_cursor.attachOutputLayout(self.wlr_output_layout);
        try self.wlr_cursor_manager.load(1);
        wlr_cursor.events.motion.add(&self.cursor_motion_listener);
        wlr_cursor.events.motion_absolute.add(&self.cursor_motion_absolute_listener);
        wlr_cursor.events.button.add(&self.cursor_button_listener);
        wlr_cursor.events.axis.add(&self.cursor_axis_listener);
        wlr_cursor.events.frame.add(&self.cursor_frame_listener);
    }

    fn deinit(self: *OwmServer) void {
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

        self.outputs.deinit(gpa);
    }

    fn setSocket(self: *OwmServer, socket: [:0]const u8) void {
        self.wl_socket = socket;
    }

    fn run(self: *OwmServer) anyerror!void {
        try self.wlr_backend.start();
        std.log.info("Running OWM compositor on WAYLAND_DISPLAY={s}", .{self.wl_socket.?});
        self.wl_server.run();
    }

    fn spawnChild(self: *OwmServer, command: [:0]const u8) anyerror!void {
        var child = std.process.Child.init(
            &[_][]const u8{ "/bin/sh", "-c", command },
            gpa,
        );

        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();
        try env_map.put("WAYLAND_DISPLAY", self.wl_socket.?);
        child.env_map = &env_map;

        try child.spawn();
    }

    fn outputAt(self: *OwmServer, lx: f64, ly: f64) ?*OwmOutput {
        for (self.outputs.items) |output| {
            const geom = output.getGeom();
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

    const ViewAtResponse = struct {
        sx: f64,
        sy: f64,
        wlr_surface: *wlr.Surface,
        toplevel: *OwmToplevel,
    };

    fn viewAt(self: *OwmServer, lx: f64, ly: f64) ?ViewAtResponse {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (self.wlr_scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*OwmToplevel, @ptrCast(@alignCast(n.node.data)))) |toplevel| {
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

    fn processCursorMotion(self: *OwmServer, time: u32) void {
        if (self.cursor_mode == .move) {
            const toplevel = self.grabbed_toplevel.?;
            toplevel.x = @as(i32, @intFromFloat(self.wlr_cursor.x - self.grab_x));
            toplevel.y = @as(i32, @intFromFloat(self.wlr_cursor.y - self.grab_y));
            toplevel.wlr_scene_tree.node.setPosition(toplevel.x, toplevel.y);
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

            const box = toplevel.wlr_xdg_toplevel.base.geometry;
            const new_x = new_left - box.x;
            const new_y = new_top - box.y;
            toplevel.x = new_x;
            toplevel.y = new_y;
            toplevel.wlr_scene_tree.node.setPosition(new_x, new_y);

            const new_width: i32 = new_right - new_left;
            const new_height: i32 = new_bottom - new_top;
            _ = toplevel.wlr_xdg_toplevel.setSize(new_width, new_height);
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

    fn resetCursorMode(self: *OwmServer) void {
        self.cursor_mode = .passthrough;
        self.grabbed_toplevel = null;
    }

    fn focusToplevel(self: *OwmServer, toplevel: *OwmToplevel, surface: *wlr.Surface) void {
        if (self.wlr_seat.keyboard_state.focused_surface) |prev_surface| {
            if (prev_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(prev_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);
            }
        }

        // Move new toplevel to the top
        toplevel.wlr_scene_tree.node.raiseToTop();
        toplevel.link.remove();
        self.toplevels.prepend(toplevel);

        _ = toplevel.wlr_xdg_toplevel.setActivated(true);

        const wlr_keyboard = self.wlr_seat.getKeyboard() orelse return;
        self.wlr_seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    fn handleKeybind(self: *OwmServer, key: xkb.Keysym) bool {
        switch (@intFromEnum(key)) {
            xkb.Keysym.Escape => self.wl_server.terminate(),
            xkb.Keysym.t => {
                self.spawnChild("cosmic-term") catch {
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

    /// Called when a new display is discovered
    fn newOutputCallback(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *OwmServer = @fieldParentPtr("new_output_listener", listener);
        if (!wlr_output.initRender(server.wlr_allocator, server.wlr_renderer)) {
            std.log.err("Failed to initialize render with allocator and renderer on new output", .{});
            return;
        }

        var state = wlr.Output.State.init();
        defer state.finish();
        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| {
            std.log.info("Output has the preferred mode {}x{} {}Hz", .{ mode.width, mode.height, mode.refresh });
            state.setMode(mode);
        }
        if (!wlr_output.commitState(&state)) {
            std.log.err("Failed to commit state for new output", .{});
            return;
        }

        OwmOutput.create(server, wlr_output) catch {
            std.log.err("Failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };
    }

    /// Called when a client creates a new toplevel (app window)
    fn newXdgToplevelCallback(listener: *wl.Listener(*wlr.XdgToplevel), wlr_xdg_toplevel: *wlr.XdgToplevel) void {
        const server: *OwmServer = @fieldParentPtr("new_toplevel_listener", listener);
        OwmToplevel.create(server, wlr_xdg_toplevel) catch {
            std.log.err("Failed to allocate new toplevel", .{});
            wlr_xdg_toplevel.sendClose();
            return;
        };
    }

    /// Called when a client create a new popup
    fn newXdgPopupCallback(_: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
        OwmPopup.create(wlr_xdg_popup) catch {
            std.log.err("Failed to allocate new popup", .{});
            return;
        };
    }

    /// Called when a new input device becomes available
    fn newInputCallback(listener: *wl.Listener(*wlr.InputDevice), input_device: *wlr.InputDevice) void {
        const server: *OwmServer = @fieldParentPtr("new_input_listener", listener);
        server.wlr_seat.setCapabilities(.{
            .pointer = true,
            .keyboard = true,
        });

        switch (input_device.type) {
            .pointer => {
                server.wlr_cursor.attachInputDevice(input_device);
            },
            .keyboard => {
                OwmKeyboard.create(server, input_device) catch |err| {
                    std.log.err("Failed to allocate keyboard: {}", .{err});
                    return;
                };
            },
            else => {},
        }
    }

    /// Called when a client provides a cursor image
    fn requestSetCursorCallback(listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor), event: *wlr.Seat.event.RequestSetCursor) void {
        const server: *OwmServer = @fieldParentPtr("request_set_cursor_listener", listener);
        if (server.wlr_seat.pointer_state.focused_client) |client| {
            if (client == event.seat_client) { // Make sure the requesting client is focused
                server.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
            }
        }
    }

    /// Called when a client want to set the selection, e.g. copies something.
    fn requestSetSelectionCallback(listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection), event: *wlr.Seat.event.RequestSetSelection) void {
        const server: *OwmServer = @fieldParentPtr("request_set_selection_listener", listener);
        server.wlr_seat.setSelection(event.source, event.serial);
    }

    /// Called when pointer emits relative (_delta_) motion events
    fn cursorMotionCallback(listener: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
        const server: *OwmServer = @fieldParentPtr("cursor_motion_listener", listener);
        server.wlr_cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    /// Called when pointer emits an absolute motion event, e.g. on Wayland or X11 backend, pointer enters the window
    fn cursorMotionAbsoluteCallback(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
        const server: *OwmServer = @fieldParentPtr("cursor_motion_absolute_listener", listener);
        server.wlr_cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    fn cursorButtonCallback(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
        const server: *OwmServer = @fieldParentPtr("cursor_button_listener", listener);
        _ = server.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        if (event.state == .released) {
            if (server.grabbed_toplevel) |toplevel| {
                if (server.outputAt(server.wlr_cursor.x, server.wlr_cursor.y)) |output| {
                    toplevel.current_output_id = output.id;
                }
            }
            server.resetCursorMode();
        } else {
            if (server.viewAt(server.wlr_cursor.x, server.wlr_cursor.y)) |result| {
                server.focusToplevel(result.toplevel, result.wlr_surface);
            }
        }
    }

    fn cursorAxisCallback(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
        const server: *OwmServer = @fieldParentPtr("cursor_axis_listener", listener);
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
        const server: *OwmServer = @fieldParentPtr("cursor_frame_listener", listener);
        server.wlr_seat.pointerNotifyFrame();
    }
};

var OUTPUT_COUNTER: usize = 0;
const OwmOutput = struct {
    id: usize,
    owm_server: *OwmServer,
    wlr_output: *wlr.Output,
    geom: wlr.Box,

    frame_listener: wl.Listener(*wlr.Output) = .init(frameCallback),
    request_state_listener: wl.Listener(*wlr.Output.event.RequestState) = .init(requestStateCallback),
    destroy_listener: wl.Listener(*wlr.Output) = .init(destroyCallback),

    fn create(server: *OwmServer, wlr_output: *wlr.Output) anyerror!void {
        const owm_output = try gpa.create(OwmOutput);
        errdefer gpa.destroy(owm_output);

        // Add the new display to the right of all the other displays
        const layout_output = try server.wlr_output_layout.addAuto(wlr_output);
        const scene_output = try server.wlr_scene.createSceneOutput(wlr_output); // Add a viewport for the output to the scene graph.
        server.wlr_scene_output_layout.addOutput(layout_output, scene_output); // Add the output to the scene output layout. When the layout output is repositioned, the scene output will be repositioned accordingly.

        const geom = wlr.Box{
            .x = layout_output.x,
            .y = layout_output.y,
            .width = wlr_output.width,
            .height = wlr_output.height,
        };

        OUTPUT_COUNTER += 1;
        owm_output.* = .{
            .id = OUTPUT_COUNTER,
            .owm_server = server,
            .wlr_output = wlr_output,
            .geom = geom,
        };

        wlr_output.events.frame.add(&owm_output.frame_listener);
        wlr_output.events.request_state.add(&owm_output.request_state_listener);
        wlr_output.events.destroy.add(&owm_output.destroy_listener);

        try server.outputs.append(gpa, owm_output);
    }

    fn getGeom(self: *OwmOutput) wlr.Box {
        return self.geom;
    }

    /// Called every time when an output is ready to display a farme, generally at the refresh rate
    fn frameCallback(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const output: *OwmOutput = @fieldParentPtr("frame_listener", listener);
        const scene_output = output.owm_server.wlr_scene.getSceneOutput(wlr_output).?;
        // Render the scene if needed and commit the output
        _ = scene_output.commit(null);

        var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
        scene_output.sendFrameDone(&now);
    }

    /// Called when the backend requests a new state for the output. E.g. new mode request when resizing it in Wayland backend
    fn requestStateCallback(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
        const output: *OwmOutput = @fieldParentPtr("request_state_listener", listener);
        _ = output.wlr_output.commitState(event.state);
    }

    fn destroyCallback(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *OwmOutput = @fieldParentPtr("destroy_listener", listener);

        output.frame_listener.link.remove();
        output.request_state_listener.link.remove();
        output.destroy_listener.link.remove();

        var index: usize = undefined;
        for (output.owm_server.outputs.items, 0..) |o, idx| {
            if (o.id == output.id) {
                index = idx;
                break;
            }
        }
        _ = output.owm_server.outputs.orderedRemove(index);
        gpa.destroy(output);
    }
};

const OwmToplevel = struct {
    owm_server: *OwmServer,
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

    fn create(server: *OwmServer, wlr_xdg_toplevel: *wlr.XdgToplevel) anyerror!void {
        const toplevel = try gpa.create(OwmToplevel);
        errdefer gpa.destroy(toplevel);

        const output = server.outputAt(server.wlr_cursor.x, server.wlr_cursor.y);
        if (output == null) {
            return error.CursorNotOnAnyOutput;
        }

        toplevel.* = .{
            .owm_server = server,
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
    }

    /// Called when the surface is mapped, or ready to display on screen
    fn mapCallback(listener: *wl.Listener(void)) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("map_listener", listener);
        toplevel.owm_server.toplevels.prepend(toplevel);
        toplevel.owm_server.focusToplevel(toplevel, toplevel.wlr_xdg_toplevel.base.surface);
    }

    /// Called when the surface should no longer be shown
    fn unmapCallback(listener: *wl.Listener(void)) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("unmap_listener", listener);
        if (toplevel.owm_server.grabbed_toplevel == toplevel) {
            toplevel.owm_server.resetCursorMode();
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
            _ = toplevel.wlr_xdg_toplevel.setSize(0, 0);
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

        gpa.destroy(toplevel);
    }

    fn requestMoveCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), _: *wlr.XdgToplevel.event.Move) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("request_move_listener", listener);
        const server = toplevel.owm_server;
        server.grabbed_toplevel = toplevel;
        server.cursor_mode = .move;
        server.grab_x = server.wlr_cursor.x - @as(f64, @floatFromInt(toplevel.x));
        server.grab_y = server.wlr_cursor.y - @as(f64, @floatFromInt(toplevel.y));
    }

    fn requestResizeCallback(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
        const toplevel: *OwmToplevel = @fieldParentPtr("request_resize_listener", listener);
        const server = toplevel.owm_server;

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
            var located_output: *OwmOutput = undefined;
            for (toplevel.owm_server.outputs.items) |output| {
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

const OwmPopup = struct {
    wlr_xdg_popup: *wlr.XdgPopup,
    link: wl.list.Link = undefined,

    commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
    destroy_listener: wl.Listener(void) = .init(destroyCallback),

    fn create(wlr_xdg_popup: *wlr.XdgPopup) anyerror!void {
        const xdg_surface = wlr_xdg_popup.base;
        // Add to the scene graph so that it gets rendered.
        const parent = wlr.XdgSurface.tryFromWlrSurface(wlr_xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
            return;
        };
        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to allocate xdg popup node", .{});
            return;
        };
        xdg_surface.data = scene_tree;

        const popup = try gpa.create(OwmPopup);
        errdefer gpa.destroy(popup);

        popup.* = .{
            .wlr_xdg_popup = wlr_xdg_popup,
        };

        xdg_surface.surface.events.commit.add(&popup.commit_listener);
        wlr_xdg_popup.events.destroy.add(&popup.destroy_listener);
    }

    /// Called when a new surface state is commited
    fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const popup: *OwmPopup = @fieldParentPtr("commit_listener", listener);
        if (popup.wlr_xdg_popup.base.initial_commit) {
            _ = popup.wlr_xdg_popup.base.scheduleConfigure();
        }
    }

    fn destroyCallback(listener: *wl.Listener(void)) void {
        const popup: *OwmPopup = @fieldParentPtr("destroy_listener", listener);

        popup.commit_listener.link.remove();
        popup.destroy_listener.link.remove();

        gpa.destroy(popup);
    }
};

const OwmKeyboard = struct {
    owm_server: *OwmServer,
    wlr_device: *wlr.InputDevice,
    link: wl.list.Link = undefined,

    modifiers_listener: wl.Listener(*wlr.Keyboard) = .init(modifiersCallback),
    key_listener: wl.Listener(*wlr.Keyboard.event.Key) = .init(keyCallback),
    destroy_listener: wl.Listener(*wlr.InputDevice) = .init(destroyCallback),

    fn create(server: *OwmServer, device: *wlr.InputDevice) !void {
        const keyboard = try gpa.create(OwmKeyboard);
        errdefer gpa.destroy(keyboard);

        keyboard.* = .{ .owm_server = server, .wlr_device = device };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        const wlr_keyboard = device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.setRepeatInfo(25, 300);

        wlr_keyboard.events.modifiers.add(&keyboard.modifiers_listener);
        wlr_keyboard.events.key.add(&keyboard.key_listener);
        device.events.destroy.add(&keyboard.destroy_listener);

        server.wlr_seat.setKeyboard(wlr_keyboard);
        server.keyboards.append(keyboard);
    }

    fn modifiersCallback(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
        const keyboard: *OwmKeyboard = @fieldParentPtr("modifiers_listener", listener);
        keyboard.owm_server.wlr_seat.setKeyboard(wlr_keyboard);
        keyboard.owm_server.wlr_seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
    }

    fn keyCallback(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *OwmKeyboard = @fieldParentPtr("key_listener", listener);
        const wlr_keyboard = keyboard.wlr_device.toKeyboard();

        // Translate libinput keycode to xkbcommon
        const keycode = event.keycode + 8;

        var handled = false;
        if (wlr_keyboard.getModifiers().alt and event.state == .pressed) {
            for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
                if (keyboard.owm_server.handleKeybind(sym)) {
                    handled = true;
                    break;
                }
            }
        }

        if (!handled) {
            keyboard.owm_server.wlr_seat.setKeyboard(wlr_keyboard);
            keyboard.owm_server.wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        }
    }

    fn destroyCallback(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const keyboard: *OwmKeyboard = @fieldParentPtr("destroy_listener", listener);

        keyboard.link.remove();
        keyboard.modifiers_listener.link.remove();
        keyboard.key_listener.link.remove();
        keyboard.destroy_listener.link.remove();

        gpa.destroy(keyboard);
    }
};

pub fn main() anyerror!void {
    wlr.log.init(.info, null);

    var server: OwmServer = undefined;
    try server.init();
    defer server.deinit();

    var buf: [11]u8 = undefined;
    const wl_socket = try server.wl_server.addSocketAuto(&buf);
    server.setSocket(wl_socket); // Setting the socket in `init` causes odd behaviour that I'm unable to understand, it uses a random value on `runProcess`

    try server.run();
}
