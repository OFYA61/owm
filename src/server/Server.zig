const Self = @This();

const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const ext = @import("wayland").server.ext;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("root").owm;
const log = owm.log;

const LayerShell = @import("LayerShell.zig");
const Output = @import("Output.zig");
const OutputManager = @import("OutputManager.zig");
const Scene = @import("Scene.zig");
const Seat = @import("Seat.zig");
const XdgShell = @import("XdgShell.zig");
const Xwayland = @import("Xwayland.zig");

wl_server: *wl.Server,
wl_socket: [11]u8 = undefined,

wlr_backend: *wlr.Backend,
wlr_allocator: *wlr.Allocator,
wlr_renderer: *wlr.Renderer,

layer_shell: LayerShell,
output_manager: OutputManager,
scene: Scene,
seat: Seat,
xdg_shell: XdgShell,
xwayland: Xwayland,

pub fn init(self: *Self) anyerror!void {
    wlr.log.init(.err, null);

    const wl_server = try wl.Server.create();

    const event_loop = wl_server.getEventLoop();
    const wlr_backend = try wlr.Backend.autocreate(event_loop, null); // Auto picks the backend (Wayland, X11, DRM+KSM)
    const wlr_renderer = try wlr.Renderer.autocreate(wlr_backend); // Auto picks a renderer (Pixman, GLES2, Vulkan)
    const wlr_allocator = try wlr.Allocator.autocreate(wlr_backend, wlr_renderer); // The bridge between the backend and renderer. It handdles the buffer creeation, allowing wlroots to render onto the screen

    const wlr_compositor = try wlr.Compositor.create(wl_server, 6, wlr_renderer); // Allows clients to allocate surfaces
    _ = try wlr.Subcompositor.create(wl_server); // Allows clients to assign role to subsurfaces
    _ = try wlr.DataDeviceManager.create(wl_server); // Handles clipboard

    const layer_shell = try LayerShell.create(wl_server);
    const output_manager = try OutputManager.create(wl_server);
    const scene = try Scene.create(output_manager.wlr_output_layout);
    const seat = try Seat.create(wl_server);
    const xdg_shell = try XdgShell.create(wl_server);
    const xwayland = try Xwayland.create(wl_server, wlr_compositor);

    self.* = .{
        .wl_server = wl_server,
        .wlr_backend = wlr_backend,
        .wlr_renderer = wlr_renderer,
        .wlr_allocator = wlr_allocator,
        .layer_shell = layer_shell,
        .output_manager = output_manager,
        .scene = scene,
        .seat = seat,
        .xdg_shell = xdg_shell,
        .xwayland = xwayland,
    };

    self.scene.init();

    _ = try wl_server.addSocketAuto(&self.wl_socket);

    try self.wlr_renderer.initServer(wl_server);

    self.layer_shell.init();
    self.output_manager.init();
    try self.seat.init(self.wlr_backend, self.output_manager.wlr_output_layout);
    self.xdg_shell.init();
    self.xwayland.init();

    owm.env.putVar("WAYLAND_DISPLAY", &self.wl_socket);
}

pub fn deinit(self: *Self) void {
    log.debug("Server: Closing wayland compositor");
    log.debug("Server Destorying clients");
    self.wl_server.destroyClients();

    self.layer_shell.deinit();
    self.output_manager.deinit();
    self.seat.deinit();
    self.xdg_shell.deinit();
    self.xwayland.deinit();

    log.debug("Server: Cleaning up Backend");
    self.wlr_backend.destroy();

    self.wl_server.getEventLoop().dispatch(0) catch {
        log.err("Server: Failed to dispatch events on cleanup");
    };

    self.scene.deinit();

    log.debug("Server: Cleaning up Display");
    self.wl_server.destroy();
}

pub fn run(self: *Self) anyerror!void {
    log.infof(
        "Running OWM compositor on WAYLAND_DISPLAY='{s}' and Xwayland DISLPAY='{s}'",
        .{
            self.wl_socket,
            self.xwayland.wlr_xwayland.display_name,
        },
    );
    try self.wlr_backend.start();
    owm.config.startup.runStartupCommands();
    self.wl_server.run();
}

pub fn handleKeybind(self: *Self, modifiers: wlr.Keyboard.ModifierMask, key_code: u32) bool {
    if (owm.config.keybinds.getKeybind(modifiers, key_code)) |keybind| {
        switch (keybind.action) {
            .Terminate => {
                self.wl_server.terminate();
            },
            .NextWindow => {
                if (self.seat.focused_window) |_| {
                    if (self.outputAtCursor()) |output| {
                        if (output.sceneSwitchToNextWindow()) |next_window| {
                            self.seat.focusWindow(next_window);
                        }
                    }
                } else {
                    self.seat.focusTopWindow();
                }
            },
            .SwitchWorkspace => |idx| {
                if (self.outputAtCursor()) |output| {
                    output.sceneSwitchWorkspace(idx - 1);
                }
            },
            .MoveWindowToWorkspace => |idx| {
                if (self.seat.focused_window) |window| {
                    if (self.outputAtCursor()) |output| {
                        output.sceneMoveWindowToWorkspace(window, idx - 1);
                        window.setFocus(false);
                        self.seat.clearFocusIfFocusedWindow(window);
                    }
                }
            },
            .Command => |command| {
                owm.process.spawnProcess(command);
            },
            .ToggleMaximize => {
                if (self.seat.focused_window) |window| {
                    window.toggleMaximize();
                }
            },
        }
        return true;
    }
    return false;
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
