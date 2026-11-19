//! Developer utilities: `tools` (release, bundle check, catalog export,
//! diagnostics), `run-project` and `analyze-keymap`. None accesses devices.
const std = @import("std");
const Steps = @import("Steps.zig");
const tests = @import("tests.zig");
const importer_build = @import("../src/importer/build.zig");
const Compile = std.Build.Step.Compile;

pub const Tools = struct {
    /// The native Windows BOOTSEL helper; null on other hosts.
    bootsel: ?*Compile,
};

pub fn add(s: *tests.Suite, catalog_export: ?*Compile) Tools {
    const b = s.b;
    const cfg = s.cfg;
    const core = s.mods.core;
    install(s, b.addExecutable(.{ .name = "diagnose-build-finalization", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/diagnose_build_finalization.zig"),
        .target = cfg.target,
        .optimize = .debug,
        .strip = false,
        .imports = core.jobs_only,
    }) }));
    if (cfg.only == .diagnostic) {
        Steps.unavailable(b, s.steps.run_project, "run-project is unavailable with -Donly=diagnostic");
        Steps.unavailable(b, s.steps.analyze_keymap, "analyze-keymap is unavailable with -Donly=diagnostic");
        return .{ .bootsel = null };
    }
    const release = b.addExecutable(.{ .name = "release", .root_module = s.mods.root("tools/release.zig", core.jobs_only) });
    release.root_module.addOptions("release-options", core.release_options);
    install(s, release);
    const bootsel = if (b.graph.host.result.os.tag == .windows)
        b.addExecutable(.{ .name = "bootsel-transfer", .root_module = s.mods.root("tools/bootsel_transfer.zig", core.bootsel_tool) })
    else
        null;
    if (bootsel) |helper| install(s, helper);

    const h = s.mods.host orelse {
        Steps.unavailable(b, s.steps.run_project, "run-project needs the firmware package; drop -Donly");
        Steps.unavailable(b, s.steps.analyze_keymap, "analyze-keymap needs the firmware package; drop -Donly");
        return .{ .bootsel = bootsel };
    };
    const bundle_check = b.addExecutable(.{ .name = "check-application-bundle", .root_module = s.mods.root("tools/check_application_bundle.zig", h.bundle_check_deps) });
    for ([_][]const u8{ "us", "de" }) |name| {
        bundle_check.root_module.addAnonymousImport(b.fmt("import-{s}", .{name}), .{ .root_source_file = b.path(b.fmt("tests/fixtures/import/{s}/src/keymap.zig", .{name})) });
        bundle_check.root_module.addAnonymousImport(b.fmt("import-{s}-manifest", .{name}), .{ .root_source_file = b.path(b.fmt("tests/fixtures/import/{s}/build.zig.zon", .{name})) });
    }
    install(s, bundle_check);
    install(s, catalog_export.?);

    const project = b.addExecutable(.{ .name = "keymap-project", .root_module = s.mods.root("src/project/main.zig", h.keymap_project) });
    s.steps.check.dependOn(&project.step);
    const run_project = b.addRunArtifact(project);
    run_project.addPassthruArgs();
    s.steps.run_project.dependOn(&run_project.step);

    if (cfg.import_root) |root| {
        const analyzer = importer_build.analyzer(b, h.zigmkay, h.keycodes, h.layout, root, cfg.import_module);
        s.steps.analyze_keymap.dependOn(&b.addInstallArtifact(analyzer, .{}).step);
    } else Steps.unavailable(b, s.steps.analyze_keymap, "analyze-keymap requires -Dimport-root=<absolute captured source directory>");
    return .{ .bootsel = bootsel };
}

fn install(s: *tests.Suite, exe: *Compile) void {
    s.steps.tools.dependOn(&s.b.addInstallArtifact(exe, .{}).step);
    s.steps.check.dependOn(&exe.step);
}
