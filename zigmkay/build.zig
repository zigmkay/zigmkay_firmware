const std = @import("std");

pub const microzig = @import("microzig");
const build_utils = @import("build_utils.zig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const zigmkay_mod = b.addModule("zigmkay", .{
        .root_source_file = .{
            .src_path = .{ .owner = b, .sub_path = "src/root.zig" },
        },
    });
    const test_run_step = b.step("test", "Run unit tests");
    build_utils.add_test_steps(b, zigmkay_mod, test_run_step, "tests");

    build_utils.install_picotool_flash(b, "tools/picotool_flash.zig");
}

/// Usage from a downstream build.zig:
///     const zigmkay_dep = b.dependency("zigmkay", .{});
///     const flash = @import("zigmkay").addPicotoolFlash(b, zigmkay_dep, firmware_uf2);
///     b.step("flash", "Flash with picotool").dependOn(&flash.step);
pub const addPicotoolFlash = build_utils.addPicotoolFlash;
