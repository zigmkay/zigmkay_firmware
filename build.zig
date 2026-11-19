const std = @import("std");

pub const microzig = @import("microzig");
const build_utils = @import("build_utils.zig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub const add_test_steps = build_utils.add_test_steps;

/// Usage from a downstream build.zig:
///     const firmware_dep = b.dependency("zigmkay_firmware", .{});
///     _ = @import("zigmkay_firmware").addFlashSteps(b, firmware_dep, firmware_uf2);
/// This adds the `flash`, `flash_pt` and `flash_mount` steps (plus
/// `install-udev-rules` on Linux) and the `-Dflash-mount` option. The single
/// run steps below are for packages that want their own step layout.
pub const FlashSteps = build_utils.FlashSteps;
pub const addFlashSteps = build_utils.addFlashSteps;
pub const addFlash = build_utils.addFlash;
pub const addPicotoolFlash = build_utils.addPicotoolFlash;
pub const addMountFlash = build_utils.addMountFlash;
pub const addUdevRulesInstall = build_utils.addUdevRulesInstall;

const KeyboardSample = struct {
    name: []const u8,
    root_source_file: []const u8,
    /// Keymap source exposed to the board's main file as `@import("keymap")`,
    /// so one main file per board can be combined with different keymaps.
    keymap: ?[]const u8 = null,
};

const keyboard_samples = [_]KeyboardSample{
    .{ .name = "clacky_chan", .root_source_file = "my_keyboards/rollercole/clacky_chan.zig" },
    .{ .name = "clackychan_colemak", .root_source_file = "my_keyboards/janbeelte/clackychan_main.zig", .keymap = "my_keyboards/janbeelte/clackychan_colemak_keymap.zig" },
    .{ .name = "keycaprio_colemak_0_4", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_4.zig", .keymap = "my_keyboards/janbeelte/clackychan_colemak_keymap.zig" },
    .{ .name = "keycaprio_colemak_0_6", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_6.zig", .keymap = "my_keyboards/janbeelte/keycaprio_colemak_keymap.zig" },
    .{ .name = "keycaprio_colemak_0_7", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_7.zig", .keymap = "my_keyboards/janbeelte/keycaprio_colemak_keymap.zig" },
    .{ .name = "keycaprio_us_intl_0_7", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_7.zig", .keymap = "my_keyboards/janbeelte/keycaprio_us_intl_keymap.zig" },
    .{ .name = "lk1", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_1.zig" },
    .{ .name = "lk2", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_2.zig" },
    .{ .name = "lk6", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_6.zig" },
    .{ .name = "lk7", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_7.zig" },
    .{ .name = "lk8", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_8.zig" },
    .{ .name = "encoder_demo", .root_source_file = "my_keyboards/rollercole/encoder_demo.zig" },
    .{ .name = "dasbob", .root_source_file = "examples/dasbob/main.zig" },
    .{ .name = "tuckytwotimes", .root_source_file = "my_keyboards/rollercole/tuckytwotimes.zig" },
    .{ .name = "molekula", .root_source_file = "my_keyboards/molekula/main.zig" },
};

pub fn build(b: *std.Build) void {
    const zigmkay_mod = b.addModule("zigmkay", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const zkeycodes_dep = b.dependency("zkeycodes", .{});
    const zkeycodes_mod = b.createModule(.{
        .root_source_file = zkeycodes_dep.path("root.zig"),
        .imports = &.{.{ .name = "zigmkay", .module = zigmkay_mod }},
    });

    build_utils.install_tools(b);
    // This package's own tools (flash helpers, picotool, rawhid-monitor), seen
    // the same way a downstream package sees them through b.dependency(...).
    var self_dep: std.Build.Dependency = .{ .builder = b };

    // Host tests: zigmkay unit tests plus keyboard keymap regression tests.
    const test_step = b.step("test", "Run unit and keyboard regression tests");
    build_utils.add_test_steps(b, zigmkay_mod, test_step, "tests");

    const keymap_test_module = b.createModule(.{
        .root_source_file = b.path("keyboard_tests/test_clackychan_combos.zig"),
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

    if (b.graph.host.result.os.tag == .macos) {
        const run_rawhid_monitor = b.addRunArtifact(self_dep.artifact("rawhid-monitor"));
        const rawhid_monitor_step = b.step("rawhid-monitor", "Observe ZigMkay Raw HID key events");
        rawhid_monitor_step.dependOn(&run_rawhid_monitor.step);
    }

    // Keyboard firmware. Skipped when this package is used as a dependency by
    // another firmware package, which builds its own firmware.
    if (!b.isRoot()) return;

    const selected_keyboard = b.option([]const u8, "keyboard", keyboardOptionDescription(b)) orelse keyboard_samples[0].name;

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    const sample = findSample(selected_keyboard) orelse {
        printAvailableSamples();
        std.debug.panic("Unknown keyboard sample: '{s}'", .{selected_keyboard});
    };

    const firmware = addKeyboardFirmware(b, mb, &target, optimize, "zigmkay_firmware", sample, zkeycodes_dep);
    mb.install_firmware(firmware, .{});

    const firmware_uf2 = firmware.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } });
    b.addNamedLazyPath("firmware_uf2", firmware_uf2);

    // Compile every keyboard so a broken keymap fails the tests, not just the
    // one selected with -Dkeyboard.
    for (keyboard_samples) |keyboard| {
        const keyboard_firmware = addKeyboardFirmware(b, mb, &target, optimize, keyboard.name, keyboard, zkeycodes_dep);
        test_step.dependOn(&keyboard_firmware.exe.step);
    }

    _ = build_utils.addFlashSteps(b, &self_dep, firmware_uf2);
}

/// Each firmware gets its own zigmkay/zkeycodes module instances: add_app_import
/// wires the firmware's microzig into them, so sharing one instance between
/// several firmwares makes microzig appear twice in the same module graph.
fn addKeyboardFirmware(
    b: *std.Build,
    mb: *MicroBuild,
    target: *const microzig.Target,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    sample: KeyboardSample,
    zkeycodes_dep: *std.Build.Dependency,
) *MicroBuild.Firmware {
    const firmware = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(sample.root_source_file),
    });
    const zigmkay_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig") });
    const zkeycodes_mod = b.createModule(.{
        .root_source_file = zkeycodes_dep.path("root.zig"),
        .imports = &.{.{ .name = "zigmkay", .module = zigmkay_mod }},
    });
    firmware.add_app_import("zigmkay", zigmkay_mod, .{ .depend_on_microzig = true });
    firmware.add_app_import("zkeycodes", zkeycodes_mod, .{ .depend_on_microzig = true });
    if (sample.keymap) |keymap_source_file| {
        const keymap_mod = b.createModule(.{
            .root_source_file = b.path(keymap_source_file),
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
    var sample_names: [keyboard_samples.len][]const u8 = undefined;
    inline for (keyboard_samples, 0..) |sample, idx| {
        sample_names[idx] = sample.name;
    }

    const joined_samples = std.mem.join(b.allocator, ", ", sample_names[0..]) catch @panic("Failed to build keyboard sample list");
    return std.fmt.allocPrint(
        b.allocator,
        "Keyboard sample to build/flash (use: zig build -Dkeyboard=<name>, flash: zig build flash -Dkeyboard=<name>, picotool: zig build flash_pt, mount: zig build flash_mount [-Dflash-mount=<path|label>], available: {s})",
        .{joined_samples},
    ) catch @panic("Failed to build keyboard option description");
}

fn findSample(name: []const u8) ?KeyboardSample {
    inline for (keyboard_samples) |sample| {
        if (std.mem.eql(u8, sample.name, name)) return sample;
    }
    return null;
}

fn printAvailableSamples() void {
    std.debug.print("Available keyboard samples:\n", .{});
    inline for (keyboard_samples) |sample| {
        std.debug.print("  - {s}\n", .{sample.name});
    }
    std.debug.print("zig build -Dkeyboard=<name>\t\tBuild the Firmware\n", .{});
    std.debug.print("zig build flash -Dkeyboard=<name>\tBuild & Flash using the host default\n", .{});
    std.debug.print("zig build flash_pt -Dkeyboard=<name>\tBuild & Flash with picotool\n", .{});
    std.debug.print("zig build flash_mount -Dkeyboard=<name>\tBuild & Flash through the mounted RP2 volume\n", .{});
    std.debug.print("zig build install-udev-rules\t\tLinux: install picotool udev rules (sudo)\n\n", .{});
}
