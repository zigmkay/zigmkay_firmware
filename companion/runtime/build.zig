//! The build script shipped as `build/build.zig` inside the application bundle.
//! The installed application invokes `build-project`, `build-runner` and
//! `analyze-keymap` with the bundled compiler and `--system` packages. Every
//! helper it uses lives in the bundled `src/` closure (`build/runtime.zig` in
//! the repository lists it).
const std = @import("std");
const firmware_build = @import("src/firmware/build.zig");
const runner_build = @import("src/runner/build.zig");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0")) @panic("Requires Zig 0.17.0");
    // An explicit Linux ABI makes host tools use Zig's shipped libc inputs.
    // Otherwise a detectable system compiler with unavailable SDK headers can
    // make native libc discovery fail before Zig uses its bundled fallback.
    if (b.graph.host.result.os.tag == .linux) {
        b.graph.host.query.abi = b.graph.host.result.abi;
    }
    const step = b.step("build-project", "Build the exported firmware and native runner offline");
    b.default_step = step;
    const runner_step = b.step("build-runner", "Build only the native tutor processor");
    const export_option = b.option([]const u8, "project-export", "Frozen project export");
    const board_option = b.option([]const u8, "project-board", "Board selector");
    const native_only = b.option(bool, "native-only", "Skip the embedded dependency graph") orelse false;
    const fw = b.lazyDependency("zigmkay_firmware", .{}) orelse return;
    const processor = fw.module("zigmkay");
    const zigmkay: []const std.Build.Module.Import = &.{.{ .name = "zigmkay", .module = processor }};
    const keycodes = b.createModule(.{ .root_source_file = fw.path("zkeycodes/root.zig"), .imports = zigmkay });
    const layout = b.createModule(.{ .root_source_file = b.path("src/layout/root.zig"), .imports = zigmkay });
    @import("src/importer/build.zig").add(b, processor, keycodes, layout);
    if (export_option) |path| {
        const owned_zon = b.createModule(.{ .root_source_file = b.path("src/project/owned_zon.zig") });
        const protocol = b.createModule(.{ .root_source_file = b.path("src/runner/protocol.zig"), .imports = &.{ .{ .name = "zigmkay", .module = processor }, .{ .name = "owned-zon", .module = owned_zon } } });
        const install = b.addInstallArtifact(runner_build.projectRunner(b, path, processor, keycodes, layout, protocol), .{});
        runner_step.dependOn(&install.step);
        step.dependOn(&install.step);
    } else runner_step.dependOn(&b.addFail("build-runner requires an absolute project-export").step);
    if (native_only) return;
    const mz = b.lazyImport(@This(), "microzig") orelse return;
    const mz_dep = b.lazyDependency("microzig", .{}) orelse return;
    const mb = mz.MicroBuild(.{ .rp2xxx = true }).init(b, mz_dep) orelse return;
    const path = export_option orelse return;
    const board = board_option orelse @panic("Missing board");
    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
    const firmware = firmware_build.projectFirmware(b, mb, &target, .{
        .keyboards = fw.path("keyboards"),
        .processor = fw.path("zigmkay/src/root.zig"),
        .keycodes = fw.path("zkeycodes/root.zig"),
    }, board, path);
    step.dependOn(&b.addInstallFile(firmware.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } }), "firmware/project.uf2").step);
}
