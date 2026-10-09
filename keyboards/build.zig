const std = @import("std");

const microzig = @import("microzig");
const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

const KeyboardSample = struct {
    name: []const u8,
    root_source_file: []const u8,
};

const keyboard_samples = [_]KeyboardSample{
    .{ .name = "clacky_chan", .root_source_file = "my_keyboards/rollercole/clacky_chan.zig" },
    .{ .name = "clackychan_colemak", .root_source_file = "my_keyboards/janbeelte/clackychan_main.zig" },
    .{ .name = "keycaprio_colemak_0_4", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_4.zig" },
    .{ .name = "keycaprio_colemak_0_6", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_6.zig" },
    .{ .name = "keycaprio_us_intl_0_7", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_7.zig" },
    .{ .name = "lk1", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_1.zig" },
    .{ .name = "lk2", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_2.zig" },
    .{ .name = "lk6", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_6.zig" },
    .{ .name = "lk7", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_7.zig" },
    .{ .name = "encoder_demo", .root_source_file = "my_keyboards/rollercole/encoder_demo.zig" },
    .{ .name = "dasbob", .root_source_file = "examples/dasbob/main.zig" },
    .{ .name = "tuckytwotimes", .root_source_file = "my_keyboards/rollercole/tuckytwotimes.zig" },
    .{ .name = "molekula", .root_source_file = "my_keyboards/molekula/main.zig" },
};

pub fn build(b: *std.Build) void {
    const selected_keyboard = b.option([]const u8, "keyboard", keyboardOptionDescription(b)) orelse keyboard_samples[0].name;

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    const zigmkay_dep = b.dependency("zigmkay", .{});
    const zigmkay_mod = zigmkay_dep.module("zigmkay");

    const zkeycodes_dep = b.dependency("zkeycodes", .{});
    const zkeycodes_mod = zkeycodes_dep.module("zkeycodes");

    const sample = findSample(selected_keyboard) orelse {
        printAvailableSamples();
        std.debug.panic("Unknown keyboard sample: '{s}'", .{selected_keyboard});
    };

    const firmware = addKeyboardFirmware(b, mb, &target, optimize, "zigmkay_firmware", sample.root_source_file, zigmkay_dep, zkeycodes_dep);
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

    // Compile every keyboard so a broken keymap fails the tests, not just the
    // one selected with -Dkeyboard.
    for (keyboard_samples) |keyboard| {
        const keyboard_firmware = addKeyboardFirmware(b, mb, &target, optimize, keyboard.name, keyboard.root_source_file, zigmkay_dep, zkeycodes_dep);
        test_step.dependOn(&keyboard_firmware.exe.step);
    }

    const flash_step = b.step("flash", "Build and flash the firmware with picotool");
    const flash_command = @import("zigmkay").addPicotoolFlash(b, zigmkay_dep, firmware_uf2);
    flash_step.dependOn(&flash_command.step);
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
    root_source_file: []const u8,
    zigmkay_dep: *std.Build.Dependency,
    zkeycodes_dep: *std.Build.Dependency,
) *MicroBuild.Firmware {
    const firmware = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(root_source_file),
    });
    const zigmkay_mod = b.createModule(.{ .root_source_file = zigmkay_dep.path("src/root.zig") });
    const zkeycodes_mod = b.createModule(.{
        .root_source_file = zkeycodes_dep.path("root.zig"),
        .imports = &.{.{ .name = "zigmkay", .module = zigmkay_mod }},
    });
    firmware.add_app_import("zigmkay", zigmkay_mod, .{ .depend_on_microzig = true });
    firmware.add_app_import("zkeycodes", zkeycodes_mod, .{ .depend_on_microzig = true });
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
        "Keyboard sample to build/flash (use: zig build -Dkeyboard=<name>, flash: zig build flash -Dkeyboard=<name>, available: {s})",
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
    std.debug.print("zig build flash -Dkeyboard=<name>\tBuild & Flash with picotool\n\n", .{});
}
