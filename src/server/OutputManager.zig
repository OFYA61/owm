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
}

pub fn deinit(self: *Self) void {
    log.debug("OutputManager: Cleaning up");
    self.new_output_listener.link.remove();
}

pub inline fn getOutputBox(self: *Self, output: *Output) wlr.Box {
    var box: wlr.Box = undefined;
    self.wlr_output_layout.getBox(output.wlr_output, &box);
    return box;
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

    if (owm.config.output.getArrangement(arrangement_id)) |arrangement| {
        defer arrangement.deinit();
        log.infof("OutputManager: Output arrangement found for outputs '{s}', setting up displays according to it", .{arrangement_id});
        for (outputs.items) |output| {
            const display_settings = arrangement.value.map.get(output.id).?;

            if (!display_settings.active) {
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
    } else {
        var arrangement = owm.config.output.Arrangement{};
        defer arrangement.deinit(owm.alloc);
        for (outputs.items) |output| {
            arrangement.map.put(
                owm.alloc,
                output.id,
                owm.config.output.DisplayArrangementSettings{
                    .width = output.area.width,
                    .height = output.area.height,
                    .refresh = output.getRefresh(),
                    .x = output.area.x,
                    .y = output.area.y,
                    .active = output.wlr_output.enabled,
                },
            ) catch unreachable;
        }
        owm.config.output.storeArrangement(arrangement_id, arrangement);
    }

    // Make sure the cursor isn't outside of the outputs viewports by moving it to the center of an active output
    for (outputs.items) |output| {
        if (output.is_active) {
            owm.SERVER.seat.setCursorPos(
                @as(f64, @floatFromInt(output.area.x + @divExact(output.area.width, 2))),
                @as(f64, @floatFromInt(output.area.y + @divExact(output.area.height, 2))),
            );
            break;
        }
    }

    owm.SERVER.scene.handleOrphanedWindows();
}
