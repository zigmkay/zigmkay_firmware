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

/// Builds and installs the `picotool_flash` host tool so that dependents can
/// fetch it with `dependency.artifact("picotool_flash")`, and exposes picotool,
/// built from source, as the named lazy path "picotool". `source_path` is the
/// tool's path relative to the calling package root, which must declare the
/// `picotool` dependency.
pub fn install_picotool_flash(b: *std.Build, source_path: []const u8) void {
    const picotool_flash = b.addExecutable(.{
        .name = "picotool_flash",
        .root_module = b.createModule(.{
            .root_source_file = b.path(source_path),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(picotool_flash);

    const picotool_dep = b.dependency("picotool", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    b.addNamedLazyPath("picotool", picotool_dep.artifact("picotool").getEmittedBin());
}

/// Adds an uncached run step that flashes `firmware_uf2` with picotool: it
/// reports the UF2 hash, waits for a device in BOOTSEL mode, loads and verifies
/// the firmware, and reboots. The UF2 must carry the RP2040 family ID, e.g.
/// `firmware.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } })`.
/// `dependency` is the package that installs picotool_flash (this repo's root
/// or the zigmkay subpackage).
pub fn addPicotoolFlash(b: *std.Build, dependency: *std.Build.Dependency, firmware_uf2: std.Build.LazyPath) *std.Build.Step.Run {
    const flash_command = b.addRunArtifact(dependency.artifact("picotool_flash"));
    flash_command.addFileArg(dependency.namedLazyPath("picotool"));
    flash_command.addFileArg(firmware_uf2);
    flash_command.has_side_effects = true;
    return flash_command;
}
