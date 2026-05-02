const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const log = owm.log;

wlr_ext_workspace_manager: *wlr.ExtWorkspaceManagerV1,
commit_listener: wl.Listener(*wlr.ExtWorkspaceManagerV1.event.Commit) = .init(commitCallback),

pub fn create(wl_server: *wl.Server) !Self {
    const wlr_ext_workspace_manager = try wlr.ExtWorkspaceManagerV1.create(wl_server, 1);
    return .{
        .wlr_ext_workspace_manager = wlr_ext_workspace_manager,
    };
}

pub fn init(self: *Self) void {
    self.wlr_ext_workspace_manager.events.commit.add(&self.commit_listener);
}

pub fn deinit(self: *Self) void {
    self.commit_listener.link.remove();
}

pub fn createGroup(self: *Self) !*wlr.ExtWorkspaceGroupHandleV1 {
    return try self.wlr_ext_workspace_manager.createGroup(.{});
}

pub fn createWorkspace(self: *Self, name: [*:0]const u8) !*wlr.ExtWorkspaceHandleV1 {
    return self.wlr_ext_workspace_manager.createWorkspace(name);
}

fn commitCallback(listener: *wl.Listener(*wlr.ExtWorkspaceManagerV1.event.Commit), event: *wlr.ExtWorkspaceManagerV1.event.Commit) void {
    const self: *Self = @fieldParentPtr("commit_listener", listener);
    _ = self;

    var iter = event.requests.iterator(.forward);
    while (iter.next()) |request| {
        switch (request.type) {
            .activate => {
                if (request.data.activate.workspace) |workspace_handle| {
                    if (workspace_handle.group) |group_handle| {
                        if (owm.SERVER.output_manager.findOutputByWorkspaceGroupHandle(group_handle)) |output| {
                            output.sceneSwitchWorkspaceWithHandle(workspace_handle);
                        }
                    }
                }
            },
            else => {},
        }
    }
}
