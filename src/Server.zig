pub const Server = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("owm.zig");

const MIN_CLIENT_WIDTH = 240;
const MIN_CLIENT_HEIGHT = 135;

wl_server: *wl.Server,
wl_socket: [11]u8 = undefined,

wlr_scene: *wlr.Scene,
scene_tree_apps: *wlr.SceneTree,
scene_tree_foreground: *wlr.SceneTree,
wlr_scene_output_layout: *wlr.SceneOutputLayout,

wlr_backend: *wlr.Backend,
wlr_allocator: *wlr.Allocator,
wlr_renderer: *wlr.Renderer,
wlr_output_layout: *wlr.OutputLayout,
outputs: wl.list.Head(owm.Output, .link) = undefined,
new_output_listener: wl.Listener(*wlr.Output) = .init(newOutputCallback),

wlr_layer_shell_v1: *wlr.LayerShellV1,
new_layer_surface_listener: wl.Listener(*wlr.LayerSurfaceV1) = .init(newLayerSurfaceCallback),

wlr_xwayland: *wlr.Xwayland,
xwayland_new_surface_listener: wl.Listener(*wlr.XwaylandSurface) = .init(xwaylandNewSurfaceCallback),

wlr_xdg_shell: *wlr.XdgShell,
windows: wl.list.Head(owm.client.window.Window, .link) = undefined,
new_toplevel_listener: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevelCallback),

wlr_seat: *wlr.Seat,
focused_window: ?*owm.client.window.Window = null,
new_input_listener: wl.Listener(*wlr.InputDevice) = .init(newInputCallback),
request_set_cursor_listener: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursorCallback),
request_set_selection_listener: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelectionCallback),

wlr_cursor: *wlr.Cursor,
wlr_cursor_manager: *wlr.XcursorManager,
grabbed_window: ?*owm.client.window.Window = null,
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
    wlr.log.init(.err, null);

    const wl_server = try wl.Server.create();

    const event_loop = wl_server.getEventLoop();
    const wlr_backend = try wlr.Backend.autocreate(event_loop, null); // Auto picks the backend (Wayland, X11, DRM+KSM)
    const wlr_renderer = try wlr.Renderer.autocreate(wlr_backend); // Auto picks a renderer (Pixman, GLES2, Vulkan)
    const wlr_allocator = try wlr.Allocator.autocreate(wlr_backend, wlr_renderer); // The bridge between the backend and renderer. It handdles the buffer creeation, allowing wlroots to render onto the screen
    const wlr_output_layout = try wlr.OutputLayout.create(wl_server); // Utility for working with an arrangement of screens in a physical layout
    const wlr_layer_shell_v1 = try wlr.LayerShellV1.create(wl_server, 5); // Protocol for status bars
    const wlr_scene = try wlr.Scene.create(); // Abstraction that handles all rendering and damage tracking
    const wlr_scene_output_layout = try wlr_scene.attachOutputLayout(wlr_output_layout);
    const wlr_xdg_shell = try wlr.XdgShell.create(wl_server, 3); // XDG protocol for app windows
    const wlr_seat = try wlr.Seat.create(wl_server, "seat0"); // Input device seat
    const wlr_cursor = try wlr.Cursor.create(); // Mouse
    const wlr_cursor_manager = try wlr.XcursorManager.create(null, 24); // Sources cursor images

    const wlr_compositor = try wlr.Compositor.create(wl_server, 6, wlr_renderer); // Allows clients to allocate surfaces
    _ = try wlr.Subcompositor.create(wl_server); // Allows clients to assign role to subsurfaces
    _ = try wlr.DataDeviceManager.create(wl_server); // Handles clipboard
    _ = try wlr.XdgOutputManagerV1.create(wl_server, wlr_output_layout); // Protocol required by `waybar`
    const wlr_xwayland = try wlr.Xwayland.create(wl_server, wlr_compositor, true);

    const scene_tree_apps = try wlr_scene.tree.createSceneTree();
    scene_tree_apps.node.setPosition(0, 0);
    const scene_tree_foreground = try wlr_scene.tree.createSceneTree();
    scene_tree_foreground.node.setPosition(0, 0);
    scene_tree_foreground.node.raiseToTop();

    self.* = .{
        .wl_server = wl_server,
        .wlr_backend = wlr_backend,
        .wlr_renderer = wlr_renderer,
        .wlr_allocator = wlr_allocator,
        .wlr_scene = wlr_scene,
        .scene_tree_apps = scene_tree_apps,
        .scene_tree_foreground = scene_tree_foreground,
        .wlr_output_layout = wlr_output_layout,
        .wlr_layer_shell_v1 = wlr_layer_shell_v1,
        .wlr_scene_output_layout = wlr_scene_output_layout,
        .wlr_xdg_shell = wlr_xdg_shell,
        .wlr_seat = wlr_seat,
        .wlr_cursor = wlr_cursor,
        .wlr_cursor_manager = wlr_cursor_manager,
        .wlr_xwayland = wlr_xwayland,
    };

    _ = try wl_server.addSocketAuto(&self.wl_socket);

    try self.wlr_renderer.initServer(wl_server);

    self.windows.init();

    self.outputs.init();
    self.wlr_backend.events.new_output.add(&self.new_output_listener);

    self.wlr_xdg_shell.events.new_toplevel.add(&self.new_toplevel_listener);

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

    wlr_layer_shell_v1.events.new_surface.add(&self.new_layer_surface_listener);

    wlr_xwayland.events.new_surface.add(&self.xwayland_new_surface_listener);
}

pub fn deinit(self: *Server) void {
    self.wl_server.destroyClients();

    self.xwayland_new_surface_listener.link.remove();

    self.new_layer_surface_listener.link.remove();

    self.new_input_listener.link.remove();
    self.new_output_listener.link.remove();

    self.new_toplevel_listener.link.remove();
    self.request_set_cursor_listener.link.remove();
    self.request_set_selection_listener.link.remove();
    self.cursor_motion_listener.link.remove();
    self.cursor_motion_absolute_listener.link.remove();
    self.cursor_button_listener.link.remove();
    self.cursor_axis_listener.link.remove();
    self.cursor_frame_listener.link.remove();

    self.wlr_xwayland.destroy();
    self.wlr_backend.destroy();
    self.wl_server.destroy();
}

pub fn run(self: *Server) anyerror!void {
    try self.wlr_backend.start();
    owm.log.infof(
        "Running OWM compositor on WAYLAND_DISPLAY='{s}' and Xwayland DISLPAY='{s}'",
        .{
            self.wl_socket,
            self.wlr_xwayland.display_name,
        },
    );
    self.wl_server.run();
}

pub fn handleKeybind(self: *Server, key: xkb.Keysym) bool {
    switch (@intFromEnum(key)) {
        xkb.Keysym.Escape => {
            self.wl_server.terminate();
        },
        xkb.Keysym.t => {
            self.spawnChild("ghostty") catch {
                owm.log.err("Failed to spawn cosmic-term");
            };
        },
        xkb.Keysym.f => {
            self.spawnChild("cosmic-files") catch {
                owm.log.err("Failed to spawn cosmic-files");
            };
        },
        xkb.Keysym.b => {
            self.spawnChild("brave") catch {
                owm.log.err("Failed to spawm brave");
            };
        },
        xkb.Keysym.m => {
            if (self.focused_window) |window| {
                window.toggleMaximize();
            }
        },
        xkb.Keysym.F1 => {
            if (self.focused_window) |_| {
                const first_window = self.windows.first().?;
                first_window.link.remove();
                self.windows.append(first_window);
                self.focusWindow(self.windows.first().?);
            } else if (self.windows.first()) |first_client| {
                self.focusWindow(first_client);
            }
        },
        else => return false,
    }
    return true;
}

pub fn focusWindow(self: *Server, new_window: *owm.client.window.Window) void {
    if (self.focused_window) |prev_window| {
        if (prev_window == new_window) {
            return;
        }
        prev_window.setFocus(false);
    }

    new_window.setFocus(true);

    const wlr_keyboard = self.wlr_seat.getKeyboard() orelse return;
    self.wlr_seat.keyboardNotifyEnter(
        new_window.getWlrSurface(),
        wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
        &wlr_keyboard.modifiers,
    );

    new_window.link.remove();
    self.windows.prepend(new_window);
    self.focused_window = new_window;
}

fn spawnChild(self: *Server, command: [:0]const u8) anyerror!void {
    var child = std.process.Child.init(
        &[_][]const u8{ "/bin/sh", "-c", command },
        owm.c_alloc,
    );

    var env_map = try std.process.getEnvMap(owm.c_alloc);
    defer env_map.deinit();
    try env_map.put("WAYLAND_DISPLAY", &self.wl_socket);
    try env_map.put("DISPLAY", std.mem.span(self.wlr_xwayland.display_name));
    child.env_map = &env_map;

    try child.spawn();
}

pub fn outputAtCursor(self: *Server) ?*owm.Output {
    return self.outputAt(self.wlr_cursor.x, self.wlr_cursor.y);
}

pub fn outputAt(self: *Server, lx: f64, ly: f64) ?*owm.Output {
    var output_iterator = self.outputs.iterator(.forward);
    while (output_iterator.next()) |output| {
        const area = output.area;
        const x = @as(f64, @floatFromInt(area.x));
        const y = @as(f64, @floatFromInt(area.y));
        const width = @as(f64, @floatFromInt(area.width));
        const height = @as(f64, @floatFromInt(area.height));
        if (x <= lx and lx < x + width and y <= ly and ly < y + height) {
            return output;
        }
    }
    return null;
}

pub fn resetCursorMode(self: *Server) void {
    self.cursor_mode = .passthrough;
    self.grabbed_window = null;
}

const WindowAtResponse = struct {
    sx: f64,
    sy: f64,
    wlr_surface: *wlr.Surface,
    window: *owm.client.window.Window,
};

fn windowAt(self: *Server, lx: f64, ly: f64) ?WindowAtResponse {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (self.wlr_scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

        var it: ?*wlr.SceneTree = node.parent;
        while (it) |n| : (it = n.node.parent) {
            if (owm.client.window.Window.fromOpaquePtr(n.node.data)) |window| {
                return WindowAtResponse{
                    .sx = sx,
                    .sy = sy,
                    .wlr_surface = scene_surface.surface,
                    .window = window,
                };
            }
        }
    }

    return null;
}

const ViewAtResponse = struct {
    sx: f64,
    sy: f64,
    wlr_surface: *wlr.Surface,
};

fn viewAt(self: *Server, lx: f64, ly: f64) ?ViewAtResponse {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (self.wlr_scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;
        return ViewAtResponse{
            .sx = sx,
            .sy = sy,
            .wlr_surface = scene_surface.surface,
        };
    }

    return null;
}

fn processCursorMotion(self: *Server, time: u32) void {
    if (self.cursor_mode == .move) {
        const grabbed_window = self.grabbed_window.?;
        grabbed_window.setPos(
            @as(i32, @intFromFloat(self.wlr_cursor.x - self.grab_x)),
            @as(i32, @intFromFloat(self.wlr_cursor.y - self.grab_y)),
        );
        return;
    } else if (self.cursor_mode == .resize) {
        const grabbed_window = self.grabbed_window.?;
        const border_x = @as(i32, @intFromFloat(self.wlr_cursor.x - self.grab_x));
        const border_y = @as(i32, @intFromFloat(self.wlr_cursor.y - self.grab_y));

        var new_left = self.grab_box.x;
        var new_right = self.grab_box.x + self.grab_box.width;
        var new_top = self.grab_box.y;
        var new_bottom = self.grab_box.y + self.grab_box.height;

        if (self.resize_edges.top) {
            new_top = border_y;
            if (new_top + MIN_CLIENT_HEIGHT >= new_bottom) { // Make sure new_top isn't below new_bottom
                new_top = new_bottom - MIN_CLIENT_HEIGHT;
            }
        } else if (self.resize_edges.bottom) {
            new_bottom = border_y;
            if (new_bottom - MIN_CLIENT_HEIGHT <= new_top) { // Make sure new_bottom isn't above new_top
                new_bottom = new_top + MIN_CLIENT_HEIGHT;
            }
        }

        if (self.resize_edges.left) {
            new_left = border_x;
            if (new_left + MIN_CLIENT_WIDTH >= new_right) { // Make sure new_left isn't right of new_right
                new_left = new_right - MIN_CLIENT_WIDTH;
            }
        } else if (self.resize_edges.right) {
            new_right = border_x;
            if (new_right - MIN_CLIENT_WIDTH <= new_left) { // Make sure new_right isn't left of new_left
                new_right = new_left + MIN_CLIENT_WIDTH;
            }
        }

        const box = grabbed_window.getGeom();
        const new_x = new_left - box.x;
        const new_y = new_top - box.y;
        grabbed_window.setPos(new_x, new_y);

        const new_width: i32 = new_right - new_left;
        const new_height: i32 = new_bottom - new_top;
        grabbed_window.setSize(new_width, new_height);
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

    const new_output = owm.Output.create(wlr_output) catch |err| {
        owm.log.errf("Failed to allocate new output {}", .{err});
        wlr_output.destroy();
        return;
    };

    if (!new_output.isDisplay()) {
        return;
    }

    var outputs: std.ArrayList(*owm.Output) = .empty;
    var output_iter = server.outputs.iterator(.forward);
    while (output_iter.next()) |it| {
        outputs.append(owm.alloc, it) catch unreachable;
    }

    if (owm.config.getOutput().findArrangementForOutputs(&outputs)) |*arrangement| {
        owm.log.info("Output arrangement found, setting up displays according to it");

        for (arrangement.displays.items) |*display| {
            var output_to_modify: ?*owm.Output = null;
            for (outputs.items) |output| {
                if (std.mem.eql(u8, output.id, display.id)) {
                    output_to_modify = output;
                }
            }

            if (!display.active) {
                owm.log.infof("Disabling output {s}", .{display.id});
                output_to_modify.?.disableOutput() catch |err| {
                    owm.log.errf("Failed to disable output {}", .{err});
                };
                continue;
            }

            owm.log.infof(
                "Setting output {s} to pos ({}, {}) mode {}x{} {}Hz",
                .{ display.id, display.x, display.y, display.width, display.height, display.refresh },
            );

            output_to_modify.?.setModeAndPos(
                display.x,
                display.y,
                owm.Output.Mode{
                    .width = display.width,
                    .height = display.height,
                    .refresh = display.refresh,
                },
            ) catch |err| {
                owm.log.errf("Failed to set mode and pos for output {s}: {}", .{ display.id, err });
                continue;
            };
        }
    } else {
        var displays = std.ArrayList(owm.config.OutputConfig.Arrangement.Display).initCapacity(owm.alloc, outputs.items.len) catch {
            owm.log.err("Failed to initialize memory for new arrangement");
            return;
        };

        for (outputs.items) |output| {
            displays.append(owm.alloc, owm.config.OutputConfig.Arrangement.Display{
                .id = output.id,
                .width = output.area.width,
                .height = output.area.height,
                .refresh = output.getRefresh(),
                .x = output.area.x,
                .y = output.area.y,
                .active = output.wlr_output.enabled,
            }) catch {
                owm.log.err("Failed to append display definition");
                displays.deinit(owm.alloc);
                return;
            };
        }
        const new_arrangement = owm.config.OutputConfig.Arrangement{ .displays = displays };
        owm.config.getOutput().addNewArrangement(new_arrangement) catch {
            displays.deinit(owm.alloc);
            return;
        };
    }
}

fn xwaylandNewSurfaceCallback(listener: *wl.Listener(*wlr.XwaylandSurface), wlr_xwayland_surface: *wlr.XwaylandSurface) void {
    _ = listener;
    if (wlr_xwayland_surface.override_redirect) {
        _ = owm.client.XwalandOverride.create(wlr_xwayland_surface) catch |err| {
            owm.log.errf("Failed to allocate XwaylandOverride {}", .{err});
            return;
        };
    } else {
        _ = owm.client.window.Window.newXwayland(wlr_xwayland_surface) catch |err| {
            owm.log.errf("Failed to allocate Xwayland {}", .{err});
            return;
        };
    }
}

/// Called when a client creates a new toplevel (app window)
fn newXdgToplevelCallback(_: *wl.Listener(*wlr.XdgToplevel), wlr_xdg_toplevel: *wlr.XdgToplevel) void {
    _ = owm.client.window.Window.newToplevel(wlr_xdg_toplevel) catch |err| {
        owm.log.errf("Failed to allocate new toplevel {}", .{err});
        wlr_xdg_toplevel.sendClose();
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
            _ = owm.Keyboard.create(input_device) catch |err| {
                owm.log.errf("Failed to allocate keyboard: {}", .{err});
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
        if (server.grabbed_window) |grabbed_window| {
            if (server.outputAtCursor()) |output| {
                grabbed_window.setCurrentOutput(output);
            }
        }
        server.resetCursorMode();
    } else {
        if (server.windowAt(server.wlr_cursor.x, server.wlr_cursor.y)) |result| {
            server.focusWindow(result.window);
        } else if (server.focused_window) |window| {
            window.setFocus(false);
            server.focused_window = null;
            server.wlr_seat.keyboardNotifyClearFocus();
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

fn newLayerSurfaceCallback(_: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    if (wlr_layer_surface.output == null) {
        wlr_layer_surface.output = owm.server.outputs.first().?.wlr_output;
    }

    _ = owm.client.LayerSurface.create(wlr_layer_surface) catch {
        owm.log.err("Failed to allocate new LayerSurface");
        return;
    };
}
