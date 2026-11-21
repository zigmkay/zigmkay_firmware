const std = @import("std");

/// microzig, pinned lazily so host-only builds never fetch it.
/// Pass the `zigmkay` package's own `*std.Build` (for dependents: `zigmkay_dep.builder`).
pub inline fn microzig(zigmkay_builder: *std.Build) ?type {
    return zigmkay_builder.lazyImport(@This(), "microzig");
}
/// This package's manifest: the microzig and picotool pins.
pub const manifest = @import("build.zig.zon");
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

pub fn build(b: *std.Build) void {
    const zigmkay_mod = b.addModule("zigmkay", .{
        .root_source_file = .{
            .src_path = .{ .owner = b, .sub_path = "src/root.zig" },
        },
    });
    const test_run_step = b.step("test", "Run unit tests");
    build_utils.add_test_steps(b, zigmkay_mod, test_run_step, "tests");

    const rawhid_monitor = build_utils.install_tools(b);

    const rawhid_monitor_step = b.step("rawhid-monitor", "macOS: observe ZigMkay Raw HID key events");
    if (rawhid_monitor) |exe| {
        rawhid_monitor_step.dependOn(&b.addRunArtifact(exe).step);
    } else {
        rawhid_monitor_step.dependOn(&b.addFail("rawhid-monitor is only available on macOS").step);
    }
}
