const std = @import("std");
const builtin = @import("builtin");

const zigmkay_build = @import("zigmkay");
pub const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub const FlashSteps = zigmkay_build.FlashSteps;

/// Adds the `flash`, `flash_pt` and `flash_mount` steps and the
/// `-Dflash-mount` option for `firmware_uf2`. `firmware_dep` is this package
/// (zigmkay_firmware) as a dependency of the calling package:
///     const firmware_dep = b.dependency("zigmkay_firmware", .{});
///     _ = @import("zigmkay_firmware").addFlashSteps(b, firmware_dep, firmware_uf2);
pub fn addFlashSteps(b: *std.Build, firmware_dep: *std.Build.Dependency, firmware_uf2: std.Build.LazyPath) FlashSteps {
    const zigmkay_dep = firmware_dep.builder.dependency("zigmkay", .{});
    return zigmkay_build.addFlashSteps(b, zigmkay_dep, firmware_uf2);
}

pub fn build(b: *std.Build) void {
    const zigmkay_mod = b.addModule("zigmkay", .{
        .root_source_file = .{
            .src_path = .{ .owner = b, .sub_path = "zigmkay/src/root.zig" },
        },
    });

    const test_run_step = b.step("test", "Run unit tests");
    zigmkay_build.add_test_steps(b, zigmkay_mod, test_run_step, "zigmkay/tests");

    if (builtin.os.tag == .macos) {
        const zigmkay_dep = b.dependency("zigmkay", .{});
        const run_rawhid_monitor = b.addRunArtifact(zigmkay_dep.artifact("rawhid-monitor"));
        const rawhid_monitor_step = b.step("rawhid-monitor", "Observe ZigMkay Raw HID key events");
        rawhid_monitor_step.dependOn(&run_rawhid_monitor.step);
    }
}

