## Setup

1. Install dependencies
```bash
sudo pacman -S wayland wayland-protocols pixman libxkbcommon libinput
```
2. Install wlroots, see [the offical repository](https://gitlab.freedesktop.org/wlroots/wlroots/) on how to install it.

## Run

While in a compositor or tty session:

```bash
zig build -Doptimize=ReleaseFast run
```

## Commands

Commands:
- Alt + Esc: Terminate
- Alt + t: Open ghostty terminal emulator
- Alt + f: Open cosmic-files
- Alt + b: Launch brave browser
- Alt + m: Maximize window
- Alt + F1: "Alt Tab"

Modify the keybinds in `handleKeybind` found in `server.zig`.

## Logs

Logs can be found in `$HOME/.local/share/owm/logs`.

## Configs

Runnig generates the default config if not present.

Config can be found in `$HOME/.config/owm`. For now there is only a JSON file to define how the displays are configured. If a new combination of monitors are present, it'll
add the default configuration for the monitors in the config file.
