const std = @import("std");

pub const microzig = @import("microzig");
const build_utils = @import("build_utils.zig");

pub const add_test_steps = build_utils.add_test_steps;

/// Usage from a downstream build.zig:
///     const zigmkay_dep = b.dependency("zigmkay", .{});
///     _ = @import("zigmkay").addFlashSteps(b, zigmkay_dep, firmware_uf2);
/// This adds the `flash`, `flash_pt` and `flash_mount` steps (plus
/// `install-udev-rules` on Linux). The single
/// run steps below are for packages that want their own step layout.
pub const FlashSteps = build_utils.FlashSteps;
pub const addFlashSteps = build_utils.addFlashSteps;
pub const addFlash = build_utils.addFlash;
pub const addPicotoolFlash = build_utils.addPicotoolFlash;
pub const addMountFlash = build_utils.addMountFlash;
pub const addUdevRulesInstall = build_utils.addUdevRulesInstall;

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

    build_utils.install_tools(b);
}
