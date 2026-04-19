const std = @import("std");

const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("root").owm;
const log = owm.log;

const utils = @import("utils.zig");

var KEYBINDS: std.ArrayList(Keybind) = undefined;

pub const Keybind = struct {
    modifiers: wlr.Keyboard.ModifierMask,
    keysym: xkb.Keysym,
    action: Action,

    pub const Action = union(enum) {
        /// Maxmize/Unmaximize focused window
        ToggleMaximize,
        /// "Alt Tab" to the next window in the workspace
        NextWindow,

        /// Close the compositor
        Terminate,

        /// Switch to the workspace given it's idx
        SwithWorkspace: usize,

        /// Shell command to run
        Command: [:0]const u8,
    };
};

pub fn init() !void {
    KEYBINDS = .empty;

    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("Escape", xkb.Keysym.Flags.case_insensitive),
        .action = .Terminate,
    }) catch unreachable;

    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("t", xkb.Keysym.Flags.case_insensitive),
        .action = .{ .Command = "ghostty" },
    }) catch unreachable;
    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("f", xkb.Keysym.Flags.case_insensitive),
        .action = .{ .Command = "cosmic-files" },
    }) catch unreachable;
    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("b", xkb.Keysym.Flags.case_insensitive),
        .action = .{ .Command = "brave" },
    }) catch unreachable;

    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("1", xkb.Keysym.Flags.case_insensitive),
        .action = .{ .SwithWorkspace = 1 },
    }) catch unreachable;
    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("2", xkb.Keysym.Flags.case_insensitive),
        .action = .{ .SwithWorkspace = 2 },
    }) catch unreachable;
    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("3", xkb.Keysym.Flags.case_insensitive),
        .action = .{ .SwithWorkspace = 3 },
    }) catch unreachable;

    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("m", xkb.Keysym.Flags.case_insensitive),
        .action = .ToggleMaximize,
    }) catch unreachable;

    KEYBINDS.append(owm.alloc, Keybind{
        .modifiers = .{ .alt = true },
        .keysym = xkb.Keysym.fromName("F1", xkb.Keysym.Flags.case_insensitive),
        .action = .ToggleMaximize,
    }) catch unreachable;
}

pub fn getKeybind(modifiers: wlr.Keyboard.ModifierMask, keysym: xkb.Keysym) ?*Keybind {
    for (KEYBINDS.items) |*keybind| {
        if (keybind.modifiers == modifiers and keybind.keysym == keysym) {
            return keybind;
        }
    }
    return null;
}
