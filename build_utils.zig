const std = @import("std");

pub fn add_test_steps(b: *std.Build, zigmkay_module: *std.Build.Module, test_step: *std.Build.Step, test_dir: []const u8) void {
    const target = b.standardTargetOptions(.{});

    // START: Create test file iterator
    var src_dir = b.root.openDir(b.graph.io, test_dir, .{ .iterate = true }) catch |err|
        std.debug.panic("Failed to open '{s}': {}", .{ test_dir, err });
    defer src_dir.close(b.graph.io);

    b.dependOnDirectoryContents(b.path(test_dir));
    var walker = src_dir.walk(b.allocator) catch |err|
        std.debug.panic("Failed to walk '{s}': {}", .{ test_dir, err });
    defer walker.deinit();
    // END: Create test file iterator

    while (walker.next(b.graph.io) catch |err| std.debug.panic("Failed to iterate '{s}': {}", .{ test_dir, err })) |entry| {
        if (entry.kind == .file and std.mem.indexOf(u8, entry.basename, "test_") != null) {
            const current_test_file_path = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ test_dir, entry.path }) catch unreachable;

            // to ensure your test file is actually being loaded, remove the comments on the following line:
            //std.debug.print("{s}\n", .{current_test_file_path});

            const current_test_file_module = b.createModule(.{
                .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = current_test_file_path } },
                .target = target,
            });
            current_test_file_module.addImport("zigmkay", zigmkay_module);

            const current_test_exe = b.addTest(.{ .root_module = current_test_file_module });
            const current_test_run = b.addRunArtifact(current_test_exe);
            test_step.dependOn(&current_test_run.step);
        }
    }
}

/// Builds and installs the host tools so that dependents can fetch them with
/// `dependency.artifact(...)`: `flash_picotool`, `flash_mount` and, on macOS,
/// `rawhid-monitor`. Also exposes picotool, built from source, as the named
/// lazy path "picotool", and its upstream udev rules as "picotool-udev-rules".
pub fn install_tools(b: *std.Build) void {
    inline for (.{ "flash_picotool", "flash_mount" }) |name| {
        const tool = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/" ++ name ++ ".zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        b.installArtifact(tool);
    }

    const picotool_dep = b.dependency("picotool", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    b.addNamedLazyPath("picotool", picotool_dep.artifact("picotool").getEmittedBin());
    const picotool_src = picotool_dep.builder.dependency("picotool", .{});
    b.addNamedLazyPath("picotool-udev-rules", picotool_src.path("udev/60-picotool.rules"));

    if (b.graph.host.result.os.tag == .macos) {
        const rawhid_monitor = b.addExecutable(.{
            .name = "rawhid-monitor",
            .root_module = b.createModule(.{ .target = b.graph.host }),
        });
        rawhid_monitor.root_module.addCSourceFile(.{
            .file = b.path("tools/rawhid_monitor.c"),
            .flags = &.{"-std=c11"},
        });
        rawhid_monitor.root_module.link_libc = true;
        rawhid_monitor.root_module.linkFramework("IOKit", .{});
        rawhid_monitor.root_module.linkFramework("CoreFoundation", .{});
        b.installArtifact(rawhid_monitor);
    }
}

/// Adds an uncached run step that flashes `firmware_uf2` with picotool: it
/// reports the UF2 hash, waits for a device in BOOTSEL mode, loads and verifies
/// the firmware, and reboots. The UF2 must carry the RP2040 family ID, e.g.
/// `firmware.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } })`.
/// `dependency` is the zigmkay package as a dependency of the calling package.
pub fn addPicotoolFlash(b: *std.Build, dependency: *std.Build.Dependency, firmware_uf2: std.Build.LazyPath) *std.Build.Step.Run {
    const flash_command = b.addRunArtifact(dependency.artifact("flash_picotool"));
    flash_command.addFileArg(dependency.namedLazyPath("picotool"));
    flash_command.addFileArg(firmware_uf2);
    flash_command.has_side_effects = true;
    return flash_command;
}

/// Adds an uncached run step that waits for the RP2 bootloader volume and
/// copies `firmware_uf2` onto it. `mount_point_or_label` is an absolute mount
/// point or a volume label; null means the "RPI-RP2" label.
pub fn addMountFlash(b: *std.Build, dependency: *std.Build.Dependency, firmware_uf2: std.Build.LazyPath, mount_point_or_label: ?[]const u8) *std.Build.Step.Run {
    const flash_command = b.addRunArtifact(dependency.artifact("flash_mount"));
    flash_command.addFileArg(firmware_uf2);
    if (mount_point_or_label) |arg| flash_command.addArg(arg);
    flash_command.has_side_effects = true;
    return flash_command;
}

/// Adds an uncached run step that installs picotool's udev rules to
/// /etc/udev/rules.d with sudo and reloads udev, so picotool can reach the RP2
/// bootloader without root. Linux only.
pub fn addUdevRulesInstall(b: *std.Build, dependency: *std.Build.Dependency) *std.Build.Step.Run {
    const script = "install -m 644 \"$1\" /etc/udev/rules.d/60-picotool.rules && udevadm control --reload-rules && udevadm trigger";
    const install_command = b.addSystemCommand(&.{ "sudo", "sh", "-c", script, "sh" });
    install_command.addFileArg(dependency.namedLazyPath("picotool-udev-rules"));
    install_command.stdio = .inherit;
    install_command.has_side_effects = true;
    return install_command;
}

/// Adds the host's default flash step: mount based on Windows, where picotool
/// needs a WinUSB driver for the bootloader, and on Linux, where picotool needs
/// udev rules for USB access; picotool everywhere else.
pub fn addFlash(b: *std.Build, dependency: *std.Build.Dependency, firmware_uf2: std.Build.LazyPath, mount_point_or_label: ?[]const u8) *std.Build.Step.Run {
    return switch (b.graph.host.result.os.tag) {
        .windows, .linux => addMountFlash(b, dependency, firmware_uf2, mount_point_or_label),
        else => addPicotoolFlash(b, dependency, firmware_uf2),
    };
}

pub const FlashSteps = struct {
    /// Host default: mount based on Windows and Linux, picotool everywhere else.
    flash: *std.Build.Step,
    flash_pt: *std.Build.Step,
    flash_mount: *std.Build.Step,
    /// Only on Linux hosts.
    install_udev_rules: ?*std.Build.Step,
};

/// Adds the `flash`, `flash_pt` and `flash_mount` top level steps (plus
/// `install-udev-rules` on Linux) for
/// `firmware_uf2`, plus the `-Dflash-mount=<path|label>` option, so the calling
/// package must not declare that option itself. The UF2 must carry the RP2040
/// family ID. `dependency` is the zigmkay package as a dependency of the
/// calling package.
pub fn addFlashSteps(b: *std.Build, dependency: *std.Build.Dependency, firmware_uf2: std.Build.LazyPath) FlashSteps {
    const flash_mount = b.option([]const u8, "flash-mount", "Mount point or volume label of the RP2 bootloader (default: RPI-RP2)");

    const flash_step = b.step("flash", "Build and flash the firmware (Windows/Linux: mount based, otherwise picotool)");
    flash_step.dependOn(&addFlash(b, dependency, firmware_uf2, flash_mount).step);

    const flash_pt_step = b.step("flash_pt", "Build and flash the firmware with picotool");
    flash_pt_step.dependOn(&addPicotoolFlash(b, dependency, firmware_uf2).step);

    const flash_mount_step = b.step("flash_mount", "Build and flash the firmware through the mounted RP2 bootloader volume");
    flash_mount_step.dependOn(&addMountFlash(b, dependency, firmware_uf2, flash_mount).step);

    const install_udev_rules_step = if (b.graph.host.result.os.tag == .linux) blk: {
        const step = b.step("install-udev-rules", "Install picotool's udev rules (needs sudo) so flash_pt works without root");
        step.dependOn(&addUdevRulesInstall(b, dependency).step);
        break :blk step;
    } else null;

    return .{
        .flash = flash_step,
        .flash_pt = flash_pt_step,
        .flash_mount = flash_mount_step,
        .install_udev_rules = install_udev_rules_step,
    };
}
