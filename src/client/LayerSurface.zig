const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;
const log = owm.log;

wlr_layer_surface: *wlr.LayerSurfaceV1,
wlr_scene_layer_surface: *wlr.SceneLayerSurfaceV1,
current_output: *owm.server.Output,
x: c_int,
y: c_int,

map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newPopupCallback),
destroy_listener: wl.Listener(*wlr.LayerSurfaceV1) = .init(destroyCallback),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) client.Error!*Self {
    var self = try owm.c_alloc.create(Self);
    errdefer owm.c_alloc.destroy(self);

    const scene_tree = owm.SERVER.scene.getLayerSurfaceTree(wlr_layer_surface.current.layer).createSceneLayerSurfaceV1(wlr_layer_surface) catch {
        log.err("Failed to create scene tree for LayerSurface");
        return client.Error.FailedToCreateSceneTree;
    };

    self.* = .{
        .wlr_layer_surface = wlr_layer_surface,
        .wlr_scene_layer_surface = scene_tree,
        .current_output = owm.server.Output.fromOpaquePtr(wlr_layer_surface.output.?.data) orelse return client.Error.FailedToDetermineOutout,
        .x = scene_tree.tree.node.x,
        .y = scene_tree.tree.node.y,
    };

    self.wlr_layer_surface.surface.events.map.add(&self.map_listener);
    self.wlr_layer_surface.surface.events.unmap.add(&self.unmap_listener);
    self.wlr_layer_surface.surface.events.commit.add(&self.commit_listener);
    self.wlr_layer_surface.events.new_popup.add(&self.new_popup_listener);
    self.wlr_layer_surface.events.destroy.add(&self.destroy_listener);

    return self;
}

pub fn getGeom(self: *Self) wlr.Box {
    return .{
        .x = 0,
        .y = 0,
        .width = self.wlr_layer_surface.current.actual_width,
        .height = self.wlr_layer_surface.current.actual_height,
    };
}

pub fn setPos(self: *Self, new_x: c_int, new_y: c_int) void {
    self.wlr_scene_layer_surface.tree.node.setPosition(new_x, new_y);
}

fn mapCallback(_: *wl.Listener(void)) void {
    // const layer_surface: *Self = @fieldParentPtr("map_listener", listener);
}

fn unmapCallback(_: *wl.Listener(void)) void {
    // const layer_surface: *Self = @fieldParentPtr("unmap_listener", listener);
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), wlr_surface: *wlr.Surface) void {
    const layer_surface: *Self = @fieldParentPtr("commit_listener", listener);
    _ = wlr_surface;
    const wlr_layer_surface = layer_surface.wlr_layer_surface;
    if (wlr_layer_surface.initial_commit) {
        const work_area = layer_surface.current_output.work_area;
        const anchors = wlr_layer_surface.pending.anchor;

        const zone_size = wlr_layer_surface.pending.exclusive_zone;
        if (zone_size <= 0) {
            log.errf("Got unsupported exclusive zone size {}", .{zone_size});
            return;
        }
        const exclusive_zone_size: u32 = @intCast(zone_size);
        const exclusive_zone_size_c_int: c_int = @intCast(zone_size);
        var zone_type: owm.server.Output.ExclusiveZone.Type = undefined;
        if (anchors.top and anchors.right and !anchors.bottom and anchors.left) {
            zone_type = .Top;
            layer_surface.setPos(work_area.x, work_area.y);
        } else if (!anchors.top and anchors.right and anchors.bottom and anchors.left) {
            zone_type = .Bottom;
            layer_surface.setPos(work_area.x, work_area.y + work_area.height - exclusive_zone_size_c_int);
        } else if (anchors.top and anchors.right and anchors.bottom and !anchors.left) {
            zone_type = .Right;
            layer_surface.setPos(work_area.x + work_area.width - exclusive_zone_size_c_int, work_area.y);
        } else if (anchors.top and !anchors.right and anchors.bottom and anchors.left) {
            zone_type = .Left;
            layer_surface.setPos(work_area.x, work_area.y);
        } else {
            log.errf("Got unsupported anchors=({}, {}, {}, {})", .{
                anchors.top,
                anchors.right,
                anchors.bottom,
                anchors.left,
            });
            wlr_layer_surface.destroy();
            return;
        }

        const exclusive_zone = owm.server.Output.ExclusiveZone{
            .type = zone_type,
            .size = exclusive_zone_size,
            .owner = layer_surface,
        };
        layer_surface.current_output.addExclusiveZone(exclusive_zone) catch |err| {
            log.errf("Failed to add exclusive zone to output {}", .{err});
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
    const layer_surface: *Self = @fieldParentPtr("new_popup_listener", listener);
    _ = client.Popup.create(wlr_xdg_popup, layer_surface.wlr_scene_layer_surface.tree, layer_surface.wlr_scene_layer_surface.tree, layer_surface.current_output) catch |err| {
        log.errf("Failed to create XDG Popup for toplevel {}", .{err});
        return;
    };
}

fn destroyCallback(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const layer_surface: *Self = @fieldParentPtr("destroy_listener", listener);

    layer_surface.map_listener.link.remove();
    layer_surface.unmap_listener.link.remove();
    layer_surface.commit_listener.link.remove();
    layer_surface.new_popup_listener.link.remove();
    layer_surface.destroy_listener.link.remove();

    layer_surface.current_output.removeExclusiveZoneByOwner(layer_surface);

    owm.c_alloc.destroy(layer_surface);
}
