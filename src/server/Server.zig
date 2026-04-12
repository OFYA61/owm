const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("root").owm;
const log = owm.log;

const Output = @import("Output.zig");
const OutputManager = @import("OutputManager.zig");
const Scene = @import("Scene.zig");
const Seat = @import("Seat.zig");

wl_server: *wl.Server,
wl_socket: [11]u8 = undefined,

output_manager: OutputManager,
scene: Scene,
seat: Seat,

wlr_backend: *wlr.Backend,
wlr_allocator: *wlr.Allocator,
wlr_renderer: *wlr.Renderer,

wlr_layer_shell_v1: *wlr.LayerShellV1,
new_layer_surface_listener: wl.Listener(*wlr.LayerSurfaceV1) = .init(newLayerSurfaceCallback),

wlr_xwayland: *wlr.Xwayland,
xwayland_new_surface_listener: wl.Listener(*wlr.XwaylandSurface) = .init(xwaylandNewSurfaceCallback),

wlr_xdg_shell: *wlr.XdgShell,
new_xdg_toplevel_listener: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevelCallback),

pub fn init(self: *Self) anyerror!void {
    wlr.log.init(.err, null);

    const wl_server = try wl.Server.create();

    const event_loop = wl_server.getEventLoop();
    const wlr_backend = try wlr.Backend.autocreate(event_loop, null); // Auto picks the backend (Wayland, X11, DRM+KSM)
    const wlr_renderer = try wlr.Renderer.autocreate(wlr_backend); // Auto picks a renderer (Pixman, GLES2, Vulkan)
    const wlr_allocator = try wlr.Allocator.autocreate(wlr_backend, wlr_renderer); // The bridge between the backend and renderer. It handdles the buffer creeation, allowing wlroots to render onto the screen
    const wlr_layer_shell_v1 = try wlr.LayerShellV1.create(wl_server, 5); // Protocol for status bars
    const wlr_xdg_shell = try wlr.XdgShell.create(wl_server, 3); // XDG protocol for app windows

    const wlr_compositor = try wlr.Compositor.create(wl_server, 6, wlr_renderer); // Allows clients to allocate surfaces
    _ = try wlr.Subcompositor.create(wl_server); // Allows clients to assign role to subsurfaces
    _ = try wlr.DataDeviceManager.create(wl_server); // Handles clipboard
    const wlr_xwayland = try wlr.Xwayland.create(wl_server, wlr_compositor, true);

    const output_manager = try OutputManager.create(wl_server);
    const scene = try Scene.create(output_manager.wlr_output_layout);
    const seat = try Seat.create(wl_server);

    self.* = .{
        .wl_server = wl_server,
        .wlr_backend = wlr_backend,
        .wlr_renderer = wlr_renderer,
        .wlr_allocator = wlr_allocator,
        .output_manager = output_manager,
        .scene = scene,
        .seat = seat,
        .wlr_layer_shell_v1 = wlr_layer_shell_v1,
        .wlr_xdg_shell = wlr_xdg_shell,
        .wlr_xwayland = wlr_xwayland,
    };

    _ = try wl_server.addSocketAuto(&self.wl_socket);

    try self.wlr_renderer.initServer(wl_server);

    self.output_manager.init();
    try self.seat.init(self.wlr_backend, self.output_manager.wlr_output_layout);

    self.wlr_xdg_shell.events.new_toplevel.add(&self.new_xdg_toplevel_listener);

    wlr_layer_shell_v1.events.new_surface.add(&self.new_layer_surface_listener);

    wlr_xwayland.events.new_surface.add(&self.xwayland_new_surface_listener);
}

pub fn deinit(self: *Self) void {
    self.wl_server.destroyClients();
    self.scene.deinit();
    self.xwayland_new_surface_listener.link.remove();
    self.new_layer_surface_listener.link.remove();
    self.new_xdg_toplevel_listener.link.remove();
    self.output_manager.deinit();
    self.seat.deinit();
    self.wlr_xwayland.destroy();
    self.wlr_backend.destroy();
    self.wl_server.destroy();
}

pub fn run(self: *Self) anyerror!void {
    try self.wlr_backend.start();
    log.infof(
        "Running OWM compositor on WAYLAND_DISPLAY='{s}' and Xwayland DISLPAY='{s}'",
        .{
            self.wl_socket,
            self.wlr_xwayland.display_name,
        },
    );
    self.wl_server.run();
}

pub fn handleKeybind(self: *Self, key: xkb.Keysym) bool {
    switch (@intFromEnum(key)) {
        xkb.Keysym.Escape => {
            self.wl_server.terminate();
        },
        xkb.Keysym.t => {
            self.spawnChild("ghostty") catch {
                log.err("Failed to spawn cosmic-term");
            };
        },
        xkb.Keysym.f => {
            self.spawnChild("cosmic-files") catch {
                log.err("Failed to spawn cosmic-files");
            };
        },
        xkb.Keysym.b => {
            self.spawnChild("brave") catch {
                log.err("Failed to spawm brave");
            };
        },
        xkb.Keysym.m => {
            if (self.seat.focused_window) |window| {
                window.toggleMaximize();
            }
        },
        xkb.Keysym.F1 => {
            if (self.seat.focused_window) |_| {
                if (self.scene.switchToNextWindowInWorkspace()) |next_window| {
                    self.seat.focusWindow(next_window);
                }
            } else {
                self.seat.focusTopWindow();
            }
        },
        xkb.Keysym.@"1" => {
            self.outputAtCursor().?.scene.switchWorkspace(0);
        },
        xkb.Keysym.@"2" => {
            self.outputAtCursor().?.scene.switchWorkspace(1);
        },
        xkb.Keysym.@"3" => {
            self.outputAtCursor().?.scene.switchWorkspace(2);
        },
        xkb.Keysym.@"4" => {
            self.outputAtCursor().?.scene.switchWorkspace(3);
        },
        xkb.Keysym.@"5" => {
            self.outputAtCursor().?.scene.switchWorkspace(4);
        },
        xkb.Keysym.@"6" => {
            self.outputAtCursor().?.scene.switchWorkspace(5);
        },
        xkb.Keysym.@"7" => {
            self.outputAtCursor().?.scene.switchWorkspace(6);
        },
        xkb.Keysym.@"8" => {
            self.outputAtCursor().?.scene.switchWorkspace(7);
        },
        xkb.Keysym.@"9" => {
            self.outputAtCursor().?.scene.switchWorkspace(8);
        },
        xkb.Keysym.@"0" => {
            self.outputAtCursor().?.scene.switchWorkspace(9);
        },
        else => return false,
    }
    return true;
}

fn spawnChild(self: *Self, command: [:0]const u8) anyerror!void {
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

pub fn outputAtCursor(self: *Self) ?*Output {
    const cursor_pos = self.seat.getCursorPos();
    const cx = cursor_pos.x;
    const cy = cursor_pos.y;
    var output_iterator = owm.SERVER.output_manager.outputs.iterator(.forward);
    while (output_iterator.next()) |output| {
        if (!output.is_active) {
            continue;
        }

        const area = output.area;
        const x = @as(f64, @floatFromInt(area.x));
        const y = @as(f64, @floatFromInt(area.y));
        const width = @as(f64, @floatFromInt(area.width));
        const height = @as(f64, @floatFromInt(area.height));
        if (x <= cx and cx < x + width and y <= cy and cy < y + height) {
            return output;
        }
    }
    return null;
}

fn xwaylandNewSurfaceCallback(listener: *wl.Listener(*wlr.XwaylandSurface), wlr_xwayland_surface: *wlr.XwaylandSurface) void {
    _ = listener;
    if (wlr_xwayland_surface.override_redirect) {
        _ = owm.client.XwaylandOverride.create(wlr_xwayland_surface) catch |err| {
            log.errf("Failed to allocate XwaylandOverride {}", .{err});
            return;
        };
    } else {
        _ = owm.client.window.Window.newXwayland(wlr_xwayland_surface) catch |err| {
            log.errf("Failed to allocate Xwayland {}", .{err});
            return;
        };
    }
}

/// Called when a client creates a new toplevel (app window)
fn newXdgToplevelCallback(_: *wl.Listener(*wlr.XdgToplevel), wlr_xdg_toplevel: *wlr.XdgToplevel) void {
    _ = owm.client.window.Window.newXdgToplevel(wlr_xdg_toplevel) catch |err| {
        log.errf("Failed to allocate new toplevel {}", .{err});
        wlr_xdg_toplevel.sendClose();
        return;
    };
}

fn newLayerSurfaceCallback(_: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
    if (wlr_layer_surface.output == null) {
        wlr_layer_surface.output = owm.SERVER.output_manager.outputs.first().?.wlr_output;
    }

    if (wlr_layer_surface.current.layer != .bottom) {
        log.err("Only `bottom` layer shell surfaces are supported at the moment");
        return;
    }

    _ = owm.client.LayerSurface.create(wlr_layer_surface) catch {
        log.err("Failed to allocate new LayerSurface");
        return;
    };
}
