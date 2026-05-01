const std = @import("std");

const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("root").owm;
const log = owm.log;

const utils = @import("utils.zig");

var KEYBINDS: std.ArrayList(Keybind) = undefined;

const ModifierMask = wlr.Keyboard.ModifierMask;
const Keysym = xkb.Keysym;

const keybind_file_path = "keybind/keybinds";
const default_config =
    \\Alt , 1 , Terminate
    \\Alt , 59 , NextWindow
    \\Alt , 50 , ToggleMaximize
    \\
    \\Alt , 20 , Command , ghostty
    \\Alt , 33 , Command , cosmic-files
    \\Alt , 48 , Command , brave
    \\
    \\Alt , 2 , SwitchWorkspace , 1
    \\Alt , 3 , SwitchWorkspace , 2
    \\Alt , 4 , SwitchWorkspace , 3
    \\Alt , 5 , SwitchWorkspace , 4
    \\Alt , 6 , SwitchWorkspace , 5
    \\Alt , 7 , SwitchWorkspace , 6
    \\Alt , 8 , SwitchWorkspace , 7
    \\Alt , 9 , SwitchWorkspace , 8
    \\Alt , 10 , SwitchWorkspace , 9
    \\Alt , 11 , SwitchWorkspace , 10
    \\
    \\Alt_Shift , 2, MoveWindowToWorkspace, 1
    \\Alt_Shift , 3, MoveWindowToWorkspace, 2
    \\Alt_Shift , 4, MoveWindowToWorkspace, 3
    \\Alt_Shift , 5, MoveWindowToWorkspace, 4
    \\Alt_Shift , 6, MoveWindowToWorkspace, 5
    \\Alt_Shift , 7, MoveWindowToWorkspace, 6
    \\Alt_Shift , 8, MoveWindowToWorkspace, 7
    \\Alt_Shift , 9, MoveWindowToWorkspace, 9
    \\Alt_Shift , 10, MoveWindowToWorkspace, 9
    \\Alt_Shift , 11, MoveWindowToWorkspace, 10
;

pub const Keybind = struct {
    modifiers: ModifierMask,
    key_code: u32,
    action: Action,

    pub const Action = union(enum) {
        /// Maxmize/Unmaximize focused window
        ToggleMaximize,
        /// "Alt Tab" to the next window in the workspace
        NextWindow,

        /// Close the compositor
        Terminate,

        /// Switch to the workspace given it's idx
        SwitchWorkspace: usize,
        /// Move focused window to the workspace given it's idx
        MoveWindowToWorkspace: usize,

        /// Shell command to run
        Command: [:0]const u8,
    };

    pub fn fromConfigStr(raw_config_str: []const u8) utils.ParseError!Keybind {
        var config_str = utils.removeWhiteSpaces(raw_config_str);
        defer config_str.deinit(owm.alloc);

        var keybind_tokenizer: utils.Tokenizer = .create(config_str.items, ',');

        var modifiers: ModifierMask = .{};
        const modifier_token = keybind_tokenizer.next() orelse {
            log.err("Config: Invalid keybind config");
            return utils.ParseError.InvalidFormat;
        };
        if (modifier_token.len > 0) {
            var modifier_tokenizer: utils.Tokenizer = .create(modifier_token, '_');
            while (modifier_tokenizer.next()) |token| {
                if (std.mem.eql(u8, token, "Shift")) {
                    modifiers.shift = true;
                } else if (std.mem.eql(u8, token, "Alt")) {
                    modifiers.alt = true;
                } else if (std.mem.eql(u8, token, "Super")) {
                    modifiers.logo = true;
                } else {
                    log.errf("Config: unknown modifier for keybind '{s}'\n", .{token});
                    return utils.ParseError.InvalidModifier;
                }
            }
        }

        const key_token = keybind_tokenizer.next() orelse {
            log.err("Config: Invalid keybind config, no key code provided");
            return utils.ParseError.InvalidFormat;
        };
        if (key_token.len == 0) {
            log.err("Config: Invalid keybind config, no key code provided");
            return utils.ParseError.InvalidFormat;
        }
        const key_code = std.fmt.parseInt(u32, key_token, 10) catch {
            log.errf(
                "Config: Invalid keybind config, key code value must be a 0+ number, but got {s}",
                .{key_token},
            );
            return utils.ParseError.InvalidFormat;
        };

        const action_type_token = keybind_tokenizer.next() orelse {
            log.err("Config: Invalid keybind config, no action type provided");
            return error.InvalidFormat;
        };
        var action: Action = undefined;
        if (std.mem.eql(u8, action_type_token, "ToggleMaximize")) {
            action = .ToggleMaximize;
        } else if (std.mem.eql(u8, action_type_token, "NextWindow")) {
            action = .NextWindow;
        } else if (std.mem.eql(u8, action_type_token, "Terminate")) {
            action = .Terminate;
        } else {
            const action_param_token = keybind_tokenizer.next() orelse {
                log.errf("Config: Invalid keybind config, no action parameters provided for {s}", .{action_type_token});
                return error.InvalidFormat;
            };
            if (std.mem.eql(u8, action_type_token, "SwitchWorkspace")) {
                const idx = std.fmt.parseInt(usize, action_param_token, 10) catch {
                    log.errf(
                        "Config: Invalid keybind config, SwitchWorkspace expects a positive integer non-zero, but got {s}",
                        .{action_param_token},
                    );
                    return utils.ParseError.InvalidFormat;
                };
                if (idx <= 0) {
                    log.errf(
                        "Config: Invalid keybind config, SwitchWorkspace expects a positive integer non-zero, but got {s}",
                        .{action_param_token},
                    );
                    return utils.ParseError.InvalidFormat;
                }
                action = .{ .SwitchWorkspace = idx };
            } else if (std.mem.eql(u8, action_type_token, "Command")) {
                const command = owm.alloc.dupeZ(u8, action_param_token) catch unreachable;
                action = .{ .Command = command };
            } else if (std.mem.eql(u8, action_type_token, "MoveWindowToWorkspace")) {
                const idx = std.fmt.parseInt(usize, action_param_token, 10) catch {
                    log.errf(
                        "Config: Invalid keybind config, MoveWindowToWorkspace expects a positive integer, but got {s}",
                        .{action_param_token},
                    );
                    return utils.ParseError.InvalidFormat;
                };
                if (idx <= 0) {
                    log.errf(
                        "Config: Invalid keybind config, MoveWindowToWorkspace expects a positive integer non-zero, but got {s}",
                        .{action_param_token},
                    );
                    return utils.ParseError.InvalidFormat;
                }
                action = .{ .MoveWindowToWorkspace = idx };
            } else {
                log.errf("Config: Invalid keybind config, unknown action type {s}", .{action_type_token});
            }
        }

        return Keybind{
            .modifiers = modifiers,
            .key_code = key_code,
            .action = action,
        };
    }
};

pub fn init() !void {
    KEYBINDS = .empty;

    _ = try utils.ensureConfigFileExists(default_config, keybind_file_path);
    const config_raw = try utils.loadRaw(keybind_file_path);
    defer owm.alloc.free(config_raw);

    var config_tokenizer: utils.Tokenizer = .create(config_raw, '\n');

    while (config_tokenizer.next()) |token| {
        if (token.len == 0) {
            continue;
        }

        if (Keybind.fromConfigStr(token)) |keybind| {
            KEYBINDS.append(owm.alloc, keybind) catch unreachable;
        } else |_| {
            log.errf("Config: Failed to parse keybind config {s}", .{token});
        }
    }

    log.info("Config: Keybindings:");
    // TODO: pretify the modifier printing
    for (KEYBINDS.items) |*keybind| {
        switch (keybind.action) {
            .Terminate => {
                log.infof("Config:   {} {} Terminate", .{ keybind.modifiers, keybind.key_code });
            },
            .NextWindow => {
                log.infof("Config:   {} {} NextWindow", .{ keybind.modifiers, keybind.key_code });
            },
            .SwitchWorkspace => |idx| {
                log.infof("Config:   {} {} SwitchWorkspace {}", .{ keybind.modifiers, keybind.key_code, idx });
            },
            .MoveWindowToWorkspace => |idx| {
                log.infof("Config:   {} {} MoveWindowToWorkspace {}", .{ keybind.modifiers, keybind.key_code, idx });
            },
            .Command => |command| {
                log.infof("Config:   {} {} Command '{s}'", .{ keybind.modifiers, keybind.key_code, command });
            },
            .ToggleMaximize => {
                log.infof("Config:   {} {} ToggleMaximize", .{ keybind.modifiers, keybind.key_code });
            },
        }
    }
}

pub fn deinit() void {
    KEYBINDS.deinit(owm.alloc);
}

pub fn getKeybind(modifiers: ModifierMask, key_code: u32) ?*Keybind {
    for (KEYBINDS.items) |*keybind| {
        if (keybind.modifiers == modifiers and keybind.key_code == key_code) {
            return keybind;
        }
    }
    return null;
}
