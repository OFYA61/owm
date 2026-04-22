# OWM

A Wayland compositor written in Zig (wlroots-based).

## Build

```bash
zig build -Doptimize=ReleaseFast run  # builds and runs
zig build                            # debug build
```

Entry point: `src/main.zig` → `src/owm.zig`

## Project Structure

- `src/server/` - Server-side Wayland logic (Output, Seat, Keyboard, Scene)
- `src/client/` - Client-side handling (windows, popups, layer surfaces)
- `src/config/` - Config loading and keybinds
- `src/math/` - Math utilities
- `src/log/` - Logging

Each folder has a module file named after it, e.g. the `server` folder has `server.zig`. The root module can be found in `src/owm.zig`, which acts as the root module of the project.
All other modules are accessible through this module.

### Importing something from a module

If you want to import something from the project located in some other module, you would do the following
```zig
const owm = @import("root").owm;
```
then use `owm` to access the desired submodules and their structs/functions.

## Runtime Dependencies

System packages (Arch Linux): `wayland wayland-protocols pixman libxkbcommon libinput`
wlroots 0.20 must be installed from source.
