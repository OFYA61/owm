const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("owm.zig");

/// Represents a keyboard input device in the Wayland compositor.
/// Manages keyboard events, keybindings, and XKB keymap handling.
pub const Keyboard = struct {
    /// Reference to the server instance that owns this keyboard
    _server: *owm.Server,
    /// Reference to the wlroots input device object
    _wlr_device: *wlr.InputDevice,

    /// Listener for keyboard modifier key changes (Ctrl, Alt, Shift, etc.)
    _modifiers_listener: wl.Listener(*wlr.Keyboard) = .init(modifiersCallback),
    /// Listener for individual key press/release events
    _key_listener: wl.Listener(*wlr.Keyboard.event.Key) = .init(keyCallback),
    /// Listener for keyboard device destruction events
    _destroy_listener: wl.Listener(*wlr.InputDevice) = .init(destroyCallback),

    pub fn create(server: *owm.Server, device: *wlr.InputDevice) anyerror!*Keyboard {
        const keyboard = try owm.allocator.create(Keyboard);
        errdefer owm.allocator.destroy(keyboard);

        keyboard.* = .{ ._server = server, ._wlr_device = device };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        const wlr_keyboard = device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.setRepeatInfo(25, 300);

        wlr_keyboard.events.modifiers.add(&keyboard._modifiers_listener);
        wlr_keyboard.events.key.add(&keyboard._key_listener);
        device.events.destroy.add(&keyboard._destroy_listener);

        server.wlr_seat.setKeyboard(wlr_keyboard);

        return keyboard;
    }

    pub fn deinit(self: *Keyboard) void {
        self._modifiers_listener.link.remove();
        self._key_listener.link.remove();
        self._destroy_listener.link.remove();

        owm.allocator.destroy(self);
    }
};

fn modifiersCallback(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
    const keyboard: *Keyboard = @fieldParentPtr("_modifiers_listener", listener);
    keyboard._server.wlr_seat.setKeyboard(wlr_keyboard);
    keyboard._server.wlr_seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
}

fn keyCallback(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const keyboard: *Keyboard = @fieldParentPtr("_key_listener", listener);
    const wlr_keyboard = keyboard._wlr_device.toKeyboard();

    // Translate libinput keycode to xkbcommon
    const keycode = event.keycode + 8;

    var handled = false;
    if (wlr_keyboard.getModifiers().alt and event.state == .pressed) {
        for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
            if (keyboard._server.handleKeybind(sym)) {
                handled = true;
                break;
            }
        }
    }

    if (!handled) {
        keyboard._server.wlr_seat.setKeyboard(wlr_keyboard);
        keyboard._server.wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
    }
}

fn destroyCallback(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const keyboard: *Keyboard = @fieldParentPtr("_destroy_listener", listener);
    keyboard.deinit();
}
