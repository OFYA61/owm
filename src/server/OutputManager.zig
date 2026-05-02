const Self = @This();

const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const log = owm.log;

const Output = @import("Output.zig");

wlr_output_layout: *wlr.OutputLayout,
outputs: wl.list.Head(Output, .link) = undefined,
new_output_listener: wl.Listener(*wlr.Output) = .init(newOutputCallback),
output_layout_change_listener: wl.Listener(*wlr.OutputLayout) = .init(outputLayoutChangeListener),

pub fn create(wl_server: *wl.Server) !Self {
    const wlr_output_layout = try wlr.OutputLayout.create(wl_server); // Utility for working with an arrangement of screens in a physical layout
    _ = try wlr.XdgOutputManagerV1.create(wl_server, wlr_output_layout); // Protocol required by `waybar`
    return .{
        .wlr_output_layout = wlr_output_layout,
    };
}

pub fn init(self: *Self) void {
    self.outputs.init();
    owm.SERVER.wlr_backend.events.new_output.add(&self.new_output_listener);
    self.wlr_output_layout.events.change.add(&self.output_layout_change_listener);
}

pub fn deinit(self: *Self) void {
    log.debug("OutputManager: Cleaning up");
    self.new_output_listener.link.remove();
    self.output_layout_change_listener.link.remove();
}

pub inline fn getOutputBox(self: *Self, output: *Output) wlr.Box {
    var box: wlr.Box = undefined;
    self.wlr_output_layout.getBox(output.wlr_output, &box);
    return box;
}

pub fn findOutputByWorkspaceGroupHandle(self: *Self, group_handle: *wlr.ExtWorkspaceGroupHandleV1) ?*Output {
    var iter = self.outputs.iterator(.forward);
    while (iter.next()) |output| {
        if (output.workspace_group_handle == group_handle) {
            return output;
        }
    }
    return null;
}

fn newOutputCallback(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("new_output_listener", listener);

    const new_output = Output.create(wlr_output) catch |err| {
        log.errf("OutputManager: Failed to allocate new output {}", .{err});
        wlr_output.destroy();
        return;
    };

    self.outputs.append(new_output);

    if (!new_output.isDisplay()) {
        return;
    }

    owm.config.output.storeDisplay(new_output.id, new_output.getModel());
    self.setupOutputArrangement();
}

fn outputLayoutChangeListener(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
    const self: *Self = @fieldParentPtr("output_layout_change_listener", listener);
    var output_iter = self.outputs.iterator(.forward);
    owm.SERVER.scene.handleOrphanedWindows();
    while (output_iter.next()) |output| {
        output.sceneEnsureWindowsInViewport();

        // Make sure the cursor isn't outside of the outputs viewports by moving it to the center of an active output
        if (output.is_active) {
            owm.SERVER.seat.setCursorPos(
                @as(f64, @floatFromInt(output.area.x + @divFloor(output.area.width, 2))),
                @as(f64, @floatFromInt(output.area.y + @divFloor(output.area.height, 2))),
            );
            break;
        }
    }
}

/// Must be invoked when a new output is detected or when an output is disconnected.
/// It'll check for a valid configuration for the set of given outputs and arrange them accordingly.
/// If none exist, it'll create a default configuration.
pub fn setupOutputArrangement(self: *Self) void {
    var outputs: std.ArrayList(*Output) = .empty;
    defer outputs.deinit(owm.alloc);
    var output_iter = self.outputs.iterator(.forward);
    while (output_iter.next()) |it| {
        outputs.append(owm.alloc, it) catch unreachable;
    }

    if (outputs.items.len == 0) { // No outputs to be processed
        return;
    }

    // Compute the ID of the arrangement made out of the currently available displays
    const compareOutputs = struct {
        fn compare(_: void, lhs: *Output, rhs: *Output) bool {
            return std.mem.order(u8, lhs.id, rhs.id) == .lt;
        }
    }.compare;
    std.mem.sort(*Output, outputs.items, {}, compareOutputs);
    var ids = owm.alloc.alloc([]const u8, outputs.items.len) catch unreachable;
    defer owm.alloc.free(ids);
    for (outputs.items, 0..) |output, idx| {
        ids[idx] = output.id;
    }
    const arrangement_id = std.mem.join(owm.alloc, ":", ids) catch unreachable;

    log.infof("OutputManager: Settings up output arrangement for outputs '{s}'", .{arrangement_id});

    var arrangement = owm.config.output.getArrangement(arrangement_id) catch |err| {
        if (err != error.FileDoesNotExist) {
            log.errf("OutputManager: Error determining the arrangement settings for id '{s}'", .{arrangement_id});
            return;
        }
        var arrangement: owm.config.output.Arrangement = .init(owm.alloc);
        defer arrangement.deinit();
        for (outputs.items) |output| {
            arrangement.put(
                output.id,
                owm.config.output.DisplaySettings{
                    .width = output.area.width,
                    .height = output.area.height,
                    .x = output.area.x,
                    .y = output.area.y,
                    .refresh = output.getRefresh(),
                    .enabled = output.wlr_output.enabled,
                },
            ) catch unreachable;
        }
        owm.config.output.storeArrangement(arrangement_id, arrangement);
        return;
    };

    defer owm.config.output.freeArrangement(&arrangement);

    log.infof("OutputManager: Output arrangement found for outputs '{s}', setting up displays according to it", .{arrangement_id});
    for (outputs.items) |output| {
        log.debugf("OutputManager: Setting display settings for output '{s}'", .{output.id});
        const display_settings = arrangement.get(output.id).?;

        if (!display_settings.enabled) {
            log.infof("OutputManager: Disabling output {s}", .{output.id});
            output.disableOutput() catch |err| {
                log.errf("OutputManager: Failed to disable output {}", .{err});
            };
            continue;
        }

        log.infof(
            "OutputManager: Setting output {s} to pos ({}, {}) mode {}x{} {}Hz",
            .{
                output.id,
                display_settings.x,
                display_settings.y,
                display_settings.width,
                display_settings.height,
                display_settings.refresh,
            },
        );

        output.setModeAndPos(
            display_settings.x,
            display_settings.y,
            Output.Mode{
                .width = display_settings.width,
                .height = display_settings.height,
                .refresh = display_settings.refresh,
            },
        ) catch |err| {
            log.errf("OutputManager: Failed to set mode and pos for output {s}: {}", .{ output.id, err });
            continue;
        };
    }
}
