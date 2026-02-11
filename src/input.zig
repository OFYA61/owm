const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("owm.zig");

/// Represents a keyboard input device in the Wayland compositor.
/// Manages keyboard events, keybindings, and XKB keymap handling.
pub const Keyboard = struct {
    server: *owm.Server,
    wlr_device: *wlr.InputDevice,

    modifiers_listener: wl.Listener(*wlr.Keyboard) = .init(modifiersCallback),
    key_listener: wl.Listener(*wlr.Keyboard.event.Key) = .init(keyCallback),
    destroy_listener: wl.Listener(*wlr.InputDevice) = .init(destroyCallback),

    pub fn create(server: *owm.Server, device: *wlr.InputDevice) anyerror!*Keyboard {
        const keyboard = try owm.c_alloc.create(Keyboard);
        errdefer owm.c_alloc.destroy(keyboard);

        keyboard.* = .{ .server = server, .wlr_device = device };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        const wlr_keyboard = device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.setRepeatInfo(25, 300);

        wlr_keyboard.events.modifiers.add(&keyboard.modifiers_listener);
        wlr_keyboard.events.key.add(&keyboard.key_listener);
        device.events.destroy.add(&keyboard.destroy_listener);

        server.wlr_seat.setKeyboard(wlr_keyboard);

        return keyboard;
    }

    pub fn deinit(self: *Keyboard) void {
        self.modifiers_listener.link.remove();
        self.key_listener.link.remove();
        self.destroy_listener.link.remove();

        owm.c_alloc.destroy(self);
    }
};

fn modifiersCallback(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
    const keyboard: *Keyboard = @fieldParentPtr("modifiers_listener", listener);
    keyboard.server.wlr_seat.setKeyboard(wlr_keyboard);
    keyboard.server.wlr_seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
}

fn keyCallback(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const keyboard: *Keyboard = @fieldParentPtr("key_listener", listener);
    const wlr_keyboard = keyboard.wlr_device.toKeyboard();

    // Translate libinput keycode to xkbcommon
    const keycode = event.keycode + 8;

    var handled = false;
    if (wlr_keyboard.getModifiers().alt and event.state == .pressed) {
        for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
            if (keyboard.server.handleKeybind(sym)) {
                handled = true;
                break;
            }
        }
    }

    if (!handled) {
        keyboard.server.wlr_seat.setKeyboard(wlr_keyboard);
        keyboard.server.wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
    }
}

fn destroyCallback(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const keyboard: *Keyboard = @fieldParentPtr("destroy_listener", listener);
    keyboard.deinit();
}
