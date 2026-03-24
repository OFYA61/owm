const Client = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;

pub const Error = error{
    CursorNotOnOutput,
    FailedToCreateSceneTree,
    FailedToDetermineOutout,
    OutOfMemory,
    ParentSceneTreeNotFound,
    SceneTreeNotFound,
};

pub const ClientType = union(enum) {
    LayerSurface: owm.client.LayerSurface,
    Popup: owm.client.Popup,
    Toplevel: owm.client.Toplevel,
    XWayland: owm.client.XWayland,
};

wlr_scene_tree: *wlr.SceneTree,
x: i32 = 0,
y: i32 = 0,
link: wl.list.Link = undefined,
client: ClientType,

pub fn newLayerSurface(wlr_layer_surface: *wlr.LayerSurfaceV1) Error!*Client {
    var client = try owm.c_alloc.create(Client);
    errdefer owm.c_alloc.destroy(client);

    const scene_layer_surface = owm.server.scene_tree_foreground.createSceneLayerSurfaceV1(wlr_layer_surface) catch {
        owm.log.err("Failed to create scene tree for LayerSurface");
        return Error.FailedToCreateSceneTree;
    };
    errdefer scene_layer_surface.tree.node.link.remove();
    const scene_tree = scene_layer_surface.tree;
    scene_tree.node.data = client;

    client.* = .{
        .wlr_scene_tree = scene_tree,
        .client = .{
            .LayerSurface = try owm.client.LayerSurface.create(wlr_layer_surface),
        },
    };

    client.setup();
    return client;
}

pub fn newPopup(wlr_xdg_popup: *wlr.XdgPopup, parent: *Client) Error!*Client {
    var client = try owm.c_alloc.create(Client);
    errdefer owm.c_alloc.destroy(client);

    const parent_scene_tree = parent.wlr_scene_tree;

    const xdg_surface = wlr_xdg_popup.base;
    const scene_tree = parent_scene_tree.createSceneXdgSurface(xdg_surface) catch {
        owm.log.err("Failed to create scene tree for Popup");
        return Error.FailedToCreateSceneTree;
    };
    errdefer scene_tree.node.link.remove();
    scene_tree.node.data = client;

    client.* = .{
        .wlr_scene_tree = scene_tree,
        .client = .{
            .Popup = try owm.client.Popup.create(wlr_xdg_popup, parent),
        },
    };
    client.setup();
    return client;
}

pub fn newToplevel(wlr_xdg_toplevel: *wlr.XdgToplevel) Error!*Client {
    var client = try owm.c_alloc.create(Client);
    errdefer owm.c_alloc.destroy(client);

    const scene_tree = owm.server.scene_tree_apps.createSceneXdgSurface(wlr_xdg_toplevel.base) catch {
        owm.log.err("Failed to create scene tree for Toplevel");
        return Error.FailedToCreateSceneTree;
    };
    errdefer scene_tree.node.link.remove();
    scene_tree.node.data = client;

    client.* = .{
        .wlr_scene_tree = scene_tree,
        .client = .{
            .Toplevel = try owm.client.Toplevel.create(wlr_xdg_toplevel),
        },
    };
    client.setup();
    return client;
}

pub fn newXWayland(wlr_xwayland_surface: *wlr.XwaylandSurface) Error!*Client {
    var client = try owm.c_alloc.create(Client);
    errdefer owm.c_alloc.destroy(client);

    client.client = .{
        .XWayland = try owm.client.XWayland.create(wlr_xwayland_surface),
    };

    client.setup();
    return client;
}

fn setup(self: *Client) void {
    switch (self.client) {
        .LayerSurface => |*ls| {
            ls.setup();
        },
        .Popup => |*p| {
            p.setup();
        },
        .Toplevel => |*t| {
            t.setup();
            const work_area = t.current_output.area;
            const spawn_x = work_area.x + @divExact(work_area.width, 2) - @divExact(owm.client.Toplevel.SPAWN_SIZE_X, 2);
            const spawn_y = work_area.y + @divExact(work_area.height, 2) - @divExact(owm.client.Toplevel.SPAWN_SIZE_Y, 2);
            self.wlr_scene_tree.node.setPosition(spawn_x, spawn_y);
            self.x = spawn_x;
            self.y = spawn_y;
        },
        .XWayland => |*xw| {
            xw.setup();
        },
    }
}

pub fn from(ptr: anytype) *Client {
    const PtrType = @TypeOf(ptr);
    const info = @typeInfo(PtrType);
    if (info != .pointer) {
        @compileError("Expected a pointer, found " ++ @TypeOf(PtrType));
    }

    const client_type_ptr: *ClientType = @ptrCast(ptr);
    return @fieldParentPtr("client", client_type_ptr);
}

pub fn fromOpaquePtr(ptr: ?*anyopaque) ?*Client {
    return @as(?*Client, @ptrCast(@alignCast(ptr)));
}

// TODO: consider returning a nullable pointer and handle at the callsite
pub fn getWlrSurface(self: *Client) *wlr.Surface {
    switch (self.client) {
        .LayerSurface => |*ls| {
            return ls.wlr_layer_surface.surface;
        },
        .Popup => |*p| {
            return p.wlr_xdg_popup.base.surface;
        },
        .Toplevel => |*t| {
            return t.getWlrSurface();
        },
        .XWayland => |*xw| {
            return xw.wlr_xwayland_surface.surface.?;
        },
    }
}

pub fn getGeom(self: *Client) wlr.Box {
    switch (self.client) {
        .LayerSurface => |*ls| {
            return .{
                .x = self.x,
                .y = self.y,
                .width = @as(i32, @intCast(ls.wlr_layer_surface.current.actual_width)),
                .height = @as(i32, @intCast(ls.wlr_layer_surface.current.actual_height)),
            };
        },
        .Popup => |*p| {
            return p.getGeom();
        },
        .Toplevel => |*t| {
            return t.getGeom();
        },
        .XWayland => |*xw| {
            return .{
                .x = self.x,
                .y = self.y,
                .width = @as(i32, @intCast(xw.wlr_xwayland_surface.width)),
                .height = @as(i32, @intCast(xw.wlr_xwayland_surface.height)),
            };
        },
    }
}

pub fn getUnconstrainBox(self: *Client) wlr.Box {
    var unconstrainBox: wlr.Box = undefined;
    switch (self.client) {
        .Toplevel => |*t| {
            unconstrainBox = t.current_output.area;
            unconstrainBox.x -= self.x;
            unconstrainBox.y -= self.y;
        },
        .LayerSurface => |ls| {
            unconstrainBox = ls.current_output.area;
            unconstrainBox.x -= self.x;
            unconstrainBox.y -= self.y;
        },
        .Popup => |*p| {
            unconstrainBox = p.parent.getUnconstrainBox();
        },
        .XWayland => |*xw| {
            unconstrainBox = xw.current_output.area;
            unconstrainBox.x -= self.x;
            unconstrainBox.y -= self.y;
        },
    }

    return unconstrainBox;
}

pub fn isFocusable(self: *Client) bool {
    switch (self.client) {
        .Toplevel => |_| return true,
        else => return false,
    }
}

pub fn setFocus(self: *Client, focus: bool) void {
    switch (self.client) {
        .Toplevel => |*t| {
            t.setFocus(focus);
        },
        else => {
            unreachable;
        },
    }
}

pub fn toggleMaximize(self: *Client) void {
    switch (self.client) {
        .Toplevel => |*t| {
            t.toggleMaximize();
        },
        else => {
            unreachable;
        },
    }
}

pub fn setPos(self: *Client, new_x: i32, new_y: i32) void {
    self.x = new_x;
    self.y = new_y;
    self.wlr_scene_tree.node.setPosition(new_x, new_y);
}

pub fn setSize(self: *Client, new_width: i32, new_height: i32) void {
    switch (self.client) {
        .Toplevel => |*t| {
            t.setSize(new_width, new_height);
        },
        else => {
            unreachable;
        },
    }
}

pub fn setCurrentOutput(self: *Client, output: *owm.Output) void {
    switch (self.client) {
        .Toplevel => |*t| {
            t.current_output = output;
        },
        else => {
            unreachable;
        },
    }
}
