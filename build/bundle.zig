//! The self-contained application (`-Dbundle`) and `run`. Assembly copies
//! the compiler, the runtime build closure (`runtime.zig`), the pinned
//! firmware packages and prebuilt Flash tools; it never flashes a device.
const std = @import("std");
const Deps = @import("Deps.zig");
const Steps = @import("Steps.zig");
const runtime = @import("runtime.zig");
const tests = @import("tests.zig");
const native = @import("native.zig");
const fw_build = @import("../src/firmware/build.zig");
const Compile = std.Build.Step.Compile;

pub fn add(s: *tests.Suite, deps: Deps, app: *Compile, bootsel: ?*Compile) void {
    const b = s.b;
    const cfg = s.cfg;
    const os = b.graph.host.result.os.tag;
    const mb = deps.microBuild() orelse return;
    // Configure every board so Zig acquires all build-time lazy inputs of the
    // firmware closure before it is copied.
    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
    for (fw_build.boards.entries) |board| {
        const firmware = fw_build.addKeyboardFirmware(b, mb, &target, .safe, b.fmt("bundle-contract-{s}", .{board.name}), board, s.mods.host.?.sources, null);
        _ = firmware.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } });
    }
    if (b.graph.needed_lazy_dependencies.count() != 0) return;

    const assembler = b.addExecutable(.{ .name = "assemble-application", .root_module = s.mods.root("tools/assemble_application.zig", s.mods.core.jobs_only) });
    assembler.root_module.addOptions("bundle-pins", pins(b, cfg.revision));
    const icons = s.mods.gui.?.icon_files;
    switch (os) {
        .macos => assembler.root_module.addAnonymousImport("application-icns", .{ .root_source_file = icons.path(b, "Zigmkay.icns") }),
        .linux => {
            assembler.root_module.addAnonymousImport("application-png", .{ .root_source_file = icons.path(b, "application.png") });
            assembler.root_module.addAnonymousImport("application-svg", .{ .root_source_file = b.path("packaging/icons/zigmkay.svg") });
        },
        else => {},
    }
    const assemble = b.addRunArtifact(assembler);
    assemble.has_side_effects = true;
    assemble.addDirectoryArg2(b.path("."), .{ .make_absolute = true });
    assemble.addFileArg2(.zig_exe, .{ .make_absolute = true });
    assemble.addDirectoryArg2(b.path("zig-pkg"), .{ .make_absolute = true });
    const application = assemble.addOutputDirectoryArg2("Zigmkay.app", .{ .make_absolute = true });
    assemble.addArtifactArg(app);
    if (os == .windows) {
        assemble.addArtifactArg(bootsel.?);
        assemble.addArtifactArg(bootsel.?);
    } else {
        const picotool = deps.picotool.?.artifact("picotool");
        if (cfg.macos_sdk) |sdk| native.sdkPaths(b, picotool.root_module, sdk);
        assemble.addArtifactArg(b.addExecutable(.{ .name = "picotool_flash", .root_module = s.mods.root("src/jobs/picotool_flash.zig", &.{}) }));
        assemble.addArtifactArg(picotool);
    }
    if (os == .linux)
        assemble.addArtifactArg(b.addExecutable(.{ .name = "AppRun", .root_module = s.mods.root("tools/app_run.zig", &.{}) }))
    else
        assemble.addArtifactArg(app);
    const corresponding_source = assemble.addOutputDirectoryArg2("corresponding-source", .{ .make_absolute = true });

    const step = s.steps.bundle;
    step.dependOn(&b.addInstallDirectory(.{ .source_dir = corresponding_source, .install_dir = .prefix, .install_subdir = "corresponding-source" }).step);
    step.dependOn(switch (os) {
        .windows => &b.addInstallFile(application.path(b, "Zigmkay.exe"), "Zigmkay.exe").step,
        else => &b.addInstallDirectory(.{ .source_dir = application, .install_dir = .prefix, .install_subdir = if (os == .linux) "Zigmkay.AppDir" else "Zigmkay.app" }).step,
    });

    const launch = std.Build.Step.Run.create(b, "run bundled application");
    launch.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = switch (os) {
        .windows => "Zigmkay.exe",
        .linux => "Zigmkay.AppDir/AppRun",
        else => "Zigmkay.app/Contents/MacOS/zigmkay-companion",
    } } }, .{ .make_absolute = true });
    launch.step.dependOn(step);
    launch.addPassthruArgs();
    s.steps.run.dependOn(&launch.step);
}

/// Inputs the assembler records: dependency pins, the runtime closure and
/// its manifest, and the application identity.
fn pins(b: *std.Build, revision: []const u8) *std.Build.Step.Options {
    const manifest = @import("../build.zig.zon");
    const firmware = manifest.dependencies.zigmkay_firmware;
    const options = b.addOptions();
    options.addOption([]const []const u8, "license_hashes", &.{
        manifest.dependencies.dvui.hash,
        manifest.dependencies.ztray.hash,
        manifest.dependencies.svg2tvg.hash,
        manifest.dependencies.icons.hash,
        manifest.dependencies.inter.hash,
        @import("../src/jobs/flash_inputs.zig").picotool_package_hash,
    });
    options.addOption([]const u8, "manifest", runtime.manifest(b));
    options.addOption([]const u8, "runtime_source_root", runtime.source_root);
    options.addOption([]const []const u8, "runtime_closure", &runtime.closure);
    options.addOption([]const u8, "firmware_hash", firmware.hash);
    options.addOption([]const u8, "microzig_hash", manifest.dependencies.microzig.hash);
    options.addOption([]const u8, "firmware_revision", firmware.url[std.mem.lastIndexOfScalar(u8, firmware.url, '#').? + 1 ..]);
    options.addOption([]const u8, "application_version", manifest.version);
    options.addOption([]const u8, "source_revision", revision);
    return options;
}
