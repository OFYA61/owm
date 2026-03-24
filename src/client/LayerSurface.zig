const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;

wlr_layer_surface: *wlr.LayerSurfaceV1,
current_output: *owm.Output,

map_listener: wl.Listener(void) = .init(mapCallback),
unmap_listener: wl.Listener(void) = .init(unmapCallback),
commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newPopupCallback),
destroy_listener: wl.Listener(*wlr.LayerSurfaceV1) = .init(destroyCallback),

pub fn create(wlr_layer_surface: *wlr.LayerSurfaceV1) client.Error!Self {
    return .{
        .wlr_layer_surface = wlr_layer_surface,
        .current_output = owm.Output.fromOpaquePtr(wlr_layer_surface.output.?.data) orelse return client.Error.FailedToDetermineOutout,
    };
}

pub fn setup(self: *Self) void {
    self.wlr_layer_surface.surface.events.map.add(&self.map_listener);
    self.wlr_layer_surface.surface.events.unmap.add(&self.unmap_listener);
    self.wlr_layer_surface.surface.events.commit.add(&self.commit_listener);
    self.wlr_layer_surface.events.new_popup.add(&self.new_popup_listener);
    self.wlr_layer_surface.events.destroy.add(&self.destroy_listener);
}

pub fn getGeom(self: *Self) wlr.Box {
    return .{
        .x = 0,
        .y = 0,
        .width = self.wlr_layer_surface.current.actual_width,
        .height = self.wlr_layer_surface.current.actual_height,
    };
}

fn mapCallback(_: *wl.Listener(void)) void {
    // const layer_surface: *Self = @fieldParentPtr("map_listener", listener);
}

fn unmapCallback(_: *wl.Listener(void)) void {
    // const layer_surface: *Self = @fieldParentPtr("unmap_listener", listener);
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), wlr_surface: *wlr.Surface) void {
    const layer_surface: *Self = @fieldParentPtr("commit_listener", listener);
    var layer_surface_client = client.Client.from(layer_surface);
    _ = wlr_surface;
    const wlr_layer_surface = layer_surface.wlr_layer_surface;
    if (wlr_layer_surface.initial_commit) {
        const work_area = layer_surface.current_output.work_area;
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
            layer_surface_client.setPos(work_area.x, work_area.y);
        } else if (!anchors.top and anchors.right and anchors.bottom and anchors.left) {
            zone_type = .Bottom;
            layer_surface_client.setPos(work_area.x, work_area.y + work_area.height - exclusive_zone_size_c_int);
        } else if (anchors.top and anchors.right and anchors.bottom and !anchors.left) {
            zone_type = .Right;
            layer_surface_client.setPos(work_area.x + work_area.width - exclusive_zone_size_c_int, work_area.y);
        } else if (anchors.top and !anchors.right and anchors.bottom and anchors.left) {
            zone_type = .Left;
            layer_surface_client.setPos(work_area.x, work_area.y);
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
            .owning_client = layer_surface_client,
        };
        layer_surface.current_output.addExclusiveZone(exclusive_zone) catch |err| {
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
    const layer_surface: *Self = @fieldParentPtr("new_popup_listener", listener);
    _ = client.Client.newPopup(wlr_xdg_popup, client.Client.from(layer_surface)) catch |err| {
        owm.log.errf("Failed to create XDG Popup for toplevel {}", .{err});
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

    const layer_surface_client = client.Client.from(layer_surface);

    layer_surface.current_output.removeExclusiveZoneByOwner(layer_surface_client);

    owm.c_alloc.destroy(layer_surface_client);
}
