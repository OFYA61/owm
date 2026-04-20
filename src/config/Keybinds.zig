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

pub const Keybind = struct {
    modifiers: ModifierMask,
    keysym: Keysym,
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

        /// Shell command to run
        Command: [:0]const u8,
    };

    pub fn fromConfigStr(raw_config_str: []const u8) error{ InvalidFormat, InvalidModifier }!Keybind {
        var config_str: std.ArrayList(u8) = .empty;
        defer config_str.deinit(owm.alloc);

        for (raw_config_str) |c| {
            switch (c) {
                ' ', '\t', '\n', '\r' => continue,
                else => config_str.append(owm.alloc, c) catch unreachable,
            }
        }

        var keybind_tokenizer: utils.Tokenizer = .create(&config_str, ',');

        var modifiers: ModifierMask = .{};
        const modifier_token = keybind_tokenizer.next() orelse {
            log.err("Config: Invalid keybind config");
            return error.InvalidFormat;
        };
        if (modifier_token.len > 0) {
            var modifier_stream = std.ArrayList(u8).initCapacity(owm.alloc, modifier_token.len) catch unreachable;
            defer modifier_stream.deinit(owm.alloc);
            modifier_stream.appendSlice(owm.alloc, modifier_token) catch unreachable;

            var modifier_tokenizer: utils.Tokenizer = .create(&modifier_stream, '_');
            while (modifier_tokenizer.next()) |token| {
                if (std.mem.eql(u8, token, "Shift")) {
                    modifiers.shift = true;
                } else if (std.mem.eql(u8, token, "Alt")) {
                    modifiers.alt = true;
                } else if (std.mem.eql(u8, token, "Super")) {
                    modifiers.logo = true;
                } else {
                    log.errf("Config: unknown modifier for keybind '{s}'\n", .{token});
                    return error.InvalidModifier;
                }
            }
        }

        const key_token = keybind_tokenizer.next() orelse {
            log.err("Config: Invalid keybind config, no key provided");
            return error.InvalidFormat;
        };
        if (key_token.len == 0) {
            log.err("Config: Invalid keybind config, no key provided");
            return error.InvalidFormat;
        }
        const key_name = owm.alloc.dupeZ(u8, key_token) catch unreachable;
        const keysym = Keysym.fromName(key_name, .case_insensitive);
        owm.alloc.free(key_name);

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
                    return error.InvalidFormat;
                };
                if (idx <= 0) {
                    log.errf(
                        "Config: Invalid keybind config, SwitchWorkspace expects a positive integer non-zero, but got {s}",
                        .{action_param_token},
                    );
                    return error.InvalidFormat;
                }
                action = .{ .SwitchWorkspace = idx };
            } else if (std.mem.eql(u8, action_type_token, "Command")) {
                const command = owm.alloc.dupeZ(u8, action_param_token) catch unreachable;
                action = .{ .Command = command };
            } else {
                log.errf("Config: Invalid keybind config, unknown action type {s}", .{action_type_token});
            }
        }

        return Keybind{
            .modifiers = modifiers,
            .keysym = keysym,
            .action = action,
        };
    }
};

pub fn init() !void {
    KEYBINDS = .empty;

    try utils.ensureConfigFileExists([]u8, "", keybind_file_path);
    const config_raw = try utils.loadRaw(keybind_file_path);
    defer owm.alloc.free(config_raw);

    var config_raw_stream = std.ArrayList(u8).initCapacity(owm.alloc, config_raw.len) catch unreachable;
    defer config_raw_stream.deinit(owm.alloc);
    config_raw_stream.appendSlice(owm.alloc, config_raw) catch unreachable;
    var config_tokenizer: utils.Tokenizer = .create(&config_raw_stream, '\n');

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
}

pub fn deinit() void {
    KEYBINDS.deinit(owm.alloc);
}

pub fn getKeybind(modifiers: ModifierMask, keysym: Keysym) ?*Keybind {
    for (KEYBINDS.items) |*keybind| {
        if (keybind.modifiers == modifiers and keybind.keysym == keysym) {
            return keybind;
        }
    }
    return null;
}
