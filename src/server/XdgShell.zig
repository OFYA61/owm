const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const log = owm.log;

wlr_xdg_shell: *wlr.XdgShell,
new_toplevel_listener: wl.Listener(*wlr.XdgToplevel) = .init(newToplevelCallback),

pub fn create(wl_server: *wl.Server) !Self {
    const wlr_xdg_shell = try wlr.XdgShell.create(wl_server, 3); // XDG protocol for app windows
    return .{
        .wlr_xdg_shell = wlr_xdg_shell,
    };
}

pub fn init(self: *Self) void {
    self.wlr_xdg_shell.events.new_toplevel.add(&self.new_toplevel_listener);
}

pub fn deinit(self: *Self) void {
    self.new_toplevel_listener.link.remove();
}

fn newToplevelCallback(_: *wl.Listener(*wlr.XdgToplevel), wlr_xdg_toplevel: *wlr.XdgToplevel) void {
    _ = owm.client.window.Window.newXdgToplevel(wlr_xdg_toplevel) catch |err| {
        log.errf("Failed to allocate new toplevel {}", .{err});
        wlr_xdg_toplevel.sendClose();
        return;
    };
}
