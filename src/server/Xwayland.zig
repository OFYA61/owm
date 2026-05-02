const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const log = owm.log;

wlr_xwayland: *wlr.Xwayland,
new_surface_listener: wl.Listener(*wlr.XwaylandSurface) = .init(newSurfaceCallback),

pub fn create(wl_server: *wl.Server, wlr_compositor: *wlr.Compositor) !Self {
    const wlr_xwayland = try wlr.Xwayland.create(wl_server, wlr_compositor, true);
    return .{
        .wlr_xwayland = wlr_xwayland,
    };
}

pub fn init(self: *Self) void {
    self.wlr_xwayland.events.new_surface.add(&self.new_surface_listener);
    owm.env.putVar("DISPLAY", std.mem.span(self.wlr_xwayland.display_name));
}

pub fn deinit(self: *Self) void {
    self.new_surface_listener.link.remove();
    self.wlr_xwayland.destroy();
}

fn newSurfaceCallback(listener: *wl.Listener(*wlr.XwaylandSurface), wlr_xwayland_surface: *wlr.XwaylandSurface) void {
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
