```bash
zig build run
```

## Commands

Commands:
- Alt + Esc: Terminate
- Alt + t: Open ghostty terminal emulator
- Alt + f: Open cosmic-files
- Alt + b: Launch brave browser
- Alt + m: Maximize window

Modify the keybinds in `handleKeybind` found in `server.zig`.

## Logs

Logs can be found in `$HOME/.local/share/owm/logs`.

## Configs

Runnig generates the default config if not present.

Config can be found in `$HOME/.config/owm`. For now there is only a JSON file to define how the displays are configured. If a new combination of monitors are present, it'll
add the default configuration for the monitors in the config file.
