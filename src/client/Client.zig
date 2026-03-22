const Client = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const Toplevel = owm.client.Toplevel;

pub const Error = error{
    CursorNotOnOutput,
    FailedToCreateSceneTree,
    OutOfMemory,
    ParentSceneTreeNotFound,
    SceneTreeNotFound,
};

pub const ClientType = union(enum) {
    Popup: owm.client.Popup,
    Toplevel: owm.client.Toplevel,
};

wlr_scene_tree: ?*wlr.SceneTree,
x: i32 = 0,
y: i32 = 0,
link: wl.list.Link = undefined,
client: ClientType,

pub fn newPopup(wlr_xdg_popup: *wlr.XdgPopup, parent: *Client) Error!*Client {
    var client = try owm.c_alloc.create(Client);
    errdefer owm.c_alloc.destroy(client);

    const parent_scene_tree = parent.wlr_scene_tree orelse return error.ParentSceneTreeNotFound;

    const xdg_surface = wlr_xdg_popup.base;
    const scene_tree = parent_scene_tree.createSceneXdgSurface(xdg_surface) catch {
        owm.log.err("Failed to create scene tree for popup");
        return error.FailedToCreateSceneTree;
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
        return error.FailedToCreateSceneTree;
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

fn setup(self: *Client) void {
    switch (self.client) {
        .Popup => |*p| {
            p.setup();
        },
        .Toplevel => |*t| {
            t.setup();
            const work_area = t.current_output.area;
            const spawn_x = work_area.x + @divExact(work_area.width, 2) - @divExact(Toplevel.SPAWN_SIZE_X, 2);
            const spawn_y = work_area.y + @divExact(work_area.height, 2) - @divExact(Toplevel.SPAWN_SIZE_Y, 2);
            self.wlr_scene_tree.?.node.setPosition(spawn_x, spawn_y);
            self.x = spawn_x;
            self.y = spawn_y;
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

pub fn getWlrSurface(self: *Client) *wlr.Surface {
    switch (self.client) {
        .Popup => |*p| {
            return p.wlr_xdg_popup.base.surface;
        },
        .Toplevel => |*t| {
            return t.getWlrSurface();
        },
    }
}

pub fn getGeom(self: *Client) wlr.Box {
    switch (self.client) {
        .Popup => |*p| {
            return p.getGeom();
        },
        .Toplevel => |*t| {
            return t.getGeom();
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
        // .LayerSurface => |ls| {
        //     unconstrainBox = ls.output.area;
        //     unconstrainBox.x -= ls.x;
        //     unconstrainBox.y -= ls.y;
        // },
        .Popup => |*p| {
            unconstrainBox = p.parent.getUnconstrainBox();
        },
        // .XWaylandWindow => |xww| {
        //     unconstrainBox = xww.current_output.area;
        //     unconstrainBox.x -= xww.x;
        //     unconstrainBox.y -= xww.y;
        // },
    }

    return unconstrainBox;
}

pub fn isFocusable(self: *Client) bool {
    switch (self.client) {
        .Popup => |_| return false,
        else => return true,
    }
}

pub fn setFocus(self: *Client, focus: bool) void {
    switch (self.client) {
        .Popup => |_| {
            unreachable;
        },
        .Toplevel => |*t| {
            t.setFocus(focus);
        },
    }
}

pub fn toggleMaximize(self: *Client) void {
    switch (self.client) {
        .Popup => |_| {
            unreachable;
        },
        .Toplevel => |*t| {
            t.toggleMaximize();
        },
    }
}

pub fn setPos(self: *Client, new_x: i32, new_y: i32) void {
    switch (self.client) {
        .Popup => |_| {
            unreachable;
        },
        .Toplevel => |*t| {
            t.setPos(new_x, new_y);
        },
    }
}

pub fn setSize(self: *Client, new_width: i32, new_height: i32) void {
    switch (self.client) {
        .Popup => |_| {
            unreachable;
        },
        .Toplevel => |*t| {
            t.setSize(new_width, new_height);
        },
    }
}

pub fn setCurrentOutput(self: *Client, output: *owm.Output) void {
    switch (self.client) {
        .Popup => |*p| {
            _ = p;
        },
        .Toplevel => |*t| {
            t.current_output = output;
        },
    }
}
