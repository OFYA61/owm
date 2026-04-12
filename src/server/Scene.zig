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
    }

    pub fn switchWorkspace(self: *OutputScene, new_workspace_idx: usize) void {
        if (new_workspace_idx >= self.workspaces.items.len) {
            return;
        }
        // TODO: fix previous workspace not cleaning up fully
        self.getCurrentWorkspaceRoot().node.enabled = false;
        self.current_workspace_idx = new_workspace_idx;
        self.getCurrentWorkspaceRoot().node.enabled = true;
        self.output.damageWhole();
    }

    pub fn removeWorkspace(self: *OutputScene, remove_idx: usize) void {
        _ = self;
        _ = remove_idx;
        // TODO:
        // 1. Move windows to the previous workspace
        // 2. Remove the workspace
    }

    inline fn getCurrentWorkspace(self: *OutputScene) *Workspace {
        return &self.workspaces.items[self.current_workspace_idx];
    }

    pub fn getCurrentWorkspaceRoot(self: *OutputScene) *wlr.SceneTree {
        return self.getCurrentWorkspace().root;
    }
};

const OrphanWindow = struct {
    workspace_idx: usize,
    window: *Window,
};

wlr_scene: *wlr.Scene,
wlr_scene_output_layout: *wlr.SceneOutputLayout,

current_workspace_idx: usize = 0,
workspaces: std.ArrayList(Workspace) = .empty,

output_scenes: std.ArrayList(OutputScene) = .empty,
orphaned_windows: std.ArrayList(OrphanWindow) = .empty,

root: *wlr.SceneTree,
layers: struct {
    /// `background` layer shell surfaces
    background: *wlr.SceneTree,
    /// `bottom` layer shell surfaces
    bottom: *wlr.SceneTree,
    /// `XdgShell` and `Xwayland` surfaces
    workspace: *wlr.SceneTree,
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
    var new_scene = Self{
        .wlr_scene = wlr_scene,
        .wlr_scene_output_layout = wlr_scene_output_layout,
        .root = root,
        .current_workspace_idx = 0,
        .layers = .{
            .background = try root.createSceneTree(),
            .bottom = try root.createSceneTree(),
            .workspace = try root.createSceneTree(),
            .top = try root.createSceneTree(),
            .overlay = try root.createSceneTree(),
            .popups = try root.createSceneTree(),
            .override_redirect = try root.createSceneTree(),
        },
    };

    try new_scene.createWorkspace();

    return new_scene;
}

pub fn deinit(self: *Self) void {
    self.output_scenes.deinit(owm.alloc);
    self.orphaned_windows.deinit(owm.alloc);
}

pub fn createOutputScene(self: *Self, output: *Output) !*OutputScene {
    var output_scene = OutputScene{
        .output = output,
        .root = try self.layers.workspace.createSceneTree(),
    };
    try output_scene.newWorkspace();
    // TODO: adding 2 workspaces for now for testing purposes, remove this in the future when workspaces get created via user actions
    try output_scene.newWorkspace();
    output_scene.workspaces.items[1].root.node.enabled = false;
    try self.output_scenes.append(owm.alloc, output_scene);
    return &self.output_scenes.items[self.output_scenes.items.len - 1];
}

pub fn removeOutputScene(self: *Self, output: *Output) void {
    for (self.output_scenes.items, 0..) |os, idx| {
        if (os.output == output) {
            _ = self.output_scenes.swapRemove(idx);
            return;
        }
    }
    log.err("Tried to remove OutputScene for an unknown output");
}

fn createWorkspace(self: *Self) !void {
    try self.workspaces.append(
        owm.alloc,
        .{
            .root = try self.layers.workspace.createSceneTree(),
        },
    );
    self.workspaces.items[self.current_workspace_idx].windows.init();
}

fn getCurrentWorkspace(self: *Self) *Workspace {
    return &self.workspaces.items[self.current_workspace_idx];
}

pub fn getCurrentWorkspaceRoot(self: *Self) *wlr.SceneTree {
    return self.getCurrentWorkspace().root;
}

pub fn addWindowToCurrentWorkspace(self: *Self, window: *Window) void {
    self.getCurrentWorkspace().windows.append(window);
}

pub fn raiseWindowToTopOfWorkspace(self: *Self, window: *Window) void {
    window.link.remove();
    self.getCurrentWorkspace().windows.prepend(window);
}

/// Puts the topmost window at the end of the list and returns the new top window.
/// Also known as `Alt+Tab`
pub fn switchToNextWindowInWorkspace(self: *Self) ?*Window {
    var workspace = self.getCurrentWorkspace();
    if (workspace.windows.first()) |first_window| {
        first_window.link.remove();
        workspace.windows.append(first_window);
        return workspace.windows.first().?;
    }
    return null;
}

pub fn getTopWindowInWorkspace(self: *Self) ?*Window {
    return self.getCurrentWorkspace().windows.first();
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
