const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const log = owm.log;

wlr_layer_shell_v1: *wlr.LayerShellV1,
new_surface_listener: wl.Listener(*wlr.LayerSurfaceV1) = .init(newSurfaceCallback),

pub fn create(wl_server: *wl.Server) !Self {
    const wlr_layer_shell_v1 = try wlr.LayerShellV1.create(wl_server, 5);
    return .{
        .wlr_layer_shell_v1 = wlr_layer_shell_v1,
    };
}

pub fn init(self: *Self) void {
    self.wlr_layer_shell_v1.events.new_surface.add(&self.new_surface_listener);
}

pub fn deinit(self: *Self) void {
    self.new_surface_listener.link.remove();
}

fn newSurfaceCallback(_: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
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
