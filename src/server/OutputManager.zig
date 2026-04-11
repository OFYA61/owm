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
        log.errf("Failed to allocate new output {}", .{err});
        wlr_output.destroy();
        return;
    };

    self.outputs.append(new_output);

    if (!new_output.isDisplay()) {
        return;
    }

    owm.config.Output.storeDisplay(new_output.id, new_output.getModel());

    var outputs: std.ArrayList(*Output) = .empty;
    defer outputs.deinit(owm.alloc);
    var output_iter = self.outputs.iterator(.forward);
    while (output_iter.next()) |it| {
        outputs.append(owm.alloc, it) catch unreachable;
    }

    const compareOutputs = struct {
        fn compare(_: void, lhs: *Output, rhs: *Output) bool {
            return std.mem.order(u8, lhs.id, rhs.id) == .lt;
        }
    }.compare;
    std.mem.sort(*Output, outputs.items, {}, compareOutputs);
    var ids = owm.alloc.alloc([]const u8, outputs.items.len) catch unreachable;
    for (outputs.items, 0..) |output, idx| {
        ids[idx] = output.id;
    }
    const arrangement_id = std.mem.join(owm.alloc, ":", ids) catch unreachable;
    _ = arrangement_id;

    if (owm.config.getOutputOld().findArrangementForOutputs(&outputs)) |*arrangement| {
        log.info("Output arrangement found, setting up displays according to it");

        for (arrangement.displays.items) |*display| {
            var output_to_modify: ?*Output = null;
            for (outputs.items) |output| {
                if (std.mem.eql(u8, output.id, display.id)) {
                    output_to_modify = output;
                }
            }

            if (!display.active) {
                log.infof("Disabling output {s}", .{display.id});
                output_to_modify.?.disableOutput() catch |err| {
                    log.errf("Failed to disable output {}", .{err});
                };
                continue;
            }

            log.infof(
                "Setting output {s} to pos ({}, {}) mode {}x{} {}Hz",
                .{ display.id, display.x, display.y, display.width, display.height, display.refresh },
            );

            output_to_modify.?.setModeAndPos(
                display.x,
                display.y,
                Output.Mode{
                    .width = display.width,
                    .height = display.height,
                    .refresh = display.refresh,
                },
            ) catch |err| {
                log.errf("Failed to set mode and pos for output {s}: {}", .{ display.id, err });
                continue;
            };
        }
    } else {
        var displays = std.ArrayList(owm.config.OutputConfigOld.Arrangement.Display).initCapacity(owm.alloc, outputs.items.len) catch {
            log.err("Failed to initialize memory for new arrangement");
            return;
        };

        for (outputs.items) |output| {
            displays.append(owm.alloc, owm.config.OutputConfigOld.Arrangement.Display{
                .id = output.id,
                .width = output.area.width,
                .height = output.area.height,
                .refresh = output.getRefresh(),
                .x = output.area.x,
                .y = output.area.y,
                .active = output.wlr_output.enabled,
            }) catch {
                log.err("Failed to append display definition");
                displays.deinit(owm.alloc);
                return;
            };
        }
        const new_arrangement = owm.config.OutputConfigOld.Arrangement{ .displays = displays };
        owm.config.getOutputOld().addNewArrangement(new_arrangement) catch {
            displays.deinit(owm.alloc);
            return;
        };
    }
}
