const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;
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

pub const Workspace = struct {
    root: *wlr.SceneTree,
    windows: wl.list.Head(Window, .link) = undefined,
};

pub const OutputScene = struct {
    root: *wlr.SceneTree,
    output: *Output,
    current_workspace_idx: usize = 0,
    workspaces: std.ArrayList(Workspace) = .empty,

    pub fn newWorkspace(self: *OutputScene) !void {
        try self.workspaces.append(owm.alloc, Workspace{
            .root = try self.root.createSceneTree(),
        });
        var new_workspace = &self.workspaces.items[self.workspaces.items.len - 1];
        new_workspace.windows.init();
        new_workspace.root.node.setEnabled(false);
    }

    pub inline fn enableWorkspace(self: *OutputScene, idx: usize) void {
        if (idx >= self.workspaces.items.len) {
            log.errf("OuptutScene {s}: Tried to enable non-existent workspace {}. Only {} workspaces exist", .{ self.output.id, idx, self.workspaces.items.len });
            return;
        }
        self.workspaces.items[idx].root.node.setEnabled(true);
    }

    pub fn switchWorkspace(self: *OutputScene, new_workspace_idx: usize) void {
        if (new_workspace_idx >= self.workspaces.items.len) {
            return;
        }
        self.getCurrentWorkspaceRoot().node.setEnabled(false);
        self.current_workspace_idx = new_workspace_idx;
        self.getCurrentWorkspaceRoot().node.setEnabled(true);
        self.output.damageWhole();
    }

    inline fn getCurrentWorkspace(self: *OutputScene) *Workspace {
        return &self.workspaces.items[self.current_workspace_idx];
    }

    pub fn getCurrentWorkspaceRoot(self: *OutputScene) *wlr.SceneTree {
        return self.getCurrentWorkspace().root;
    }

    pub fn addWindowToCurrentWorkspace(self: *OutputScene, window: *Window) void {
        self.getCurrentWorkspace().windows.append(window);
    }

    pub fn raiseWindowToTopOfWorkspace(self: *OutputScene, window: *Window) void {
        window.link.remove();
        self.getCurrentWorkspace().windows.prepend(window);
    }

    /// Puts the topmost window at the end of the list and returns the new top window.
    /// Also known as `Alt+Tab`
    pub fn switchToNextWindowInWorkspace(self: *OutputScene) ?*Window {
        var workspace = self.getCurrentWorkspace();
        if (workspace.windows.first()) |first_window| {
            first_window.link.remove();
            workspace.windows.append(first_window);
            return workspace.windows.first().?;
        }
        return null;
    }

    /// Moves a window from its current workspace to a different target workspace.
    /// If the window is already in the target workspace, it is removed first.
    pub fn moveWindowToWorkspace(self: *OutputScene, window: *Window, target_workspace_idx: usize) void {
        // Create intermediate workspaces if the target workspace doesn't exist yet
        if (target_workspace_idx >= self.workspaces.items.len) {
            var next_idx: usize = self.workspaces.items.len;
            while (next_idx <= target_workspace_idx) : (next_idx += 1) {
                self.newWorkspace() catch {
                    log.errf("OutputScene {s}: Failed to create new workspace while trying to move window to it", .{self.output.id});
                    return;
                };
            }
        }

        window.link.remove();
        var target_workspace = &self.workspaces.items[target_workspace_idx];
        window.setSceneTreeParent(target_workspace.root);
        target_workspace.windows.prepend(window);
    }

    pub fn getTopWindowInWorkspace(self: *OutputScene) ?*Window {
        return self.getCurrentWorkspace().windows.first();
    }

    /// When an outputs mode is changes, the windows in it's scene viewport are potentially
    /// not in view anymore. Move them into view if they're outside of the viewport
    /// of the output.
    pub fn handleOutputModeChange(self: *OutputScene) void {
        if (!self.output.is_active) {
            log.debugf("OutputScene {s}: Output is disabled, marking owned windows as orphan", .{self.output.id});
            // TODO: collect owned windows as orphan windows
            return;
        }
        log.debugf("OutputScene {s}: Moving windows belonging to output into viewport post mode change", .{self.output.id});

        const output_area = self.output.area;
        for (self.workspaces.items) |*workspace| {
            var window_iter = workspace.windows.iterator(.forward);
            while (window_iter.next()) |window| {
                const window_pos = window.getPos();
                const window_geom = window.getGeom();
                const geom: wlr.Box = .{
                    .x = window_pos.x,
                    .y = window_pos.y,
                    .width = window_geom.width,
                    .height = window_geom.height,
                };
                var intersection: wlr.Box = undefined;
                _ = wlr.Box.intersection(&intersection, &output_area, &geom);
                if (intersection.width <= 0 or intersection.height <= 0) {
                    log.debugf("OutputScene {s}: Window {*} is not in viewport, moving", .{ self.output.id, window });
                    const new_window_coords = self.output.getCenterPosForWindow(geom.width, geom.height);
                    window.setPos(new_window_coords.x, new_window_coords.y);
                }
            }
        }

        log.debugf("OutputScene {s}: Completed moving windows to viewport", .{self.output.id});
    }
};

const OrphanWindow = struct {
    workspace_idx: usize,
    window: *Window,
};

wlr_scene: *wlr.Scene,
wlr_scene_output_layout: *wlr.SceneOutputLayout,

output_scenes: std.ArrayList(OutputScene) = .empty,
orphaned_windows: std.ArrayList(OrphanWindow) = .empty,

root: *wlr.SceneTree,
layers: struct {
    /// `background` layer shell surfaces
    background: *wlr.SceneTree,
    /// `bottom` layer shell surfaces
    bottom: *wlr.SceneTree,
    /// Root node for anchoring the workspaces of outputs
    outputs_root: *wlr.SceneTree,
    /// `top` layer shell surfaces
    top: *wlr.SceneTree,
    /// `overlay` layer shell surfaces
    overlay: *wlr.SceneTree,
    /// `XdgShell` popup surfaces
    popups: *wlr.SceneTree,
    /// Xwayland override redirect windows
    override_redirect: *wlr.SceneTree,
},

pub fn create(wlr_output_layout: *wlr.OutputLayout) !Self {
    const wlr_scene = try wlr.Scene.create();
    const wlr_scene_output_layout = try wlr_scene.attachOutputLayout(wlr_output_layout);
    const root = try wlr_scene.tree.createSceneTree();
    return Self{
        .wlr_scene = wlr_scene,
        .wlr_scene_output_layout = wlr_scene_output_layout,
        .root = root,
        .layers = .{
            .background = try root.createSceneTree(),
            .bottom = try root.createSceneTree(),
            .outputs_root = try root.createSceneTree(),
            .top = try root.createSceneTree(),
            .overlay = try root.createSceneTree(),
            .popups = try root.createSceneTree(),
            .override_redirect = try root.createSceneTree(),
        },
    };
}

pub fn deinit(self: *Self) void {
    self.output_scenes.deinit(owm.alloc);
    self.orphaned_windows.deinit(owm.alloc);
}

pub fn createOutputScene(self: *Self, output: *Output) !*OutputScene {
    var output_scene = OutputScene{
        .output = output,
        .root = try self.layers.outputs_root.createSceneTree(),
    };
    try output_scene.newWorkspace();
    output_scene.enableWorkspace(0);
    try self.output_scenes.append(owm.alloc, output_scene);
    return &self.output_scenes.items[self.output_scenes.items.len - 1];
}

pub fn removeOutputScene(self: *Self, output: *Output) void {
    log.debugf("Scene: Removing output {s} from the scene", .{output.id});
    for (self.output_scenes.items, 0..) |*os, idx| {
        if (os.output != output) continue;
        // TODO: collect windows owned by this output into orphaned windows
        os.root.node.destroy();
        _ = self.output_scenes.swapRemove(idx);
        return;
    }
    log.err("Scene: Tried to remove OutputScene for an unknown output");
}

pub fn getLayerSurfaceTree(self: *Self, layer: zwlr.LayerShellV1.Layer) *wlr.SceneTree {
    switch (layer) {
        .background => return self.layers.background,
        .bottom => return self.layers.bottom,
        .top => return self.layers.top,
        .overlay => return self.layers.overlay,
        _ => unreachable,
    }
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

/// Must be called after arranging a set of outputs. In case we've had an output removed,
/// we'll have a list of orphaned windows. These should get moved into the view of another output.
/// We move them to the first available outputs viewport.
pub fn handleOrphanedWindows(self: *Self) void {
    if (self.orphaned_windows.items.len == 0 or self.output_scenes.items.len == 0) return;

    var output_scene = self.output_scenes.items[0];
    log.debugf("Scene: Moving orphaned windows to output {s}", .{output_scene.output.id});

    for (self.orphaned_windows.items) |*orphan_window| {
        // Make sure the workspace idx exists
        // Add to workspace
        if (orphan_window.workspace_idx >= output_scene.workspaces.items.len) {
            var next_idx: usize = output_scene.workspaces.items.len;
            while (next_idx <= orphan_window.workspace_idx) : (next_idx += 1) {
                output_scene.newWorkspace() catch {
                    log.err("Failed to create new workspace while tyring to move orphaned window to it");
                    return;
                };
            }
        }

        // TODO: move orphaned window to the selected output_scene
    }

    log.debugf("Scene: Moved orphaned windows to output {s}", .{output_scene.output.id});
    self.orphaned_windows.clearAndFree(owm.alloc);
}
