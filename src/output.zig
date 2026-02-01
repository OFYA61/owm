const posix = @import("std").posix;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("owm.zig");

var OUTPUT_COUNTER: usize = 0;
pub const OwmOutput = struct {
    id: usize,
    server: *owm.Server,
    wlr_output: *wlr.Output,
    geom: wlr.Box,

    frame_listener: wl.Listener(*wlr.Output) = .init(frameCallback),
    request_state_listener: wl.Listener(*wlr.Output.event.RequestState) = .init(requestStateCallback),
    destroy_listener: wl.Listener(*wlr.Output) = .init(destroyCallback),

    pub fn create(server: *owm.Server, wlr_output: *wlr.Output) anyerror!void {
        const owm_output = try owm.allocator.create(OwmOutput);
        errdefer owm.allocator.destroy(owm_output);

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

        OUTPUT_COUNTER += 1;
        owm_output.* = .{
            .id = OUTPUT_COUNTER,
            .server = server,
            .wlr_output = wlr_output,
            .geom = geom,
        };

        wlr_output.events.frame.add(&owm_output.frame_listener);
        wlr_output.events.request_state.add(&owm_output.request_state_listener);
        wlr_output.events.destroy.add(&owm_output.destroy_listener);

        try server.outputs.append(owm.allocator, owm_output);
    }

    pub fn getGeom(self: *OwmOutput) wlr.Box {
        return self.geom;
    }

    /// Called every time when an output is ready to display a farme, generally at the refresh rate
    fn frameCallback(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const output: *OwmOutput = @fieldParentPtr("frame_listener", listener);
        const scene_output = output.server.wlr_scene.getSceneOutput(wlr_output).?;
        // Render the scene if needed and commit the output
        _ = scene_output.commit(null);

        var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
        scene_output.sendFrameDone(&now);
    }

    /// Called when the backend requests a new state for the output. E.g. new mode request when resizing it in Wayland backend
    fn requestStateCallback(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
        const output: *OwmOutput = @fieldParentPtr("request_state_listener", listener);
        _ = output.wlr_output.commitState(event.state);
    }

    fn destroyCallback(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *OwmOutput = @fieldParentPtr("destroy_listener", listener);

        output.frame_listener.link.remove();
        output.request_state_listener.link.remove();
        output.destroy_listener.link.remove();

        var index: usize = undefined;
        for (output.server.outputs.items, 0..) |o, idx| {
            if (o.id == output.id) {
                index = idx;
                break;
            }
        }
        _ = output.server.outputs.orderedRemove(index);
        owm.allocator.destroy(output);
    }
};
