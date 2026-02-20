const std = @import("std");

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");

    // Some of these versions may be out of date with what wlroots implements.
    // This is not a problem in practice though as long it successfully compiles.
    // These versions control Zig code generation and have no effect on anything internal
    // to wlroots. Therefore, the only thing that can happen due to a version being too
    // old is that tinywl fails to compile.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwp_tablet_manager_v2", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");

    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // We need to ensure the wlroots include path obtained from pkg-config is
    // exposed to the wlroots module for @cImport() to work. This seems to be
    // the best way to do so with the current std.Build API.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.19", .{});

    const logly = b.dependency("logly", .{
        .target = target,
        .optimize = optimize,
    });

    const owm_exe = b.addExecutable(.{
        .name = "owm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const prefix = switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe => "release-safe",
        .ReleaseFast => "release-fast",
        .ReleaseSmall => "release-small",
    };
    std.log.info("{s}", .{prefix});

    owm_exe.linkLibC();

    owm_exe.root_module.addImport("wayland", wayland);
    owm_exe.root_module.addImport("xkbcommon", xkbcommon);
    owm_exe.root_module.addImport("wlroots", wlroots);
    owm_exe.root_module.addImport("pixman", pixman);
    owm_exe.root_module.addImport("logly", logly.module("logly"));

    owm_exe.linkSystemLibrary("wayland-server");
    owm_exe.linkSystemLibrary("xkbcommon");
    owm_exe.linkSystemLibrary("pixman-1");

    const owm_install = b.addInstallArtifact(
        owm_exe,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = prefix,
                },
            },
        },
    );
    b.default_step.dependOn(&owm_install.step);

    const run_cmd = b.addRunArtifact(owm_exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
