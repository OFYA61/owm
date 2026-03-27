const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;
const log = owm.log;

wlr_xdg_popup: *wlr.XdgPopup,
root_scene_tree: *wlr.SceneTree,
scene_tree: *wlr.SceneTree,
output: *owm.Output,

commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
reposition_listener: wl.Listener(void) = .init(repositionCallback),
new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newPopupCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),

pub fn create(wlr_xdg_popup: *wlr.XdgPopup, root_scene_tree: *wlr.SceneTree, parent_scene_tree: *wlr.SceneTree, parent_output: *owm.Output) client.Error!*Self {
    var self = try owm.c_alloc.create(Self);
    errdefer owm.c_alloc.destroy(self);

    const scene_tree = parent_scene_tree.createSceneXdgSurface(wlr_xdg_popup.base) catch {
        log.err("Failed to create scene tree for Popup");
        return client.Error.FailedToCreateSceneTree;
    };

    self.* = .{
        .wlr_xdg_popup = wlr_xdg_popup,
        .root_scene_tree = root_scene_tree,
        .scene_tree = scene_tree,
        .output = parent_output,
    };

    self.wlr_xdg_popup.base.surface.events.commit.add(&self.commit_listener);
    self.wlr_xdg_popup.events.reposition.add(&self.reposition_listener);
    self.wlr_xdg_popup.base.events.new_popup.add(&self.new_popup_listener);
    self.wlr_xdg_popup.events.destroy.add(&self.destroy_listener);

    return self;
}

fn unconstrain(self: *Self) void {
    var root_lx: c_int = undefined;
    var root_ly: c_int = undefined;
    _ = self.root_scene_tree.node.coords(&root_lx, &root_ly);
    var box: wlr.Box = undefined;
    owm.server.wlr_output_layout.getBox(self.output.wlr_output, &box);
    box.x -= root_lx;
    box.y -= root_ly;
    self.wlr_xdg_popup.unconstrainFromBox(&box);
}

fn commitCallback(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const popup: *Self = @fieldParentPtr("commit_listener", listener);
    if (popup.wlr_xdg_popup.base.initial_commit) {
        popup.unconstrain();
        _ = popup.wlr_xdg_popup.base.scheduleConfigure();
    }
}

fn repositionCallback(listener: *wl.Listener(void)) void {
    const popup: *Self = @fieldParentPtr("reposition_listener", listener);
    popup.unconstrain();
}

fn newPopupCallback(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const popup: *Self = @fieldParentPtr("new_popup_listener", listener);
    _ = create(wlr_xdg_popup, popup.root_scene_tree, popup.scene_tree, popup.output) catch |err| {
        log.errf("Failed to create XDG Popup{}", .{err});
        return;
    };
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const popup: *Self = @fieldParentPtr("destroy_listener", listener);

    popup.commit_listener.link.remove();
    popup.reposition_listener.link.remove();
    popup.new_popup_listener.link.remove();
    popup.destroy_listener.link.remove();

    owm.c_alloc.destroy(popup);
}
