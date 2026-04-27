//! Represents a display output in the Wayland compositor.
//! Manages output geometry, output scene (everything that gets rendered on it),
//! frame callbacks, state requests, and destruction events.
pub const Self = @This();

const std = @import("std");
const posix = @import("std").posix;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const zwlr = @import("wayland").server.zwlr;
const pixman = @import("pixman");

const owm = @import("root").owm;
const log = owm.log;

const Window = owm.client.window.Window;

const Workspace = struct {
    root: *wlr.SceneTree,
    windows: wl.list.Head(Window, .link) = undefined,

    inline fn setEnabled(self: *Workspace, enabled: bool) void {
        self.root.node.setEnabled(enabled);
    }
};

pub const ExclusiveZone = struct {
    type: Type,
    size: u32,
    owner: *owm.client.LayerSurface,
    pub const Type = enum { Top, Right, Bottom, Left };
};

pub const Mode = struct {
    width: i32,
    height: i32,
    refresh: i32,
};

pub const Error = error{
    CommitState,
    InitRenderer,
    AddOutputLayout,
    CreateSceneOutput,
    ModeDoesNotExist,
    OutOfMemory,
};

id: []u8,
wlr_output: *wlr.Output,
wlr_layout_output: *wlr.OutputLayout.Output,
wlr_scene_output: *wlr.SceneOutput,
area: wlr.Box,
work_area: wlr.Box,
link: wl.list.Link = undefined,
exclusive_zones: std.ArrayList(ExclusiveZone) = .empty,

scene: struct {
    const Scene = @This();
    root: *wlr.SceneTree,
    layers: struct {
        /// `background` layer shell surfaces
        background: *wlr.SceneTree,
        /// `bottom` layer shell surfaces
        bottom: *wlr.SceneTree,
        /// Root node for anchoring the workspaces
        workspaces_root: *wlr.SceneTree,
        /// `top` layer shell surfaces
        top: *wlr.SceneTree,
        /// `overlay` layer shell surfaces
        overlay: *wlr.SceneTree,
        /// `XdgShell` popup surfaces
        popups: *wlr.SceneTree,
        /// Xwayland override redirect windows
        override_redirect: *wlr.SceneTree,
    },
    workspaces: std.ArrayList(Workspace),
    current_workspace_idx: usize = 0,
},
is_active: bool = true,

frame_listener: wl.Listener(*wlr.Output) = .init(frameCallback),
request_state_listener: wl.Listener(*wlr.Output.event.RequestState) = .init(requestStateCallback),
destroy_listener: wl.Listener(*wlr.Output) = .init(destroyCallback),

pub fn fromOpaquePtr(ptr: ?*anyopaque) ?*Self {
    return @as(*Self, @ptrCast(@alignCast(ptr)));
}

pub fn create(wlr_output: *wlr.Output) Error!*Self {
    const id = try std.mem.join(owm.alloc, ":", &[_][]const u8{
        std.mem.span(wlr_output.serial orelse wlr_output.name),
    });

    const self = try owm.c_alloc.create(Self);
    errdefer owm.c_alloc.destroy(self);

    if (!wlr_output.initRender(owm.SERVER.wlr_allocator, owm.SERVER.wlr_renderer)) {
        log.errf("Output {s}: Failed to initialize render with allocator and renderer on new output", .{id});
        return Error.InitRenderer;
    }

    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(true);
    if (!wlr_output.modes.empty()) {
        var modes_iterator = wlr_output.modes.iterator(.forward);
        log.infof("Output {s}: The output has the following modes:", .{id});
        while (modes_iterator.next()) |mode| {
            log.infof(
                "\t- {}x{} {}Hz",
                .{
                    mode.width,
                    mode.height,
                    @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(mode.refresh)) / 1000))),
                },
            );
        }
    }
    if (wlr_output.preferredMode()) |mode| {
        log.infof(
            "Output {s}: Has the preferred mode {}x{} {}Hz",
            .{
                id,
                mode.width,
                mode.height,
                @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(mode.refresh)) / 1000))),
            },
        );
        state.setMode(mode);
    }
    if (!wlr_output.commitState(&state)) {
        log.errf("Output {s}: Failed to commit state for new output", .{id});
        return Error.CommitState;
    }

    const layout_output = owm.SERVER.output_manager.wlr_output_layout.addAuto(wlr_output) catch {
        return Error.AddOutputLayout;
    };
    const scene_output = owm.SERVER.scene.wlr_scene.createSceneOutput(wlr_output) catch { // Add a viewport for the output to the scene graph.
        return Error.CreateSceneOutput;
    };
    owm.SERVER.scene.wlr_scene_output_layout.addOutput(layout_output, scene_output); // Add the output to the scene output layout. When the layout output is repositioned, the scene output will be repositioned accordingly.

    const area = wlr.Box{
        .x = layout_output.x,
        .y = layout_output.y,
        .width = wlr_output.width,
        .height = wlr_output.height,
    };

    const scene_root = try owm.SERVER.scene.root.createSceneTree();
    self.* = .{
        .id = id,
        .wlr_output = wlr_output,
        .area = area,
        .work_area = area,
        .wlr_layout_output = layout_output,
        .wlr_scene_output = scene_output,
        .scene = .{
            .root = scene_root,
            .layers = .{
                .background = try scene_root.createSceneTree(),
                .bottom = try scene_root.createSceneTree(),
                .workspaces_root = try scene_root.createSceneTree(),
                .top = try scene_root.createSceneTree(),
                .overlay = try scene_root.createSceneTree(),
                .popups = try scene_root.createSceneTree(),
                .override_redirect = try scene_root.createSceneTree(),
            },
            .workspaces = .empty,
        },
    };
    try self.sceneCreateWorkspace();
    self.getCurrentWorkspace().setEnabled(true);

    wlr_output.data = self;

    wlr_output.events.frame.add(&self.frame_listener);
    wlr_output.events.request_state.add(&self.request_state_listener);
    wlr_output.events.destroy.add(&self.destroy_listener);

    return self;
}

pub fn getModel(self: *Self) []const u8 {
    if (self.wlr_output.model) |model| {
        return std.mem.span(model);
    }
    return std.mem.span(self.wlr_output.name);
}

pub fn disableOutput(self: *Self) Error!void {
    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(false);
    if (!self.wlr_output.commitState(&state)) {
        log.errf("Output {s}: Failed to commit state", .{self.id});
        return Error.CommitState;
    }
    owm.SERVER.output_manager.wlr_output_layout.remove(self.wlr_output);
    self.is_active = false;

    log.debugf("Output {s}: Deactivated, marking orphaning windows", .{self.id});
    self.sceneOrphanWindows();
}

pub fn setModeAndPos(self: *Self, new_x: i32, new_y: i32, new_mode: Mode) Error!void {
    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(true);

    // Find the requsted mode from the available modes
    var modes_iter = self.wlr_output.modes.iterator(.forward);
    var mode: ?*wlr.Output.Mode = null;
    while (modes_iter.next()) |m| {
        if (m.width == new_mode.width and m.height == new_mode.height and
            new_mode.refresh == @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(m.refresh)) / 1000))))
        {
            mode = m;
            break;
        }
    }
    if (mode == null) {
        log.errf("Output {s}: The given mode {}x{} {}Hz does not exist", .{ self.id, new_mode.width, new_mode.height, new_mode.refresh });
        return Error.ModeDoesNotExist;
    }
    state.setMode(mode.?);
    if (!self.wlr_output.commitState(&state)) {
        log.errf("Output {s}: Failed to commit state", .{self.id});
        return Error.CommitState;
    }

    const x = @as(c_int, new_x);
    const y = @as(c_int, new_y);
    self.wlr_layout_output = owm.SERVER.output_manager.wlr_output_layout.add(self.wlr_output, x, y) catch unreachable;
    self.area = wlr.Box{
        .x = x,
        .y = y,
        .width = self.wlr_output.width,
        .height = self.wlr_output.height,
    };
    self.recalculateWorkArea();
    self.is_active = true;
}

pub fn getCenterPosForWindow(self: *Self, window_width: c_int, window_height: c_int) owm.math.Vec2(i32) {
    const area = self.area;
    const x: i32 = area.x + @divExact(area.width, 2) - @divExact(window_width, 2);
    const y: i32 = area.y + @divExact(area.height, 2) - @divExact(window_height, 2);
    return .{ .x = x, .y = y };
}

pub fn getRefresh(self: *Self) i32 {
    return @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(self.wlr_output.current_mode.?.refresh)) / 1000)));
}

pub fn isDisplay(self: *Self) bool {
    if (self.wlr_output.current_mode) |_| {
        return true;
    }
    return false;
}

pub fn addExclusiveZone(self: *Self, exclusive_zone: ExclusiveZone) error{OutOfMemory}!void {
    log.debugf("Output {s}: Adding exclusive zone {} {}", .{ self.id, exclusive_zone.type, exclusive_zone.size });
    try self.exclusive_zones.append(owm.alloc, exclusive_zone);
    self.recalculateWorkArea();
}

pub fn removeExclusiveZoneByOwner(self: *Self, owner: *owm.client.LayerSurface) void {
    var index: ?usize = null;
    for (self.exclusive_zones.items, 0..) |*zone, i| {
        if (zone.owner == owner) {
            index = i;
        }
    }

    if (index) |i| {
        _ = self.exclusive_zones.orderedRemove(i);
        self.recalculateWorkArea();

        // Rearrange the position of the owners of exclusive zones
        var top: c_int = 0;
        var bottom: c_int = 0;
        var left: c_int = 0;
        var right: c_int = 0;
        for (self.exclusive_zones.items) |zone| {
            const size: c_int = @intCast(zone.size);
            var new_x: c_int = undefined;
            var new_y: c_int = undefined;

            switch (zone.type) {
                .Top => {
                    new_x = self.area.x + left;
                    new_y = self.area.y + top;
                    top += size;
                },
                .Bottom => {
                    new_x = self.area.x + left;
                    new_y = self.area.y + self.area.height - bottom;
                    bottom += size;
                },
                .Left => {
                    new_x = self.area.x + left;
                    new_y = self.area.y + top;
                    left += size;
                },
                .Right => {
                    new_x = self.area.x + self.area.width - right;
                    new_y = self.area.y + top;
                    right += size;
                },
            }
            zone.owner.setPos(new_x, new_y);
        }
    }
}

pub fn damageWhole(self: *Self) void {
    const scene_output = owm.SERVER.scene.wlr_scene.getSceneOutput(self.wlr_output).?;
    const x: c_int = self.area.x;
    const y: c_int = self.area.y;
    const width: c_uint = @intCast(self.wlr_output.width);
    const height: c_uint = @intCast(self.wlr_output.height);

    var damage: pixman.Region32 = undefined;
    defer damage.deinit();
    damage.initRect(x, y, width, height);

    var clipped: pixman.Region32 = undefined;
    defer clipped.deinit();
    clipped.init();
    _ = clipped.intersectRect(&damage, x, y, width, height);

    if (clipped.notEmpty()) {
        self.wlr_output.scheduleFrame();
        scene_output.damage_ring.add(&clipped);
        _ = scene_output.private.pending_commit_damage.@"union"(&scene_output.private.pending_commit_damage, &clipped);
    }
}

fn recalculateWorkArea(self: *Self) void {
    var top: c_int = 0;
    var bottom: c_int = 0;
    var left: c_int = 0;
    var right: c_int = 0;
    for (self.exclusive_zones.items) |zone| {
        const size: c_int = @intCast(zone.size);
        switch (zone.type) {
            .Top => top += size,
            .Bottom => bottom += size,
            .Left => left += size,
            .Right => right += size,
        }
    }

    var new_work_area = self.area;
    new_work_area.x += left;
    new_work_area.y += top;
    new_work_area.width -= (left + right);
    new_work_area.height -= (top + bottom);

    self.work_area = new_work_area;

    log.debugf("Output {s}: New work area ({}, {}, {}, {})", .{ self.id, self.work_area.x, self.work_area.y, self.work_area.width, self.work_area.height });
}

//////////////////////////////////
///////////// Scene //////////////
//////////////////////////////////

/// Creats and appends a workspace to the list of workspaces, disabled by default
pub fn sceneCreateWorkspace(self: *Self) !void {
    var scene = &self.scene;
    try scene.workspaces.append(
        owm.alloc,
        Workspace{ .root = try scene.root.createSceneTree() },
    );
    var new_workspace = &scene.workspaces.items[scene.workspaces.items.len - 1];
    new_workspace.windows.init();
    new_workspace.setEnabled(false);
    log.debugf("Output {s}: Created workspace {}", .{ self.id, scene.workspaces.items.len });
}

pub fn sceneSwitchWorkspace(self: *Self, idx: usize) void {
    var scene = &self.scene;
    if (idx >= scene.workspaces.items.len) {
        return;
    }
    self.getCurrentWorkspace().setEnabled(false);
    scene.current_workspace_idx = idx;
    self.getCurrentWorkspace().setEnabled(true);
    self.damageWhole();
}

pub inline fn sceneGetCurrentRoot(self: *Self) *wlr.SceneTree {
    return self.getCurrentWorkspace().root;
}

pub inline fn sceneGetRoot(self: *Self, idx: usize) *wlr.SceneTree {
    return self.scene.workspaces.items[idx].root;
}

pub fn sceneAddWindow(self: *Self, window: *Window) void {
    self.getCurrentWorkspace().windows.prepend(window);
    window.setSceneTreeParent(self.sceneGetCurrentRoot());
}

/// Ensures that the workspaces up until the given `idx` exists, if not, it creates them on the spot
pub fn ensureWorkspacesExist(self: *Self, idx: usize) void {
    const scene = &self.scene;
    if (idx < scene.workspaces.items.len) return;

    var next_idx: usize = scene.workspaces.items.len;
    while (next_idx <= idx) : (next_idx += 1) {
        self.sceneCreateWorkspace() catch {
            log.errf("Output {s}: Failed to create new workspace", .{self.id});
            return;
        };
    }
}

pub fn sceneMoveWindowToWorkspace(self: *Self, window: *Window, target_workspace_idx: usize) void {
    const scene = &self.scene;
    self.ensureWorkspacesExist(target_workspace_idx);

    window.link.remove();
    var target_workspace = &scene.workspaces.items[target_workspace_idx];
    window.setSceneTreeParent(target_workspace.root);
    target_workspace.windows.prepend(window);

    log.debugf("Output {s}: Moved window to workspace {}", .{ self.id, target_workspace_idx + 1 });
}

pub fn sceneEnsureWindowsInViewport(self: *Self) void {
    if (!self.is_active) {
        log.debugf("Output {s}: Deactivated, marking orphaning windows", .{self.id});
        self.sceneOrphanWindows();
        return;
    }

    log.debugf("Output {s}: Moving windows belonging to output into viewport", .{self.id});
    for (self.scene.workspaces.items) |*workspace| {
        var window_iter = workspace.windows.iterator(.forward);
        while (window_iter.next()) |window| {
            self.sceneEnsureWindowInViewport(window);
        }
    }
    log.debugf("Output {s}: Moved windows belonging to output into viewport", .{self.id});
}

pub fn sceneEnsureWindowInViewport(self: *Self, window: *Window) void {
    if (!window.isMapped()) return;

    const window_pos = window.getPos();
    const window_geom = window.getGeom();
    const geom: wlr.Box = .{
        .x = window_pos.x,
        .y = window_pos.y,
        .width = window_geom.width,
        .height = window_geom.height,
    };
    var intersection: wlr.Box = undefined;
    const intersected = wlr.Box.intersection(&intersection, &self.area, &geom);
    if (!intersected) {
        log.debugf("Output {s}: Window '{s}' is not in viewport, moving", .{ self.id, window.getTitle() orelse "" });
        const new_window_coords = self.getCenterPosForWindow(geom.width, geom.height);
        window.setPos(new_window_coords.x, new_window_coords.y);
        log.debugf("Output {s}: Window '{s}' moved to viewport", .{ self.id, window.getTitle() orelse "" });
    }
}

fn sceneOrphanWindows(self: *Self) void {
    log.debugf("Output {s}: Marking owned windows as orphan", .{self.id});
    var count: usize = 0;
    for (self.scene.workspaces.items, 0..) |*workspace, idx| {
        var window_iter = workspace.windows.iterator(.forward);
        while (window_iter.next()) |window| : (count += 1) {
            owm.SERVER.scene.storeOrphanWindow(window, idx);
        }
    }
    log.debugf("Output {s}: Marked {} owned windows as orphan", .{ self.id, count });
}

/// Puts the topmost window at the end of the list and returns the new top window in the current workspace
/// Also known as `Alt+Tab`
pub fn sceneSwitchToNextWindow(self: *Self) ?*Window {
    var workspace = self.getCurrentWorkspace();
    if (workspace.windows.first()) |first_window| {
        first_window.link.remove();
        workspace.windows.append(first_window);
        return workspace.windows.first().?;
    }
    return null;
}

pub fn sceneGetTopWindow(self: *Self) ?*Window {
    return self.getCurrentWorkspace().windows.first();
}

pub fn sceneGetLayerSurfaceTree(self: *Self, layer: zwlr.LayerShellV1.Layer) *wlr.SceneTree {
    const scene = &self.scene;
    switch (layer) {
        .background => return scene.layers.background,
        .bottom => return scene.layers.bottom,
        .top => return scene.layers.top,
        .overlay => return scene.layers.overlay,
        _ => unreachable,
    }
}

pub fn raiseWindowToTopOfWorkspace(self: *Self, window: *Window) void {
    window.link.remove();
    self.getCurrentWorkspace().windows.prepend(window);
}

inline fn getCurrentWorkspace(self: *Self) *Workspace {
    const scene = &self.scene;
    return &scene.workspaces.items[scene.current_workspace_idx];
}

//////////////////////////////////////
///////////// Callbacks //////////////
//////////////////////////////////////

/// Called every time when an output is ready to display a frame, generally at the refresh rate
fn frameCallback(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("frame_listener", listener);

    const scene_output = owm.SERVER.scene.wlr_scene.getSceneOutput(wlr_output).?;
    if (!(scene_output.output.needs_frame or pixman.Region32.notEmpty(&scene_output.private.pending_commit_damage) or scene_output.private.gamma_lut != null)) {
        return;
    }

    var output_state = wlr.Output.State.init();
    defer output_state.finish();

    if (!scene_output.buildState(&output_state, null)) {
        log.errf("Output {s}: Failed to build output state", .{self.id});
        return;
    }

    if (!wlr_output.commitState(&output_state)) {
        log.errf("Output {s}: Failed to commit output state", .{self.id});
        return;
    }

    var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
}

/// Called when the backend requests a new state for the output. E.g. new mode request when resizing it in Wayland backend
fn requestStateCallback(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const self: *Self = @fieldParentPtr("request_state_listener", listener);
    _ = self.wlr_output.commitState(event.state);
    if (owm.SERVER.wlr_backend.isWl() or owm.SERVER.wlr_backend.isX11()) {
        self.area = .{
            .x = 0,
            .y = 0,
            .width = event.output.width,
            .height = event.output.height,
        };
        self.recalculateWorkArea();
    }
}

fn destroyCallback(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("destroy_listener", listener);

    log.debugf("Output {s}: Destroying output data", .{self.id});

    var should_terminate_server = true;
    if (self.isDisplay()) {
        should_terminate_server = false;
    } else {
        log.infof("Output {s}: Terminating server", .{self.id});
    }

    self.frame_listener.link.remove();
    self.request_state_listener.link.remove();
    self.destroy_listener.link.remove();
    self.is_active = false;

    if (!should_terminate_server) {
        self.sceneOrphanWindows();
        self.scene.root.node.destroy();
    }

    self.link.remove();
    owm.c_alloc.destroy(self);

    if (should_terminate_server) {
        owm.SERVER.wl_server.terminate();
        return;
    }

    owm.SERVER.output_manager.setupOutputArrangement();
}
