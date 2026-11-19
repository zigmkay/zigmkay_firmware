const std = @import("std");

/// The keyboards of this package. Other packages reach the table as
/// `@import("keyboards").boards` in their build.zig.
pub const boards = @import("boards.zig");

// microzig is pinned once, by the zigmkay package.
const microzig = @import("zigmkay").microzig;
pub const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const selected_keyboard = b.option([]const u8, "keyboard", keyboardOptionDescription(b)) orelse boards.boards[0].name;

    const zigmkay_dep = b.dependency("zigmkay", .{});
    const mz_dep = zigmkay_dep.builder.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    const zigmkay_mod = zigmkay_dep.module("zigmkay");

    const zkeycodes_dep = b.dependency("zkeycodes", .{});
    const zkeycodes_mod = zkeycodes_dep.module("zkeycodes");

    const sample = boards.find(selected_keyboard) orelse {
        printAvailableSamples();
        std.debug.panic("Unknown keyboard sample: '{s}'", .{selected_keyboard});
    };

    const firmware = addKeyboardFirmware(b, mb, &target, optimize, "zigmkay_firmware", sample, zigmkay_dep, zkeycodes_dep, b.path("."), null);
    mb.install_firmware(firmware, .{});

    const firmware_uf2 = firmware.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } });
    b.addNamedLazyPath("firmware_uf2", firmware_uf2);

    const test_step = b.step("test", "Run keyboard regression tests");
    const keymap_test_module = b.createModule(.{
        .root_source_file = b.path("tests/test_clackychan_combos.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "zigmkay", .module = zigmkay_mod },
        },
    });
    const clackychan_keymap_module = b.createModule(.{
        .root_source_file = b.path("my_keyboards/janbeelte/clackychan_colemak_keymap.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "zigmkay", .module = zigmkay_mod },
            .{ .name = "zkeycodes", .module = zkeycodes_mod },
        },
    });
    keymap_test_module.addImport("clackychan_keymap", clackychan_keymap_module);
    const keymap_tests = b.addTest(.{ .root_module = keymap_test_module });
    test_step.dependOn(&b.addRunArtifact(keymap_tests).step);
    const board_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("boards.zig"),
        .target = b.graph.host,
    }) });
    test_step.dependOn(&b.addRunArtifact(board_tests).step);

    // Compile every keyboard so a broken keymap fails the tests, not just the
    // one selected with -Dkeyboard.
    for (boards.boards) |keyboard| {
        const keyboard_firmware = addKeyboardFirmware(b, mb, &target, optimize, keyboard.name, keyboard, zigmkay_dep, zkeycodes_dep, b.path("."), null);
        test_step.dependOn(&keyboard_firmware.exe.step);
    }

    _ = @import("zigmkay").addFlashSteps(b, zigmkay_dep, firmware_uf2);
}

/// Each firmware gets its own zigmkay/zkeycodes module instances: add_app_import
/// wires the firmware's microzig into them, so sharing one instance between
/// several firmwares makes microzig appear twice in the same module graph.
///
/// `root` is this keyboards directory, which `board` paths are relative to:
/// `b.path(".")` here, `keyboards_dep.path(".")` from another package. A
/// non-null `keymap` replaces the board's own keymap file.
pub fn addKeyboardFirmware(
    b: *std.Build,
    mb: *MicroBuild,
    target: *const microzig.Target,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    board: boards.Board,
    zigmkay_dep: *std.Build.Dependency,
    zkeycodes_dep: *std.Build.Dependency,
    root: std.Build.LazyPath,
    keymap: ?std.Build.LazyPath,
) *MicroBuild.Firmware {
    const firmware = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = optimize,
        .root_source_file = root.path(b, board.root_source_file),
    });
    const zigmkay_mod = b.createModule(.{ .root_source_file = zigmkay_dep.path("src/root.zig") });
    const zkeycodes_mod = b.createModule(.{
        .root_source_file = zkeycodes_dep.path("root.zig"),
        .imports = &.{.{ .name = "zigmkay", .module = zigmkay_mod }},
    });
    firmware.add_app_import("zigmkay", zigmkay_mod, .{ .depend_on_microzig = true });
    firmware.add_app_import("zkeycodes", zkeycodes_mod, .{ .depend_on_microzig = true });
    if (keymap orelse if (board.keymap) |file| root.path(b, file) else null) |keymap_source| {
        const keymap_mod = b.createModule(.{
            .root_source_file = keymap_source,
            .imports = &.{
                .{ .name = "zigmkay", .module = zigmkay_mod },
                .{ .name = "zkeycodes", .module = zkeycodes_mod },
            },
        });
        firmware.add_app_import("keymap", keymap_mod, .{ .depend_on_microzig = true });
    }
    return firmware;
}

fn keyboardOptionDescription(b: *std.Build) []const u8 {
    var sample_names: [boards.boards.len][]const u8 = undefined;
    inline for (boards.boards, 0..) |sample, idx| {
        sample_names[idx] = sample.name;
    }

    const joined_samples = std.mem.join(b.allocator, ", ", sample_names[0..]) catch @panic("Failed to build keyboard sample list");
    return std.fmt.allocPrint(
        b.allocator,
        "Keyboard sample to build/flash (use: zig build -Dkeyboard=<name>, flash: zig build flash -Dkeyboard=<name>, picotool: zig build flash_pt, mount: zig build flash_mount [-Dflash-mount=<path|label>], available: {s})",
        .{joined_samples},
    ) catch @panic("Failed to build keyboard option description");
}

fn printAvailableSamples() void {
    std.debug.print("Available keyboard samples:\n", .{});
    inline for (boards.boards) |sample| {
        std.debug.print("  - {s}\n", .{sample.name});
    }
    std.debug.print("zig build -Dkeyboard=<name>\t\tBuild the Firmware\n", .{});
    std.debug.print("zig build flash -Dkeyboard=<name>\tBuild & Flash using the host default\n", .{});
    std.debug.print("zig build flash_pt -Dkeyboard=<name>\tBuild & Flash with picotool\n", .{});
    std.debug.print("zig build flash_mount -Dkeyboard=<name>\tBuild & Flash through the mounted RP2 volume\n", .{});
    std.debug.print("zig build install-udev-rules\t\tLinux: install picotool udev rules (sudo)\n\n", .{});
}
