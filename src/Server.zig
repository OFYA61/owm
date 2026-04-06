pub const Server = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("owm.zig");
const log = owm.log;

wl_server: *wl.Server,
wl_socket: [11]u8 = undefined,

scene: owm.Scene,
seat: owm.Seat,

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
new_xdg_toplevel_listener: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevelCallback),

pub fn init(self: *Server) anyerror!void {
    wlr.log.init(.err, null);

    const wl_server = try wl.Server.create();

    const event_loop = wl_server.getEventLoop();
    const wlr_backend = try wlr.Backend.autocreate(event_loop, null); // Auto picks the backend (Wayland, X11, DRM+KSM)
    const wlr_renderer = try wlr.Renderer.autocreate(wlr_backend); // Auto picks a renderer (Pixman, GLES2, Vulkan)
    const wlr_allocator = try wlr.Allocator.autocreate(wlr_backend, wlr_renderer); // The bridge between the backend and renderer. It handdles the buffer creeation, allowing wlroots to render onto the screen
    const wlr_output_layout = try wlr.OutputLayout.create(wl_server); // Utility for working with an arrangement of screens in a physical layout
    const wlr_layer_shell_v1 = try wlr.LayerShellV1.create(wl_server, 5); // Protocol for status bars
    const wlr_xdg_shell = try wlr.XdgShell.create(wl_server, 3); // XDG protocol for app windows

    const wlr_compositor = try wlr.Compositor.create(wl_server, 6, wlr_renderer); // Allows clients to allocate surfaces
    _ = try wlr.Subcompositor.create(wl_server); // Allows clients to assign role to subsurfaces
    _ = try wlr.DataDeviceManager.create(wl_server); // Handles clipboard
    _ = try wlr.XdgOutputManagerV1.create(wl_server, wlr_output_layout); // Protocol required by `waybar`
    const wlr_xwayland = try wlr.Xwayland.create(wl_server, wlr_compositor, true);

    self.* = .{
        .wl_server = wl_server,
        .wlr_backend = wlr_backend,
        .wlr_renderer = wlr_renderer,
        .wlr_allocator = wlr_allocator,
        .wlr_output_layout = wlr_output_layout,
        .scene = try owm.Scene.create(wlr_output_layout),
        .seat = try owm.Seat.create(wl_server),
        .wlr_layer_shell_v1 = wlr_layer_shell_v1,
        .wlr_xdg_shell = wlr_xdg_shell,
        .wlr_xwayland = wlr_xwayland,
    };

    _ = try wl_server.addSocketAuto(&self.wl_socket);

    try self.wlr_renderer.initServer(wl_server);

    self.outputs.init();
    self.wlr_backend.events.new_output.add(&self.new_output_listener);

    self.wlr_xdg_shell.events.new_toplevel.add(&self.new_xdg_toplevel_listener);

    try self.seat.init(self.wlr_backend, self.wlr_output_layout);

    wlr_layer_shell_v1.events.new_surface.add(&self.new_layer_surface_listener);

    wlr_xwayland.events.new_surface.add(&self.xwayland_new_surface_listener);
}

pub fn deinit(self: *Server) void {
    self.wl_server.destroyClients();
    self.xwayland_new_surface_listener.link.remove();
    self.new_layer_surface_listener.link.remove();
    self.new_output_listener.link.remove();
    self.new_xdg_toplevel_listener.link.remove();
    self.seat.deinit();
    self.wlr_xwayland.destroy();
    self.wlr_backend.destroy();
    self.wl_server.destroy();
}

pub fn run(self: *Server) anyerror!void {
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

pub fn handleKeybind(self: *Server, key: xkb.Keysym) bool {
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
        else => return false,
    }
    return true;
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
    const cursor_pos = self.seat.getCursorPos();
    const cx = cursor_pos.x;
    const cy = cursor_pos.y;
    var output_iterator = owm.SERVER.outputs.iterator(.forward);
    while (output_iterator.next()) |output| {
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

/// Called when a new display is discovered
fn newOutputCallback(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const server: *Server = @fieldParentPtr("new_output_listener", listener);

    const new_output = owm.Output.create(wlr_output) catch |err| {
        log.errf("Failed to allocate new output {}", .{err});
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
        log.info("Output arrangement found, setting up displays according to it");

        for (arrangement.displays.items) |*display| {
            var output_to_modify: ?*owm.Output = null;
            for (outputs.items) |output| {
                if (std.mem.eql(u8, output.id, display.id)) {
                    output_to_modify = output;
                }
            }

            if (!display.active) {
                log.infof("Disabling output {s}", .{display.id});
                output_to_modify.?.disableOutput() catch |err| {
                    log.errf("Failed to disable output {}", .{err});
                };
                continue;
            }

            log.infof(
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
                log.errf("Failed to set mode and pos for output {s}: {}", .{ display.id, err });
                continue;
            };
        }
    } else {
        var displays = std.ArrayList(owm.config.OutputConfig.Arrangement.Display).initCapacity(owm.alloc, outputs.items.len) catch {
            log.err("Failed to initialize memory for new arrangement");
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
                log.err("Failed to append display definition");
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
        wlr_layer_surface.output = owm.SERVER.outputs.first().?.wlr_output;
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
