const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0")) @panic("Requires Zig 0.17.0");
    const step = b.step("build-project", "Build the exported firmware and native runner offline");
    b.default_step = step;
    const export_option = b.option([]const u8, "project-export", "Frozen project export");
    const board_option = b.option([]const u8, "project-board", "Board selector");
    const api = b.lazyImport(@This(), "zigmkay_firmware") orelse return;
    const fw = b.lazyDependency("zigmkay_firmware", .{}) orelse return;
    const native_keycodes = b.createModule(.{ .root_source_file = fw.path("zkeycodes/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = fw.module("zigmkay") }} });
    const native_model = b.createModule(.{ .root_source_file = b.path("packages/layout-model/src/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = fw.module("zigmkay") }} });
    @import("packages/importer/build.zig").add(b, fw.module("zigmkay"), native_keycodes, native_model);
    const runner_step = b.step("build-runner", "Build only the native tutor processor");
    if (export_option) |path| {
        const native = @import("packages/project/src/build_input.zig").load(b, path, fw.module("zigmkay"), native_keycodes, native_model) catch |err| @panic(@errorName(err));
        const owned_zon = b.createModule(.{ .root_source_file = b.path("packages/project/src/owned_zon.zig") });
        const protocol = b.createModule(.{ .root_source_file = b.path("packages/runner/src/protocol.zig"), .imports = &.{ .{ .name = "zigmkay", .module = fw.module("zigmkay") }, .{ .name = "owned-zon", .module = owned_zon } } });
        const runner = @import("packages/runner/build.zig").runner(b, "project-runner", fw.module("zigmkay"), native.module, protocol, native.snapshot_id);
        const install = b.addInstallArtifact(runner, .{});
        runner_step.dependOn(&install.step);
        step.dependOn(&install.step);
    } else runner_step.dependOn(&b.addFail("build-runner requires an absolute project-export").step);
    if (b.option(bool, "native-only", "Skip the embedded dependency graph") orelse false) return;
    const mz = b.lazyImport(@This(), "microzig") orelse return;
    const mz_dep = b.lazyDependency("microzig", .{}) orelse return;
    const MicroBuild = mz.MicroBuild(.{ .rp2xxx = true });
    const mb = MicroBuild.init(b, mz_dep) orelse return;
    const path = export_option orelse return;
    const name = board_option orelse @panic("Missing board");
    const board = api.boards.find(name) orelse @panic("Unknown board");
    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
    const item = api.addKeyboardFirmware(b, mb, &target, .safe, "project", board, .{
        .keyboards = fw.path("keyboards"),
        .processor = fw.path("zigmkay/src/root.zig"),
        .keycodes = fw.path("zkeycodes/root.zig"),
        .companion_enabled = true,
    }, null);
    const selector = @import("packages/project/src/build_input.zig");
    const processor = item.exe.root_module.import_table.get("zigmkay").?;
    const keycodes = item.exe.root_module.import_table.get("zkeycodes").?;
    const model = b.createModule(.{ .root_source_file = b.path("packages/layout-model/src/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = processor }} });
    const selected = selector.load(b, path, processor, keycodes, model) catch |err| @panic(@errorName(err));
    selected.module.addImport("microzig", item.core_mod);
    item.add_app_import("keymap", selected.module, .{});
    step.dependOn(&b.addInstallFile(item.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } }), "firmware/project.uf2").step);
}
