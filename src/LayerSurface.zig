pub const LayerSurface = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

wlr_layer_surface: *wlr.LayerSurfaceV1,
link: wl.list.Link = undefined,

map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newPopupCallback),
destroy_listener: wl.Listener(*wlr.LayerSurfaceV1) = .init(destroyCallback),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) !*LayerSurface {
    const layer_shell = try owm.c_alloc.create(LayerSurface);
    errdefer owm.c_alloc.destroy(layer_shell);

    layer_shell.* = .{
        .wlr_layer_surface = wlr_layer_surface,
    };

    wlr_layer_surface.surface.events.map.add(&layer_shell.map_listener);
    wlr_layer_surface.surface.events.unmap.add(&layer_shell.unmap_listener);
    wlr_layer_surface.surface.events.commit.add(&layer_shell.commit_listener);
    wlr_layer_surface.events.new_popup.add(&layer_shell.new_popup_listener);
    wlr_layer_surface.events.destroy.add(&layer_shell.destroy_listener);

    return layer_shell;
}

fn mapCallback(_: *wl.Listener(void)) void {
    // const layer_shell: *LayerSurface = @fieldParentPtr("map_listener", listener);
    // _ = layer_shell;
}

fn unmapCallback(_: *wl.Listener(void)) void {
    // const layer_shell: *LayerSurface = @fieldParentPtr("unmap_listener", listener);
    // _ = layer_shell;
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), wlr_surface: *wlr.Surface) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("commit_listener", listener);
    _ = wlr_surface;
    const wlr_layer_surface = layer_surface.wlr_layer_surface;
    if (wlr_layer_surface.initial_commit) {
        _ = wlr_layer_surface.configure(1000, 40);
    }
}

fn newPopupCallback(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("new_popup_listener", listener);
    _ = layer_surface;
    owm.Popup.create(wlr_xdg_popup) catch {
        owm.log.err("Failed to create XDG Popup for layer shell");
    };
}

fn destroyCallback(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("destroy_listener", listener);
    layer_surface.link.remove();

    layer_surface.map_listener.link.remove();
    layer_surface.unmap_listener.link.remove();
    layer_surface.commit_listener.link.remove();
    layer_surface.new_popup_listener.link.remove();
    layer_surface.destroy_listener.link.remove();

    owm.c_alloc.destroy(layer_surface);
}
