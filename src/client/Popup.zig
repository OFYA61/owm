const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const client = owm.client;

wlr_xdg_popup: *wlr.XdgPopup,
parent: *client.Client,

commit_listener: wl.Listener(*wlr.Surface) = .init(commitCallback),
reposition_listener: wl.Listener(void) = .init(repositionCallback),
new_popup_listener: wl.Listener(*wlr.XdgPopup) = .init(newPopupCallback),
destroy_listener: wl.Listener(void) = .init(destroyCallback),

pub fn create(
    wlr_xdg_popup: *wlr.XdgPopup,
    parent: *owm.client.Client,
) client.Client.Error!Self {
    return .{
        .wlr_xdg_popup = wlr_xdg_popup,
        .parent = parent,
    };
}

pub fn setup(self: *Self) void {
    self.wlr_xdg_popup.base.surface.events.commit.add(&self.commit_listener);
    self.wlr_xdg_popup.events.reposition.add(&self.reposition_listener);
    self.wlr_xdg_popup.base.events.new_popup.add(&self.new_popup_listener);
    self.wlr_xdg_popup.events.destroy.add(&self.destroy_listener);
}

pub fn getWlrSurface(self: *Self) *wlr.Surface {
    return self.wlr_xdg_popup.base.surface;
}

pub fn getGeom(self: *Self) wlr.Box {
    return self.wlr_xdg_popup.base.geometry;
}

fn unconstrain(self: *Self) void {
    self.wlr_xdg_popup.unconstrainFromBox(&self.parent.getUnconstrainBox());
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
    _ = client.Client.newPopup(wlr_xdg_popup, client.Client.from(popup)) catch |err| {
        owm.log.errf("Failed to create XDG Popup{}", .{err});
        return;
    };
}

fn destroyCallback(listener: *wl.Listener(void)) void {
    const popup: *Self = @fieldParentPtr("destroy_listener", listener);

    popup.commit_listener.link.remove();
    popup.reposition_listener.link.remove();
    popup.new_popup_listener.link.remove();
    popup.destroy_listener.link.remove();

    owm.c_alloc.destroy(client.Client.from(popup));
}
