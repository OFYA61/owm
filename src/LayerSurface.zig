//! Reprezents surfaces requested via the `wlr-layer-shell-v1` protocol
pub const LayerSurface = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

wlr_layer_surface: *wlr.LayerSurfaceV1,
output: *owm.Output,
wlr_scene_layer_surface: *wlr.SceneLayerSurfaceV1,
link: wl.list.Link = undefined,
managed_window: owm.ManagedWindow,

map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newPopupCallback),
destroy_listener: wl.Listener(*wlr.LayerSurfaceV1) = .init(destroyCallback),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) !*LayerSurface {
    const layer_surface = try owm.c_alloc.create(LayerSurface);
    errdefer owm.c_alloc.destroy(layer_surface);

    const wlr_scene_layer_surface = try owm.server.scene_tree_foreground.createSceneLayerSurfaceV1(wlr_layer_surface);

    layer_surface.* = .{
        .output = owm.server.outputs.first().?,
        .wlr_layer_surface = wlr_layer_surface,
        .wlr_scene_layer_surface = wlr_scene_layer_surface,
        .managed_window = owm.ManagedWindow.layerSurface(layer_surface),
    };

    layer_surface.wlr_scene_layer_surface.tree.node.data = &layer_surface.managed_window;

    wlr_layer_surface.surface.events.map.add(&layer_surface.map_listener);
    wlr_layer_surface.surface.events.unmap.add(&layer_surface.unmap_listener);
    wlr_layer_surface.surface.events.commit.add(&layer_surface.commit_listener);
    wlr_layer_surface.events.new_popup.add(&layer_surface.new_popup_listener);
    wlr_layer_surface.events.destroy.add(&layer_surface.destroy_listener);

    return layer_surface;
}

fn mapCallback(_: *wl.Listener(void)) void {
    // const layer_surface: *LayerSurface = @fieldParentPtr("map_listener", listener);
}

fn unmapCallback(_: *wl.Listener(void)) void {
    // const layer_surface: *LayerSurface = @fieldParentPtr("unmap_listener", listener);
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), wlr_surface: *wlr.Surface) void {
    const layer_surface: *LayerSurface = @fieldParentPtr("commit_listener", listener);
    _ = wlr_surface;
    const wlr_layer_surface = layer_surface.wlr_layer_surface;
    if (wlr_layer_surface.initial_commit) {
        const work_area = layer_surface.output.work_area;
        const anchors = wlr_layer_surface.pending.anchor;

        const zone_size = wlr_layer_surface.pending.exclusive_zone;
        if (zone_size <= 0) {
            owm.log.errf("Got unsupported exclusive zone size {}", .{zone_size});
            return;
        }
        const exclusive_zone_size: u32 = @intCast(zone_size);
        const exclusive_zone_size_c_int: c_int = @intCast(zone_size);
        var zone_type: owm.Output.ExclusiveZone.Type = undefined;
        if (anchors.top and anchors.right and !anchors.bottom and anchors.left) {
            zone_type = .Top;
            layer_surface.wlr_scene_layer_surface.tree.node.setPosition(work_area.x, work_area.y);
        } else if (!anchors.top and anchors.right and anchors.bottom and anchors.left) {
            zone_type = .Bottom;
            layer_surface.wlr_scene_layer_surface.tree.node.setPosition(work_area.x, work_area.y + work_area.height - exclusive_zone_size_c_int);
        } else if (anchors.top and anchors.right and anchors.bottom and !anchors.left) {
            zone_type = .Right;
            layer_surface.wlr_scene_layer_surface.tree.node.setPosition(work_area.x + work_area.width - exclusive_zone_size_c_int, work_area.y);
        } else if (anchors.top and !anchors.right and anchors.bottom and anchors.left) {
            zone_type = .Left;
            layer_surface.wlr_scene_layer_surface.tree.node.setPosition(work_area.x, work_area.y);
        } else {
            owm.log.errf("Got unsupported anchors=({}, {}, {}, {})", .{
                anchors.top,
                anchors.right,
                anchors.bottom,
                anchors.left,
            });
            wlr_layer_surface.destroy();
            return;
        }

        const exclusive_zone = owm.Output.ExclusiveZone{
            .type = zone_type,
            .size = exclusive_zone_size,
            .owner = layer_surface,
        };
        layer_surface.output.addExclusiveZone(exclusive_zone) catch |err| {
            owm.log.errf("Failed to add exclusive zone to output {}", .{err});
            return;
        };

        if (zone_type == .Top or zone_type == .Bottom) {
            _ = wlr_layer_surface.configure(@intCast(work_area.width), exclusive_zone_size);
        } else {
            _ = wlr_layer_surface.configure(exclusive_zone_size, @intCast(work_area.height));
        }
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

    layer_surface.output.removeExclusiveZoneByOwner(layer_surface);

    owm.c_alloc.destroy(layer_surface);
}
