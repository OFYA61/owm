const std = @import("std");
const posix = @import("std").posix;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

/// Represents a display output in the Wayland compositor.
/// Manages output geometry, frame callbacks, state requests, and destruction events.
pub const Output = struct {
    server: *owm.Server,
    wlr_output: *wlr.Output,
    geom: wlr.Box,
    link: wl.list.Link = undefined,

    frame_listener: wl.Listener(*wlr.Output) = .init(frameCallback),
    request_state_listener: wl.Listener(*wlr.Output.event.RequestState) = .init(requestStateCallback),
    destroy_listener: wl.Listener(*wlr.Output) = .init(destroyCallback),

    pub fn create(server: *owm.Server, wlr_output: *wlr.Output) anyerror!void {
        const owm_output = try owm.allocator.create(Output);
        errdefer owm.allocator.destroy(owm_output);

        if (!wlr_output.initRender(server.wlr_allocator, server.wlr_renderer)) {
            std.log.err("Failed to initialize render with allocator and renderer on new output", .{});
            return;
        }

        var state = wlr.Output.State.init();
        defer state.finish();
        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| {
            std.log.info("Output has the preferred mode {}x{} {}Hz", .{ mode.width, mode.height, mode.refresh });
            state.setMode(mode);
        }
        if (!wlr_output.commitState(&state)) {
            std.log.err("Failed to commit state for new output", .{});
            return;
        }

        // Add the new display to the right of all the other displays
        const layout_output = try server.wlr_output_layout.addAuto(wlr_output);
        const scene_output = try server.wlr_scene.createSceneOutput(wlr_output); // Add a viewport for the output to the scene graph.
        server.wlr_scene_output_layout.addOutput(layout_output, scene_output); // Add the output to the scene output layout. When the layout output is repositioned, the scene output will be repositioned accordingly.

        const geom = wlr.Box{
            .x = layout_output.x,
            .y = layout_output.y,
            .width = wlr_output.width,
            .height = wlr_output.height,
        };

        owm_output.* = .{
            .server = server,
            .wlr_output = wlr_output,
            .geom = geom,
        };

        wlr_output.events.frame.add(&owm_output.frame_listener);
        wlr_output.events.request_state.add(&owm_output.request_state_listener);
        wlr_output.events.destroy.add(&owm_output.destroy_listener);

        server.outputs.append(owm_output);
    }
};

/// Called every time when an output is ready to display a farme, generally at the refresh rate
fn frameCallback(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame_listener", listener);
    const scene_output = output.server.wlr_scene.getSceneOutput(wlr_output).?;
    // Render the scene if needed and commit the output
    _ = scene_output.commit(null);

    var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
}

/// Called when the backend requests a new state for the output. E.g. new mode request when resizing it in Wayland backend
fn requestStateCallback(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    const output: *Output = @fieldParentPtr("request_state_listener", listener);
    _ = output.wlr_output.commitState(event.state);
    if (output.server.wlr_backend.isWl() or output.server.wlr_backend.isX11()) {
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

    output.frame_listener.link.remove();
    output.request_state_listener.link.remove();
    output.destroy_listener.link.remove();

    output.link.remove();

    owm.allocator.destroy(output);
}
