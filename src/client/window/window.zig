pub const XdgToplevel = @import("XdgToplevel.zig");
pub const Xwayland = @import("Xwayland.zig");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;
const log = owm.log;

pub const Window = struct {
    const Self = @This();

    pub const WindowType = union(enum) {
        xdg_toplevel: XdgToplevel,
        xwayland: Xwayland,
    };

    wlr_scene_tree: *wlr.SceneTree,
    x: i32 = 0,
    y: i32 = 0,
    link: wl.list.Link = undefined,
    window: WindowType,

    pub fn newToplevel(wlr_xdg_toplevel: *wlr.XdgToplevel) client.Error!*Self {
        var window = try owm.c_alloc.create(Self);
        errdefer owm.c_alloc.destroy(window);

        const scene_tree = owm.server.scene_tree_apps.createSceneXdgSurface(wlr_xdg_toplevel.base) catch {
            log.err("Failed to create scene tree for Toplevel");
            return client.Error.FailedToCreateSceneTree;
        };
        errdefer scene_tree.node.link.remove();
        scene_tree.node.data = window;

        window.* = .{
            .wlr_scene_tree = scene_tree,
            .window = .{
                .xdg_toplevel = try XdgToplevel.create(wlr_xdg_toplevel),
            },
        };
        window.setup();
        return window;
    }

    pub fn newXwayland(wlr_xwayland_surface: *wlr.XwaylandSurface) client.Error!*Self {
        var window = try owm.c_alloc.create(Self);
        errdefer owm.c_alloc.destroy(window);

        const scene_tree = owm.server.scene_tree_apps.createSceneSubsurfaceTree(wlr_xwayland_surface.surface.?) catch {
            log.err("Failed to create scene tree for Toplevel");
            return client.Error.FailedToCreateSceneTree;
        };
        errdefer scene_tree.node.link.remove();
        scene_tree.node.data = window;

        window.* = .{
            .wlr_scene_tree = scene_tree,
            .window = .{
                .xwayland = try Xwayland.create(wlr_xwayland_surface),
            },
        };

        window.setup();
        return window;
    }

    fn setup(self: *Self) void {
        switch (self.window) {
            .xdg_toplevel => |*t| {
                t.setup();
            },
            .xwayland => |*xw| {
                xw.setup();
            },
        }
    }

    pub fn from(ptr: anytype) *Self {
        const PtrType = @TypeOf(ptr);
        const info = @typeInfo(PtrType);
        if (info != .pointer) {
            @compileError("Expected a pointer, found " ++ @TypeOf(PtrType));
        }

        const client_type_ptr: *WindowType = @ptrCast(ptr);
        return @fieldParentPtr("window", client_type_ptr);
    }

    pub fn fromOpaquePtr(ptr: ?*anyopaque) ?*Self {
        return @as(?*Self, @ptrCast(@alignCast(ptr)));
    }

    pub fn getWlrSurface(self: *Self) *wlr.Surface {
        switch (self.window) {
            .xdg_toplevel => |*t| {
                return t.getWlrSurface();
            },
            .xwayland => |*xw| {
                return xw.wlr_xwayland_surface.surface.?;
            },
        }
    }

    pub fn getGeom(self: *Self) wlr.Box {
        switch (self.window) {
            .xdg_toplevel => |*t| {
                return t.getGeom();
            },
            .xwayland => |*xw| {
                return .{
                    .x = self.x,
                    .y = self.y,
                    .width = @as(i32, @intCast(xw.wlr_xwayland_surface.width)),
                    .height = @as(i32, @intCast(xw.wlr_xwayland_surface.height)),
                };
            },
        }
    }

    pub fn setFocus(self: *Self, focus: bool) void {
        switch (self.window) {
            .xdg_toplevel => |*t| {
                t.setFocus(focus);
            },
            .xwayland => |*xw| {
                xw.setFocus(focus);
            },
        }
    }

    pub fn toggleMaximize(self: *Self) void {
        switch (self.window) {
            .xdg_toplevel => |*t| {
                t.toggleMaximize();
            },
            .xwayland => |*xw| {
                xw.toggleMaximize();
            },
        }
    }

    pub fn setPos(self: *Self, new_x: i32, new_y: i32) void {
        self.x = new_x;
        self.y = new_y;
        self.wlr_scene_tree.node.setPosition(new_x, new_y);
    }

    pub fn setSize(self: *Self, new_width: i32, new_height: i32) void {
        switch (self.window) {
            .xdg_toplevel => |*t| {
                t.setSize(new_width, new_height);
            },
            .xwayland => |*xw| {
                xw.setSize(
                    @as(u16, @intCast(new_width)),
                    @as(u16, @intCast(new_height)),
                );
            },
        }
    }

    pub fn setCurrentOutput(self: *Self, output: *owm.Output) void {
        switch (self.window) {
            .xdg_toplevel => |*t| {
                t.current_output = output;
            },
            .xwayland => |*xw| {
                xw.current_output = output;
            },
        }
    }
};
