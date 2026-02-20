//! Represents a display output in the Wayland compositor.
//! Manages output geometry, frame callbacks, state requests, and destruction events.
pub const Output = @This();

const std = @import("std");
const posix = @import("std").posix;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

id: []u8,
wlr_output: *wlr.Output,
layout_output: *wlr.OutputLayout.Output,
scene_output: *wlr.SceneOutput,
geom: wlr.Box,
link: wl.list.Link = undefined,

frame_listener: wl.Listener(*wlr.Output) = .init(frameCallback),
request_state_listener: wl.Listener(*wlr.Output.event.RequestState) = .init(requestStateCallback),
destroy_listener: wl.Listener(*wlr.Output) = .init(destroyCallback),

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
};
const Anyerror = Error || anyerror;

pub fn create(wlr_output: *wlr.Output) Anyerror!*Output {
    const output = try owm.c_alloc.create(Output);
    errdefer owm.c_alloc.destroy(output);

    if (!wlr_output.initRender(owm.server.wlr_allocator, owm.server.wlr_renderer)) {
        owm.log.err("Failed to initialize render with allocator and renderer on new output");
        return Error.InitRenderer;
    }

    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(true);
    if (!wlr_output.modes.empty()) {
        var modes_iterator = wlr_output.modes.iterator(.forward);
        owm.log.info("The output has the following modes:");
        while (modes_iterator.next()) |mode| {
            owm.log.infof(
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
        owm.log.infof(
            "Output has the preferred mode {}x{} {}Hz",
            .{
                mode.width,
                mode.height,
                @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(mode.refresh)) / 1000))),
            },
        );
        state.setMode(mode);
    }
    if (!wlr_output.commitState(&state)) {
        owm.log.err("Failed to commit state for new output");
        return Error.CommitState;
    }

    const layout_output = owm.server.wlr_output_layout.addAuto(wlr_output) catch {
        return Error.AddOutputLayout;
    };
    const scene_output = owm.server.wlr_scene.createSceneOutput(wlr_output) catch { // Add a viewport for the output to the scene graph.
        return Error.CreateSceneOutput;
    };
    owm.server.wlr_scene_output_layout.addOutput(layout_output, scene_output); // Add the output to the scene output layout. When the layout output is repositioned, the scene output will be repositioned accordingly.

    const id = try std.mem.join(owm.alloc, ":", &[_][]const u8{
        std.mem.span(wlr_output.name),
        std.mem.span(wlr_output.model orelse ""),
        std.mem.span(wlr_output.serial orelse ""),
    });

    const geom = wlr.Box{
        .x = layout_output.x,
        .y = layout_output.y,
        .width = wlr_output.width,
        .height = wlr_output.height,
    };

    output.* = .{
        .id = id,
        .wlr_output = wlr_output,
        .geom = geom,
        .layout_output = layout_output,
        .scene_output = scene_output,
    };

    wlr_output.events.frame.add(&output.frame_listener);
    wlr_output.events.request_state.add(&output.request_state_listener);
    wlr_output.events.destroy.add(&output.destroy_listener);

    owm.server.outputs.append(output);

    return output;
}

pub fn disableOutput(self: *Output) Error!void {
    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(false);
    if (!self.wlr_output.commitState(&state)) {
        owm.log.errf("Failed to commit state for output {s}", .{self.id});
        return Error.CommitState;
    }
    owm.server.wlr_output_layout.remove(self.wlr_output);
}

pub fn setModeAndPos(self: *Output, new_x: i32, new_y: i32, new_mode: Mode) Error!void {
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
        owm.log.errf("The given mode {}x{} {}Hz does not exist", .{ new_mode.width, new_mode.height, new_mode.refresh });
        return Error.ModeDoesNotExist;
    }
    state.setMode(mode.?);
    if (!self.wlr_output.commitState(&state)) {
        owm.log.errf("Failed to commit state for output {s}", .{self.id});
        return Error.CommitState;
    }

    const x = @as(c_int, new_x);
    const y = @as(c_int, new_y);
    self.layout_output = owm.server.wlr_output_layout.add(self.wlr_output, x, y) catch unreachable;
    self.geom = wlr.Box{
        .x = x,
        .y = y,
        .width = self.wlr_output.width,
        .height = self.wlr_output.height,
    };
}

pub fn getRefresh(self: *Output) i32 {
    return @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(self.wlr_output.current_mode.?.refresh)) / 1000)));
}

pub fn isDisplay(self: *Output) bool {
    if (self.wlr_output.current_mode) |_| {
        return true;
    }
    return false;
}

/// Called every time when an output is ready to display a farme, generally at the refresh rate
fn frameCallback(_: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const scene_output = owm.server.wlr_scene.getSceneOutput(wlr_output).?;
    // Render the scene if needed and commit the output
    _ = scene_output.commit(null);

    var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
}

/// Called when the backend requests a new state for the output. E.g. new mode request when resizing it in Wayland backend
fn requestStateCallback(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const output: *Output = @fieldParentPtr("request_state_listener", listener);
    _ = output.wlr_output.commitState(event.state);
    if (owm.server.wlr_backend.isWl() or owm.server.wlr_backend.isX11()) {
        output.geom = .{
            .x = 0,
            .y = 0,
            .width = event.output.width,
            .height = event.output.height,
        };
    }
}

fn destroyCallback(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy_listener", listener);

    var should_terminate_server = true;
    if (output.isDisplay()) {
        should_terminate_server = false;
    }

    output.frame_listener.link.remove();
    output.request_state_listener.link.remove();
    output.destroy_listener.link.remove();

    output.link.remove();

    owm.c_alloc.destroy(output);

    if (should_terminate_server) {
        owm.server.wl_server.terminate();
    }
}
