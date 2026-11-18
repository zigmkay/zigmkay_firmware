//! Embedded firmware (`-Dfirmware`): compile-only firmware matrices,
//! `build-project` and the `hardware-tools` preparation. Every UF2 stays in
//! the build cache or `zig-out`; nothing here flashes or opens a device.
const std = @import("std");
const Deps = @import("Deps.zig");
const Steps = @import("Steps.zig");
const tests = @import("tests.zig");
const fw_build = @import("../src/firmware/build.zig");
const runner_build = @import("../src/runner/build.zig");

/// Every firmware-area test root; `tests-reached` checks it against the wiring.
pub const test_roots = [_][]const u8{ "tests/project_processor_contract.zig", "tools/usb_candidate.zig" };

pub fn add(s: *tests.Suite, deps: Deps, fixtures: tests.Fixtures) void {
    const b = s.b;
    const cfg = s.cfg;
    const steps = s.steps;
    const h = s.mods.host.?;
    if (cfg.project_export != null and cfg.project_board != null) {
        steps.build_project.dependOn(&b.addInstallArtifact(runner_build.projectRunner(b, cfg.project_export.?, h.zigmkay, h.keycodes, h.layout, h.runner_protocol), .{}).step);
    } else Steps.unavailable(b, steps.build_project, "build-project requires -Dproject-export=<absolute export> and -Dproject-board=<selector>");

    const mb = deps.microBuild() orelse return;
    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
    const sources = h.sources;
    if (cfg.project_export) |path| if (cfg.project_board) |board| {
        const project = fw_build.projectFirmware(b, mb, &target, sources, board, path);
        steps.build_project.dependOn(&b.addInstallFile(uf2(project), "firmware/project.uf2").step);
    };

    // Both pinned imports for every Keycaprio revision.
    for (fixtures.imports) |fixture| {
        const firmware = fw_build.addKeyboardFirmware(b, mb, &target, .safe, "imported", fw_build.boards.find(fixture.selector).?, sources, null);
        const processor = firmware.exe.root_module.import_table.get("zigmkay").?;
        const layout = b.createModule(.{ .root_source_file = b.path("src/layout/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = processor }} });
        const selected = tests.importedProfile(b, fixture.export_root, processor, firmware.exe.root_module.import_table.get("zkeycodes").?, layout);
        selected.addImport("microzig", firmware.core_mod);
        firmware.add_app_import("keymap", selected, .{});
        steps.check_firmware.dependOn(&firmware.exe.step);
    }

    // Every selected board with its synthetic indexed export and, separately,
    // with its actual default keymap.
    for ([_]struct { *std.Build.Step, bool }{ .{ steps.check_firmware, false }, .{ steps.check_firmware_defaults, true } }) |matrix| {
        const step, const defaults = matrix;
        const files = b.addWriteFiles();
        for (fw_build.boards.entries) |board| {
            const generate = b.addRunArtifact(fixtures.catalog_export.?);
            generate.addArg(board.name);
            const directory = generate.addOutputDirectoryArg2(board.name, .{ .make_absolute = true });
            if (defaults) generate.addArg("--default");
            const firmware = fw_build.addKeyboardFirmware(b, mb, &target, .safe, b.fmt("catalog-{s}", .{board.name}), board, sources, directory.path(b, "keymap.zig"));
            if (defaults) firmware.exe.root_module.import_table.get("keymap").?.addImport("callback_0", b.createModule(.{
                .root_source_file = directory.path(b, b.fmt("callback_0/{s}", .{board.default_keymap})),
                .imports = &.{
                    .{ .name = "zigmkay", .module = firmware.exe.root_module.import_table.get("zigmkay").? },
                    .{ .name = "zkeycodes", .module = firmware.exe.root_module.import_table.get("zkeycodes").? },
                },
            }));
            _ = files.addCopyFile(uf2(firmware), b.fmt("{s}.uf2", .{board.name}));
        }
        step.dependOn(&files.step);
    }

    // Generated LK7 and split keymaps, the project processor contract and the
    // offline USB candidate inventory.
    const generator = b.addExecutable(.{ .name = "export-board-fixture", .root_module = s.mods.root("src/project/board_export_fixture.zig", h.keymap_project) });
    const project_export = b.addRunArtifact(generator);
    const project_directory = project_export.addOutputDirectoryArg("project");
    const exported_project = project_directory.path(b, "keymap.zig");
    if (cfg.candidate_project) |path| {
        project_export.addDirectoryArg(.{ .cwd_relative = path });
        if (cfg.candidate_overlay_trigger) project_export.addArg("--overlay-trigger");
    }
    const native_profile = b.createModule(.{ .root_source_file = exported_project, .imports = h.zigmkay_only });
    _ = s.unit(steps.check_firmware, .firmware, "tests/project_processor_contract.zig", &.{
        .{ .name = "zigmkay", .module = h.zigmkay },
        .{ .name = "generated-project", .module = native_profile },
    });
    const artifacts = b.addWriteFiles();
    const generated = b.addWriteFiles();
    for ([_]struct { []const u8, usize }{ .{ "lk7", 34 }, .{ "dasbob", 36 } }) |fixture| {
        const name, const keys = fixture;
        const keymap = if (std.mem.eql(u8, name, "lk7")) exported_project else generated.add(b.fmt("{s}/keymap.zig", .{name}), b.fmt(
            \\const core = @import("zigmkay").core;
            \\pub const key_count = {d};
            \\pub const dimensions = core.KeymapDimensions{{ .key_count = key_count, .layer_count = 2 }};
            \\pub const sides: [key_count]core.Side = @splat(.X);
            \\pub const keymap = [2][key_count]?core.KeyDef{{ @splat(.{{ .tap_only = .{{ .key_press = .{{ .tap_keycode = 4 }} }} }}), @splat(null) }};
            \\pub const combos = [_]core.Combo2Def{{}};
            \\fn onEvent(_: core.ProcessorEvent, _: *core.LayerActivations, _: *core.OutputCommandQueue) void {{}}
            \\pub const custom_functions: core.CustomFunctions = .{{ .on_event = onEvent, .companion_keymap_id = "fixture-observe!".* }};
            \\
        , .{keys}));
        const firmware = fw_build.addKeyboardFirmware(b, mb, &target, .safe, b.fmt("generated-{s}", .{name}), fw_build.boards.find(name).?, sources, keymap);
        const image = uf2(firmware);
        _ = artifacts.addCopyFile(image, b.fmt("{s}.uf2", .{name}));
        if (!std.mem.eql(u8, name, "lk7")) continue;
        const candidate = s.mods.root("tools/usb_candidate.zig", &.{
            .{ .name = "generated-profile", .module = native_profile },
            .{ .name = "zigmkay", .module = h.zigmkay },
            .{ .name = "device-protocol", .module = h.protocol },
        });
        _ = s.add(steps.check_firmware, .firmware, candidate);
        const inventory = b.addRunArtifact(b.addExecutable(.{ .name = "usb-candidate", .root_module = candidate }));
        inventory.addFileArg(image);
        const manifest = inventory.addOutputFileArg("candidate.zon");
        inventory.addArg(cfg.firmware_revision);
        for ([_]*std.Build.Step{
            &inventory.step,
            &b.addInstallFile(manifest, "acceptance/candidate.zon").step,
            &b.addInstallFile(image, "acceptance/candidate.uf2").step,
            &b.addInstallDirectory(.{ .source_dir = project_directory, .install_dir = .prefix, .install_subdir = "acceptance/project" }).step,
        }) |item| steps.hardware_tools.dependOn(item);
    }
    steps.check_firmware.dependOn(&artifacts.step);

    if (s.mods.gui) |g| {
        const client = b.addExecutable(.{ .name = "usb-acceptance", .root_module = s.mods.root("tools/usb_acceptance.zig", g.usb_acceptance_deps) });
        steps.hardware_tools.dependOn(&b.addInstallArtifact(client, .{}).step);
    }
}

fn uf2(firmware: anytype) std.Build.LazyPath {
    return firmware.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } });
}
