## Setup

1. Install `zig` version `0.16`
2. Install dependencies
```bash
sudo pacman -S wayland wayland-protocols pixman libxkbcommon libinput
```
3. Install wlroots `0.20`, see [the offical repository](https://gitlab.freedesktop.org/wlroots/wlroots/) on how to install it.

## Run

While in a compositor or tty session:

```bash
zig build -Doptimize=ReleaseFast run
```

## Default Commands

Commands:
- Alt + Esc: Terminate
- Alt + t: Open ghostty terminal emulator
- Alt + f: Open cosmic-files
- Alt + b: Launch brave browser
- Alt + m: Maximize window
- Alt + F1: "Alt Tab"
- Alt + [0-9]: switch workspaces
- Alt + Shift + [0-9]: move windows between workspaces

## Logs

Logs can be found in `$HOME/.local/share/owm/logs`.

## Configs

Runnig generates the default config files as they are requested with their default values.

Config can be found in `$HOME/.config/owm`.

### Dislpay arrangement

For each display combination, a config file in `$HOME/.config/owm/output/` will get generated. The files name will be the serials of all the displays sorted in alphabetical orders
concatinated with `:`. You can modify the position, resolution, and refresh rate. Needs restart to take affect.

Example config
```
SERIAL1 = 1920x1080, 2560x0, 60, 1
SERIAL2 = 2560x1440, 0x0, 144, 1
SERIAL3 = 1920x1080, 0x0, 144, 0
```

```
SERIAL = resolution, position, refresh rate, enabled
```

**TODO**: Write docs around display arrangement

### Keybinds

The keybinds file can be found in `$HOME/.config/owm/keybind/keybinds`. If one doesnt' exist, on startup it'll get created with the default values.
See the default keybinds at `./src/config/Keybinds.zig` to see how to configure keybinds. Sample syntax
```
modifiers, keycode, action, action_args
```

**TODO**: Write docs around keybinds.

### Startup commands

The startup commands can be set in the `$HOME/.config/owm/startup/commands` file. Each line is a separate shell command that can be run. Currently chaining commands with `&&` doesn't work.

## TODO

- [x] Keybindings
- [x] Startup commands
- [ ] Workspaces
    - [x] Create worksapces
    - [x] Move windows between workspaces
    - [x] Cleanup workspaces on output destroy
    - [x] Move destroyed outputs windows to another outputs workspaces
    - [ ] Implement `ext-workspace-v1` protocol
- [ ] Finish implementing `wlr-layer-shell` protocol
    - [ ] Handle status bar positioning on all 4 sides
    - [ ] Launchers and App Menus
    - [ ] Wallpapers (background layer)
    - [ ] Notifications (overlay layer)
    - [ ] Screen Lockers (overlay layer)
- [ ] Custom rendering logic, cuz I want to
