const std = @import("std");

const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const owm = @import("root").owm;
const log = owm.log;

const utils = @import("utils.zig");

const startup_commands_file_path = "startup/commands";

pub fn runStartupCommands() void {
    _ = utils.ensureConfigFileExists("", startup_commands_file_path) catch {
        log.errf("Config: failed to ensure that config file '{s}' exists, not running startup commands", .{startup_commands_file_path});
        return;
    };

    const startup_config_raw = utils.loadRaw(startup_commands_file_path) catch {
        log.errf("Config: Failed to read config file '{s}', not running startup commands", .{startup_commands_file_path});
        return;
    };
    defer owm.alloc.free(startup_config_raw);

    var startup_config_tokenizer: utils.Tokenizer = .create(startup_config_raw, '\n');
    while (startup_config_tokenizer.next()) |startup_command_token| {
        if (startup_command_token.len == 0) {
            continue;
        }
        log.infof("Config: Parsing and running startup command: {s}", .{startup_command_token});

        var startup_command_tokenizer: utils.Tokenizer = .create(startup_command_token, ' ');
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(owm.alloc);
        argv.append(owm.alloc, "/bin/sh") catch unreachable;
        argv.append(owm.alloc, "-c") catch unreachable;
        while (startup_command_tokenizer.next()) |arg| {
            argv.append(owm.alloc, arg) catch unreachable;
        }
        owm.process.spawnProcessWithArgs(argv.items);
    }
}
