const std = @import("std");
const owm = @import("owm.zig");

var config: Config = undefined;

pub fn init() anyerror!void {
    owm.log.info("Reading config", .{}, @src());
    config = try Config.init();
}

pub fn deinit() void {
    config.output.deinit();
}

pub fn output() OutputConfig {
    return config.output.value;
}

const Config = struct {
    output: std.json.Parsed(OutputConfig),

    pub fn init() anyerror!Config {
        const alloc = std.heap.page_allocator;

        return .{
            .output = try OutputConfig.init(alloc),
        };
    }
};

const OutputConfig = struct {
    arrangements: []Arrangement,

    const Arrangement = struct {
        displays: [][]const u8,
        order: []Order,

        const Order = struct {
            id: []const u8,
            order: u32,
        };
    };

    fn init(alloc: std.mem.Allocator) anyerror!std.json.Parsed(OutputConfig) {
        // TODO: create the file and folder if it doesn't exist
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
            return error.MissingHomeEnvironmentVariable;
        };
        defer alloc.free(home);

        const full_path = try std.fs.path.join(alloc, &.{
            home,
            ".config/owm/output.json",
        });
        defer alloc.free(full_path);

        const file = try std.fs.openFileAbsolute(full_path, .{ .mode = .read_only });
        defer file.close();

        // Let `Parsed.deinit()` handle cleaning this one up
        const file_contents = try file.readToEndAlloc(alloc, try file.getEndPos());

        return std.json.parseFromSlice(
            OutputConfig,
            alloc,
            file_contents,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            owm.log.err("Failed to parse output config: {}", .{err}, @src());
            return err;
        };
    }
};
