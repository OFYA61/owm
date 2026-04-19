const std = @import("std");

const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("root").owm;
const log = owm.log;

const utils = @import("utils.zig");

var KEYBINDS: std.ArrayList(Keybind) = undefined;

const ModifierMask = wlr.Keyboard.ModifierMask;

pub const Keybind = struct {
    modifiers: ModifierMask,
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
        SwitchWorkspace: usize,

        /// Shell command to run
        Command: [:0]const u8,
    };

    pub fn fromConfigStr(raw_config_str: []const u8) error{ InvalidFormat, InvalidModifier }!Keybind {
        const Tokenizer = struct {
            const Self = @This();

            stream: *std.ArrayList(u8),
            seperator: u8,
            config_progress: usize = 0,
            finished: bool = false,

            fn create(stream: *std.ArrayList(u8), seperator: u8) Self {
                return .{
                    .stream = stream,
                    .seperator = seperator,
                };
            }

            fn next(self: *Self) ?[]u8 {
                if (self.finished) {
                    return null;
                }
                for (self.stream.items[self.config_progress..], self.config_progress..) |c, i| {
                    if (c != self.seperator) {
                        continue;
                    }

                    const ret_value = self.stream.items[self.config_progress..i];
                    self.config_progress = i + 1;
                    return ret_value;
                }
                self.finished = true;
                return self.stream.items[self.config_progress..];
            }
        };

        var config_str: std.ArrayList(u8) = .empty;
        defer config_str.deinit(owm.alloc);

        for (raw_config_str) |c| {
            switch (c) {
                ' ', '\t', '\n', '\r' => continue,
                else => config_str.append(owm.alloc, c) catch unreachable,
            }
        }

        var keybind_tokenizer: Tokenizer = .create(&config_str, ',');

        var modifiers: ModifierMask = .{};
        const modifier_token = keybind_tokenizer.next() orelse {
            log.err("Config: Invalid keybind config");
            return error.InvalidFormat;
        };
        if (modifier_token.len > 0) {
            var modifier_stream = std.ArrayList(u8).initCapacity(owm.alloc, modifier_token.len) catch unreachable;
            defer modifier_stream.deinit(owm.alloc);
            modifier_stream.appendSlice(owm.alloc, modifier_token) catch unreachable;

            var modifier_tokenizer: Tokenizer = .create(&modifier_stream, '_');
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
        const keysym = xkb.Keysym.fromName(key_name, .case_insensitive);
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
            }
            if (std.mem.eql(u8, action_type_token, "Command")) {
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

    if (Keybind.fromConfigStr("Alt , Escape , Terminate")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}
    if (Keybind.fromConfigStr("Alt , F1 , NextWindow")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}
    if (Keybind.fromConfigStr("Alt , m , ToggleMaximize")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}

    if (Keybind.fromConfigStr("Alt , t , Command , ghostty")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}
    if (Keybind.fromConfigStr("Alt , f , Command , cosmic-files")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}
    if (Keybind.fromConfigStr("Alt , b , Command , brave")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}

    if (Keybind.fromConfigStr("Alt , 1 , SwitchWorkspace , 1")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}
    if (Keybind.fromConfigStr("Alt , 2 , SwitchWorkspace , 2")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}
    if (Keybind.fromConfigStr("Alt , 3 , SwitchWorkspace , 3")) |keybind| {
        KEYBINDS.append(owm.alloc, keybind) catch unreachable;
    } else |_| {}
}

pub fn getKeybind(modifiers: ModifierMask, keysym: xkb.Keysym) ?*Keybind {
    for (KEYBINDS.items) |*keybind| {
        if (keybind.modifiers == modifiers and keybind.keysym == keysym) {
            return keybind;
        }
    }
    return null;
}
