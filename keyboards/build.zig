const std = @import("std");

/// The keyboards of this package. Other packages reach the table as
/// `@import("keyboards").boards` in their build.zig.
pub const boards = @import("boards.zig");

// microzig is pinned once, by the zigmkay package.
const microzig = @import("zigmkay").microzig;
pub const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

/// Where `addKeyboardFirmware` finds its sources.
pub const Sources = struct {
    /// This keyboards directory; `Board` paths are relative to it.
    keyboards: std.Build.LazyPath,
    /// `zigmkay/src/root.zig`.
    processor: std.Build.LazyPath,
    /// `zkeycodes/root.zig`.
    keycodes: std.Build.LazyPath,
};

pub fn build(b: *std.Build) void {
    const selected_keyboard = b.option([]const u8, "keyboard", keyboardOptionDescription(b)) orelse boards.boards[0].name;
    const keymap_option = b.option([]const u8, "keymap", "Keymap file that replaces the keyboard's own, relative to this directory or absolute, such as local/lk8/keymap.zig");

    const zigmkay_dep = b.dependency("zigmkay", .{});
    const mz_dep = zigmkay_dep.builder.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    const zigmkay_mod = zigmkay_dep.module("zigmkay");

    const zkeycodes_dep = b.dependency("zkeycodes", .{});
    const zkeycodes_mod = zkeycodes_dep.module("zkeycodes");
    const sources: Sources = .{
        .keyboards = b.path("."),
        .processor = zigmkay_dep.path("src/root.zig"),
        .keycodes = zkeycodes_dep.path("root.zig"),
    };

    const sample = boards.find(selected_keyboard) orelse {
        printAvailableSamples();
        std.debug.panic("Unknown keyboard sample: '{s}'", .{selected_keyboard});
    };

    const keymap_override = if (keymap_option) |path| keymapPath(b, sample, path) else null;
    const firmware = addKeyboardFirmware(b, mb, &target, optimize, "zigmkay_firmware", sample, sources, keymap_override);
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
    const boards_mod = b.createModule(.{
        .root_source_file = b.path("boards.zig"),
        .target = b.graph.host,
    });
    const board_tests = b.addTest(.{ .root_module = boards_mod });
    test_step.dependOn(&b.addRunArtifact(board_tests).step);

    // Compile every keyboard so a broken keymap fails the tests, not just the
    // one selected with -Dkeyboard; the board template too, so that what
    // board:new creates always builds.
    for (boards.boards ++ [_]boards.Board{board_template}) |keyboard| {
        const keyboard_firmware = addKeyboardFirmware(b, mb, &target, optimize, keyboard.name, keyboard, sources, null);
        test_step.dependOn(&keyboard_firmware.exe.step);
    }

    // keymap:new and board:new; see tools/scaffold.zig.
    const scaffold_mod = b.createModule(.{
        .root_source_file = b.path("tools/scaffold.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "boards", .module = boards_mod }},
    });
    const scaffold = b.addExecutable(.{ .name = "scaffold", .root_module = scaffold_mod });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = scaffold_mod })).step);
    for ([_][3][]const u8{
        .{ "keymap-new", "keymap", "Copy a keyboard's default keymap into local/ (zig build keymap-new -- <keyboard> [name])" },
        .{ "board-new", "board", "Create my_keyboards/<name>/ from the board template and register it (zig build board-new -- <name>)" },
    }) |step| {
        const run = b.addRunArtifact(scaffold);
        run.addArg(step[1]);
        run.addPassthruArgs();
        run.setCwd(b.path("."));
        b.step(step[0], step[2]).dependOn(&run.step);
    }

    _ = @import("zigmkay").addFlashSteps(b, zigmkay_dep, firmware_uf2);
}

/// Each firmware gets its own zigmkay/zkeycodes module instances: add_app_import
/// wires the firmware's microzig into them, so sharing one instance between
/// several firmwares makes microzig appear twice in the same module graph.
///
/// Other packages reach this through `@import("zigmkay_firmware").keyboards`.
/// A non-null `keymap` replaces the board's own keymap file.
pub fn addKeyboardFirmware(
    b: *std.Build,
    mb: *MicroBuild,
    target: *const microzig.Target,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    board: boards.Board,
    sources: Sources,
    keymap: ?std.Build.LazyPath,
) *MicroBuild.Firmware {
    const firmware = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = optimize,
        .root_source_file = sources.keyboards.path(b, board.root_source_file),
    });
    const zigmkay_mod = b.createModule(.{ .root_source_file = sources.processor });
    const zkeycodes_mod = b.createModule(.{
        .root_source_file = sources.keycodes,
        .imports = &.{.{ .name = "zigmkay", .module = zigmkay_mod }},
    });
    firmware.add_app_import("zigmkay", zigmkay_mod, .{ .depend_on_microzig = true });
    firmware.add_app_import("zkeycodes", zkeycodes_mod, .{ .depend_on_microzig = true });
    if (keymap orelse if (board.keymap) |file| sources.keyboards.path(b, file) else null) |keymap_source| {
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

/// What `board:new` copies; compiled by the test step, not a build target.
const board_template: boards.Board = .{
    .name = "board_template",
    .root_source_file = "tools/templates/main.zig",
    .keymap = "tools/templates/keymap.zig",
};

/// The `-Dkeymap` file of `board`: relative to this directory, or absolute.
fn keymapPath(b: *std.Build, board: boards.Board, path: []const u8) std.Build.LazyPath {
    if (board.keymap == null) std.process.fatal(
        "'{s}' defines its keymap in its main file, {s}; -Dkeymap needs a keyboard with a keymap file.",
        .{ board.name, board.root_source_file },
    );
    const absolute = std.fs.path.isAbsolute(path);
    const found = if (absolute) std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) else b.root.access(b.graph.io, path, .{});
    found catch |err|
        std.process.fatal("Cannot read the keymap '{s}' ({t}); a relative path starts in the keyboards directory, such as local/lk8/keymap.zig.", .{ path, err });
    return if (absolute) .{ .cwd_relative = path } else b.path(path);
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
