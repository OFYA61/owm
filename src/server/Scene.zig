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

wlr_scene: *wlr.Scene,
wlr_scene_output_layout: *wlr.SceneOutputLayout,

root: *wlr.SceneTree,
orphaned_windows: struct {
    root: *wlr.SceneTree,
    windows: wl.list.Head(Window, .link) = undefined,
    workspace_idxs: std.ArrayList(usize) = .empty,

    fn getCount(self: *@This()) usize {
        return self.workspace_idxs.items.len;
    }

    fn clear(self: *@This()) void {
        var orphan_window_iter = self.windows.iterator(.forward);
        while (orphan_window_iter.next()) |window| {
            window.link.remove();
        }
        self.workspace_idxs.clearAndFree(owm.alloc);
    }

    fn getMaxWorkspaceIdx(self: *@This()) usize {
        var max: usize = 0;
        for (self.workspace_idxs.items) |idx| {
            if (idx > max) {
                max = idx;
            }
        }
        return max;
    }
},

pub fn create(wlr_output_layout: *wlr.OutputLayout) !Self {
    const wlr_scene = try wlr.Scene.create();
    const wlr_scene_output_layout = try wlr_scene.attachOutputLayout(wlr_output_layout);
    const root = try wlr_scene.tree.createSceneTree();
    return Self{
        .wlr_scene = wlr_scene,
        .wlr_scene_output_layout = wlr_scene_output_layout,
        .root = root,
        .orphaned_windows = .{
            .root = try root.createSceneTree(),
        },
    };
}

pub fn init(self: *Self) void {
    self.orphaned_windows.root.node.setEnabled(false);
    self.orphaned_windows.windows.init();
}

pub fn deinit(self: *Self) void {
    log.debug("Scene: Cleaning up");
    self.orphaned_windows.root.node.destroy();
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
    log.debugf("Scene: Orphaning window {*}", .{window});
    window.link.remove();
    window.setSceneTreeParent(self.orphaned_windows.root);
    self.orphaned_windows.windows.append(window);
    self.orphaned_windows.workspace_idxs.append(owm.alloc, workspace_idx) catch unreachable;
}

/// Must be called after arranging a set of outputs. In case we've had an output removed,
/// we'll have a list of orphaned windows. These should get moved into the view of another output.
/// We move them to the first available outputs viewport.
pub fn handleOrphanedWindows(self: *Self) void {
    if (self.orphaned_windows.getCount() == 0) {
        return;
    }

    var output_to_move_maybe: ?*Output = null;
    var output_iter = owm.SERVER.output_manager.outputs.iterator(.forward);
    while (output_iter.next()) |output| {
        if (output.is_active) {
            output_to_move_maybe = output;
            break;
        }
    }

    if (output_to_move_maybe == null) {
        log.debugf("Scene: There are no active outputs, keeping {} orphan windows", .{self.orphaned_windows.getCount()});
    }

    var output_to_move = output_to_move_maybe.?;
    log.debugf("Scene: Moving {} orphaned windows to output {s}", .{ self.orphaned_windows.getCount(), output_to_move.id });

    output_to_move.ensureWorkspacesExist(self.orphaned_windows.getMaxWorkspaceIdx());

    var orphan_window_iter = self.orphaned_windows.windows.iterator(.forward);
    var counter: usize = 0;
    while (orphan_window_iter.next()) |window| : (counter += 1) {
        const workspace_idx = self.orphaned_windows.workspace_idxs.items[counter];
        log.debugf("Scene: Moving window {*} to output {s} workspace {}", .{ window, output_to_move.id, workspace_idx + 1 });
        window.setCurrentOutput(output_to_move);
        output_to_move.sceneMoveWindowToWorkspace(window, workspace_idx);
    }

    output_to_move.sceneEnsureWindowsInViewport();

    log.debugf("Scene: Moved {} orphaned windows to output {s}", .{ self.orphaned_windows.getCount(), output_to_move.id });
    self.orphaned_windows.clear();
}
