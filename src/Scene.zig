const Self = @This();

const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const log = owm.log;

pub const WindowAtResponse = struct {
    sx: f64,
    sy: f64,
    wlr_surface: *wlr.Surface,
    window: *owm.client.window.Window,
};

pub const SurfaceAtResponse = struct {
    sx: f64,
    sy: f64,
    wlr_surface: *wlr.Surface,
};

wlr_scene: *wlr.Scene,
wlr_scene_output_layout: *wlr.SceneOutputLayout,

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
    return .{
        .wlr_scene = wlr_scene,
        .wlr_scene_output_layout = wlr_scene_output_layout,
        .root = root,
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
}

// TODO: modify this when implementing multiple workspaces
pub fn getCurrentWorkspaceRoot(self: *Self) *wlr.SceneTree {
    return self.layers.workspace;
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
            if (owm.client.window.Window.fromOpaquePtr(n.node.data)) |window| {
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
