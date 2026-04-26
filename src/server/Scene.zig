//! Reprezents the root of the scene. Contains methods to grab the surfaces located at certain points and handles orphaned windows.

const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const log = owm.log;

const Output = @import("Output.zig");
const Window = owm.client.window.Window;

pub const WindowAtResponse = struct {
    sx: f64,
    sy: f64,
    wlr_surface: *wlr.Surface,
    window: *Window,
};

pub const SurfaceAtResponse = struct {
    sx: f64,
    sy: f64,
    wlr_surface: *wlr.Surface,
};

const OrphanWindow = struct {
    workspace_idx: usize,
    window: *Window,
};

wlr_scene: *wlr.Scene,
wlr_scene_output_layout: *wlr.SceneOutputLayout,

root: *wlr.SceneTree,

orphaned_windows: std.ArrayList(OrphanWindow) = .empty,

pub fn create(wlr_output_layout: *wlr.OutputLayout) !Self {
    const wlr_scene = try wlr.Scene.create();
    const wlr_scene_output_layout = try wlr_scene.attachOutputLayout(wlr_output_layout);
    const root = try wlr_scene.tree.createSceneTree();
    return Self{
        .wlr_scene = wlr_scene,
        .wlr_scene_output_layout = wlr_scene_output_layout,
        .root = root,
    };
}

pub fn deinit(self: *Self) void {
    log.debug("Scene: Cleaning up");
    self.orphaned_windows.deinit(owm.alloc);
}

pub fn windowAt(self: *Self, lx: f64, ly: f64) ?WindowAtResponse {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (self.root.node.at(lx, ly, &sx, &sy)) |node| {
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

        var it: ?*wlr.SceneTree = node.parent;
        while (it) |n| : (it = n.node.parent) {
            if (Window.fromOpaquePtr(n.node.data)) |window| {
                return WindowAtResponse{
                    .sx = sx,
                    .sy = sy,
                    .wlr_surface = scene_surface.surface,
                    .window = window,
                };
            }
        }
    }

    return null;
}

pub fn surfaceAt(self: *Self, lx: f64, ly: f64) ?SurfaceAtResponse {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (self.wlr_scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;
        return SurfaceAtResponse{
            .sx = sx,
            .sy = sy,
            .wlr_surface = scene_surface.surface,
        };
    }

    return null;
}

pub fn storeOrphanWindow(self: *Self, window: *Window, workspace_idx: usize) void {
    self.orphaned_windows.append(
        owm.alloc,
        OrphanWindow{
            .window = window,
            .workspace_idx = workspace_idx,
        },
    ) catch unreachable;
}

/// Must be called after arranging a set of outputs. In case we've had an output removed,
/// we'll have a list of orphaned windows. These should get moved into the view of another output.
/// We move them to the first available outputs viewport.
pub fn handleOrphanedWindows(self: *Self) void {
    // TODO: move orphaned windows to the first available outputs workspaces
    self.orphaned_windows.clearAndFree(owm.alloc);
}
