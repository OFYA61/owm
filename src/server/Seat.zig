const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const owm = @import("root").owm;
const log = owm.log;
const math = owm.math;
const Window = owm.client.window.Window;

const Keyboard = @import("Keyboard.zig");

const MIN_CLIENT_WIDTH = 240;
const MIN_CLIENT_HEIGHT = 135;

wlr_seat: *wlr.Seat,
focused_window: ?*Window = null,
new_input_listener: wl.Listener(*wlr.InputDevice) = .init(newInputCallback),
request_set_cursor_listener: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursorCallback),
request_set_selection_listener: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelectionCallback),

wlr_cursor: *wlr.Cursor,
wlr_cursor_manager: *wlr.XcursorManager,
grabbed_window: ?*Window = null,
cursor_mode: enum { passthrough, move, resize } = .passthrough,
grab_x: f64 = 0,
grab_y: f64 = 0,
grab_box: wlr.Box = undefined,
resize_edges: wlr.Edges = .{},
cursor_motion_listener: wl.Listener(*wlr.Pointer.event.Motion) = .init(cursorMotionCallback),
cursor_motion_absolute_listener: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(cursorMotionAbsoluteCallback),
cursor_button_listener: wl.Listener(*wlr.Pointer.event.Button) = .init(cursorButtonCallback),
cursor_axis_listener: wl.Listener(*wlr.Pointer.event.Axis) = .init(cursorAxisCallback),
cursor_frame_listener: wl.Listener(*wlr.Cursor) = .init(cursorFrameCallback),

pub fn create(wl_server: *wl.Server) !Self {
    const wlr_seat = try wlr.Seat.create(wl_server, "seat0"); // Input device seat
    const wlr_cursor = try wlr.Cursor.create(); // Mouse
    const wlr_cursor_manager = try wlr.XcursorManager.create(null, 24); // Sources cursor images

    return .{
        .wlr_seat = wlr_seat,
        .wlr_cursor = wlr_cursor,
        .wlr_cursor_manager = wlr_cursor_manager,
    };
}

pub fn init(self: *Self, wlr_backend: *wlr.Backend, wlr_output_layout: *wlr.OutputLayout) !void {
    wlr_backend.events.new_input.add(&self.new_input_listener);
    self.wlr_seat.events.request_set_cursor.add(&self.request_set_cursor_listener);
    self.wlr_seat.events.request_set_selection.add(&self.request_set_selection_listener);

    self.wlr_cursor.attachOutputLayout(wlr_output_layout);
    try self.wlr_cursor_manager.load(1);
    self.wlr_cursor.events.motion.add(&self.cursor_motion_listener);
    self.wlr_cursor.events.motion_absolute.add(&self.cursor_motion_absolute_listener);
    self.wlr_cursor.events.button.add(&self.cursor_button_listener);
    self.wlr_cursor.events.axis.add(&self.cursor_axis_listener);
    self.wlr_cursor.events.frame.add(&self.cursor_frame_listener);
}

pub fn deinit(self: *Self) void {
    self.new_input_listener.link.remove();
    self.request_set_cursor_listener.link.remove();
    self.request_set_selection_listener.link.remove();
    self.cursor_motion_listener.link.remove();
    self.cursor_motion_absolute_listener.link.remove();
    self.cursor_button_listener.link.remove();
    self.cursor_axis_listener.link.remove();
    self.cursor_frame_listener.link.remove();
}

pub fn getCursorPos(self: *Self) math.Vec2(f64) {
    return .{
        .x = self.wlr_cursor.x,
        .y = self.wlr_cursor.y,
    };
}

pub fn resetCursorMode(self: *Self) void {
    self.cursor_mode = .passthrough;
    self.grabbed_window = null;
}

pub fn focusTopWindow(self: *Self) void {
    if (owm.SERVER.scene.getTopWindowInWorkspace()) |top_window| {
        self.focusWindow(top_window);
    }
}

pub fn focusWindow(self: *Self, new_window: *Window) void {
    if (self.focused_window) |prev_window| {
        if (prev_window == new_window) {
            return;
        }
        prev_window.setFocus(false);
    }

    new_window.setFocus(true);

    const wlr_keyboard = self.wlr_seat.getKeyboard() orelse return;
    self.wlr_seat.keyboardNotifyEnter(
        new_window.getWlrSurface(),
        wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
        &wlr_keyboard.modifiers,
    );
    self.focused_window = new_window;
}

pub fn requestMove(self: *Self, window: *Window) void {
    self.grabbed_window = window;
    self.cursor_mode = .move;
    const window_pos = window.getPos();
    self.grab_x = self.wlr_cursor.x - @as(f64, @floatFromInt(window_pos.x));
    self.grab_y = self.wlr_cursor.y - @as(f64, @floatFromInt(window_pos.y));
}

pub fn requestResize(self: *Self, window: *Window, edges: wlr.Edges) void {
    self.grabbed_window = window;
    self.cursor_mode = .resize;
    self.resize_edges = edges;

    const window_pos = window.getPos();
    const box = window.getGeom();

    const border_x = window_pos.x + box.x + if (edges.right) box.width else 0;
    const border_y = window_pos.y + box.y + if (edges.bottom) box.height else 0;
    self.grab_x = self.wlr_cursor.x - @as(f64, @floatFromInt(border_x));
    self.grab_y = self.wlr_cursor.y - @as(f64, @floatFromInt(border_y));

    self.grab_box = box;
    self.grab_box.x += window_pos.x;
    self.grab_box.y += window_pos.y;
}

pub fn clearFocusIfFocusedWindow(self: *Self, window: *Window) void {
    if (self.focused_window == window) {
        self.focused_window = null;
        self.focusTopWindow();
    }
}

fn processCursorMotion(self: *Self, time: u32) void {
    if (self.cursor_mode == .move) {
        const grabbed_window = self.grabbed_window.?;
        grabbed_window.setPos(
            @as(i32, @intFromFloat(self.wlr_cursor.x - self.grab_x)),
            @as(i32, @intFromFloat(self.wlr_cursor.y - self.grab_y)),
        );
        return;
    } else if (self.cursor_mode == .resize) {
        const grabbed_window = self.grabbed_window.?;
        const border_x = @as(i32, @intFromFloat(self.wlr_cursor.x - self.grab_x));
        const border_y = @as(i32, @intFromFloat(self.wlr_cursor.y - self.grab_y));

        var new_left = self.grab_box.x;
        var new_right = self.grab_box.x + self.grab_box.width;
        var new_top = self.grab_box.y;
        var new_bottom = self.grab_box.y + self.grab_box.height;

        if (self.resize_edges.top) {
            new_top = border_y;
            if (new_top + MIN_CLIENT_HEIGHT >= new_bottom) { // Make sure new_top isn't below new_bottom
                new_top = new_bottom - MIN_CLIENT_HEIGHT;
            }
        } else if (self.resize_edges.bottom) {
            new_bottom = border_y;
            if (new_bottom - MIN_CLIENT_HEIGHT <= new_top) { // Make sure new_bottom isn't above new_top
                new_bottom = new_top + MIN_CLIENT_HEIGHT;
            }
        }

        if (self.resize_edges.left) {
            new_left = border_x;
            if (new_left + MIN_CLIENT_WIDTH >= new_right) { // Make sure new_left isn't right of new_right
                new_left = new_right - MIN_CLIENT_WIDTH;
            }
        } else if (self.resize_edges.right) {
            new_right = border_x;
            if (new_right - MIN_CLIENT_WIDTH <= new_left) { // Make sure new_right isn't left of new_left
                new_right = new_left + MIN_CLIENT_WIDTH;
            }
        }

        const box = grabbed_window.getGeom();
        const new_x = new_left - box.x;
        const new_y = new_top - box.y;
        grabbed_window.setPos(new_x, new_y);

        const new_width: i32 = new_right - new_left;
        const new_height: i32 = new_bottom - new_top;
        grabbed_window.setSize(new_width, new_height);
        return;
    }

    if (owm.SERVER.scene.surfaceAt(self.wlr_cursor.x, self.wlr_cursor.y)) |response| {
        self.wlr_seat.pointerNotifyEnter(response.wlr_surface, response.sx, response.sy);
        self.wlr_seat.pointerNotifyMotion(time, response.sx, response.sy);
    } else {
        self.wlr_cursor.setXcursor(self.wlr_cursor_manager, "default");
        self.wlr_seat.pointerClearFocus();
    }
}

/// Called when a new input device becomes available
fn newInputCallback(listener: *wl.Listener(*wlr.InputDevice), input_device: *wlr.InputDevice) void {
    const self: *Self = @fieldParentPtr("new_input_listener", listener);
    self.wlr_seat.setCapabilities(.{
        .pointer = true,
        .keyboard = true,
    });

    switch (input_device.type) {
        .pointer => {
            self.wlr_cursor.attachInputDevice(input_device);
        },
        .keyboard => {
            _ = Keyboard.create(input_device) catch |err| {
                log.errf("Failed to allocate keyboard: {}", .{err});
                return;
            };
        },
        else => {},
    }
}

/// Called when a client provides a cursor image
fn requestSetCursorCallback(listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor), event: *wlr.Seat.event.RequestSetCursor) void {
    const self: *Self = @fieldParentPtr("request_set_cursor_listener", listener);
    if (self.wlr_seat.pointer_state.focused_client) |client| {
        if (client == event.seat_client) { // Make sure the requesting client is focused
            self.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
        }
    }
}

/// Called when a client want to set the selection, e.g. copies something.
fn requestSetSelectionCallback(listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection), event: *wlr.Seat.event.RequestSetSelection) void {
    const self: *Self = @fieldParentPtr("request_set_selection_listener", listener);
    self.wlr_seat.setSelection(event.source, event.serial);
}

/// Called when pointer emits relative (_delta_) motion events
fn cursorMotionCallback(listener: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
    const self: *Self = @fieldParentPtr("cursor_motion_listener", listener);
    self.wlr_cursor.move(event.device, event.delta_x, event.delta_y);
    self.processCursorMotion(event.time_msec);
}

/// Called when pointer emits an absolute motion event, e.g. on Wayland or X11 backend, pointer enters the window
fn cursorMotionAbsoluteCallback(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
    const self: *Self = @fieldParentPtr("cursor_motion_absolute_listener", listener);
    self.wlr_cursor.warpAbsolute(event.device, event.x, event.y);
    self.processCursorMotion(event.time_msec);
}

fn cursorButtonCallback(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    const self: *Self = @fieldParentPtr("cursor_button_listener", listener);
    _ = self.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    if (event.state == .released) {
        if (self.grabbed_window) |grabbed_window| {
            if (owm.SERVER.outputAtCursor()) |output| {
                grabbed_window.setCurrentOutput(output);
            }
        }
        self.resetCursorMode();
    } else {
        if (owm.SERVER.scene.windowAt(self.wlr_cursor.x, self.wlr_cursor.y)) |result| {
            self.focusWindow(result.window);
        } else if (self.focused_window) |window| {
            window.setFocus(false);
            self.focused_window = null;
            self.wlr_seat.keyboardNotifyClearFocus();
        }
    }
}

fn cursorAxisCallback(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    const self: *Self = @fieldParentPtr("cursor_axis_listener", listener);
    self.wlr_seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
        event.relative_direction,
    );
}

/// Frame events are sent after regular pointer events to group multiple events together.
/// E.g. 2 axis events may hapen at the same time, in which case a farme event won't be sent in between
fn cursorFrameCallback(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const self: *Self = @fieldParentPtr("cursor_frame_listener", listener);
    self.wlr_seat.pointerNotifyFrame();
}
