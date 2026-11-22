const std = @import("std");

pub fn add_test_steps(b: *std.Build, zigmkay_module: *std.Build.Module, test_step: *std.Build.Step, test_dir: []const u8) void {
    const target = b.standardTargetOptions(.{});

    const root_path = b.fmt("{s}/test_all.zig", .{test_dir});

    var src_dir = b.root.openDir(b.graph.io, test_dir, .{ .iterate = true }) catch |err|
        std.debug.panic("Failed to open '{s}': {}", .{ test_dir, err });
    defer src_dir.close(b.graph.io);

    const root_source = src_dir.readFileAlloc(b.graph.io, "test_all.zig", b.allocator, .limited(1024 * 1024)) catch |err|
        std.debug.panic("Failed to read '{s}': {}", .{ root_path, err });

    b.dependOnDirectoryContents(b.path(test_dir));
    var walker = src_dir.walk(b.allocator) catch |err|
        std.debug.panic("Failed to walk '{s}': {}", .{ test_dir, err });
    defer walker.deinit();

    while (walker.next(b.graph.io) catch |err| std.debug.panic("Failed to iterate '{s}': {}", .{ test_dir, err })) |entry| {
        if (entry.kind == .file and std.mem.indexOf(u8, entry.basename, "test_") != null and !std.mem.eql(u8, entry.basename, "test_all.zig")) {
            const normalized = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
            std.mem.replaceScalar(u8, normalized, '\\', '/');
            const needle = b.fmt("@import(\"{s}\")", .{normalized});
            if (std.mem.indexOf(u8, root_source, needle) == null) {
                std.debug.panic("Test file '{s}/{s}' is not imported in '{s}'", .{ test_dir, normalized, root_path });
            }
        }
    }

    const test_module = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = root_path } },
        .target = target,
    });
    test_module.addImport("zigmkay", zigmkay_module);

    const test_exe = b.addTest(.{ .root_module = test_module });
    const test_run = b.addRunArtifact(test_exe);
    test_step.dependOn(&test_run.step);
}

/// Builds and installs the host tools so that dependents can fetch them with
/// `dependency.artifact(...)`: `flash_picotool`, `flash_mount` and, on macOS,
/// `rawhid-monitor`. picotool itself is a lazy dependency, fetched only by
/// builds that configure a picotool step.
pub fn install_tools(b: *std.Build) ?*std.Build.Step.Compile {
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

    if (b.graph.host.result.os.tag == .macos) {
        const rawhid_monitor = b.addExecutable(.{
            .name = "rawhid-monitor",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/rawhid_monitor.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
                .link_libc = true,
            }),
        });
        // The monitor decodes reports with the firmware's own companion definitions.
        rawhid_monitor.root_module.addImport("zigmkay", b.modules.get("zigmkay").?);
        rawhid_monitor.root_module.linkFramework("IOKit", .{});
        rawhid_monitor.root_module.linkFramework("CoreFoundation", .{});
        b.installArtifact(rawhid_monitor);
        return rawhid_monitor;
    }
    return null;
}

/// Adds an uncached run step that flashes `firmware_uf2` with picotool: it
/// reports the UF2 hash, waits for a device in BOOTSEL mode, loads and verifies
/// the firmware, and reboots. The UF2 must carry the RP2040 family ID, e.g.
/// `firmware.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } })`.
/// `dependency` is the zigmkay package as a dependency of the calling package.
pub fn addPicotoolFlash(b: *std.Build, dependency: *std.Build.Dependency, firmware_uf2: std.Build.LazyPath) *std.Build.Step.Run {
    const flash_command = b.addRunArtifact(dependency.artifact("flash_picotool"));
    flash_command.addArtifactArg(picotool(dependency).artifact("picotool"));
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
    install_command.addFileArg(picotool(dependency).builder.dependency("picotool", .{}).path("udev/60-picotool.rules"));
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

/// picotool, built from source for the host. A lazy dependency of zigmkay:
/// only builds that configure a picotool step fetch it.
fn picotool(dependency: *std.Build.Dependency) *std.Build.Dependency {
    return dependency.builder.dependency("picotool", .{
        .target = dependency.builder.graph.host,
        .optimize = .ReleaseFast,
    });
}
