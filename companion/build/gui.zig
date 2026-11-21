//! The native editor and companion (`-Ddesktop`): the application
//! executable, compile-only smoke probes, `test-desktop` SDL dummy/software
//! fixtures and the explicit `test-native` tray fixture.
const std = @import("std");
const Modules = @import("Modules.zig");
const tests = @import("tests.zig");
const Compile = std.Build.Step.Compile;

/// Every desktop test root; `tests-reached` checks it against the wiring.
pub const test_roots = [_][]const u8{
    "tests/desktop_vectors.zig",
    "src/platform/window_placement.zig",
    "src/desktop/application_icons.zig",
    "src/platform/events.zig",
    "tests/editor_frame.zig",
    "src/desktop/icon_resources.zig",
    "src/desktop/components/key.zig",
    "src/desktop/onboarding_ui.zig",
    "src/desktop/keyboard_ui.zig",
    "src/desktop/key_editor_ui.zig",
    "src/platform/companion_window.zig",
};

/// SDL dummy/software fixtures of the application: flag and frame count.
const fixtures = [_]struct { []const u8, []const u8 }{
    .{ "--offline-frames", "3" },
    .{ "--offline-onboarding-frames", "24" },
    .{ "--offline-catalog-frames", "56" },
    .{ "--offline-status-frames", "24" },
    .{ "--offline-practice-frames", "3" },
    .{ "--offline-companion-frames", "9" },
    .{ "--offline-source-refresh-frames", "3" },
};

/// Returns the application executable.
pub fn add(s: *tests.Suite, test_fixtures: tests.Fixtures) *Compile {
    const b = s.b;
    const mods = s.mods;
    const g = mods.gui.?;
    const h = mods.host.?;
    const step = s.steps.test_desktop;

    _ = s.unit(step, .desktop, "tests/desktop_vectors.zig", g.vector_test_deps);
    _ = s.add(step, .desktop, g.placement);
    _ = s.add(step, .desktop, g.application_icons);
    _ = s.add(step, .desktop, g.events);
    tests.headless(s.unit(step, .desktop, "tests/editor_frame.zig", g.editor_frame_test_deps));
    _ = s.add(step, .desktop, g.icon_resources);
    _ = s.unit(step, .desktop, "src/desktop/components/key.zig", g.key_renderer_deps);
    _ = s.add(step, .desktop, g.onboarding_ui);
    _ = s.add(step, .desktop, g.keyboard_ui);
    _ = s.add(step, .desktop, g.key_editor_ui);
    _ = s.add(step, .desktop, g.companion_window);
    for (test_fixtures.flash_session) |run| step.dependOn(&run.?.step);

    // Force native code generation and linkage without running the probes.
    for ([_]*Compile{
        b.addExecutable(.{ .name = "desktop-dependency-smoke", .root_module = mods.root("tools/desktop_dependency_smoke.zig", g.dependency_smoke_deps) }),
        b.addExecutable(.{ .name = "desktop-physical-smoke", .root_module = mods.root("tools/desktop_physical_smoke.zig", g.physical_smoke_deps) }),
    }) |probe| {
        _ = probe.getEmittedBin();
        s.steps.check.dependOn(&probe.step);
    }

    const app = b.addExecutable(.{ .name = "zigmkay-companion", .root_module = mods.root("src/app/main.zig", g.app_deps) });
    if (s.cfg.target.result.os.tag == .windows)
        app.root_module.addWin32ResourceFile(.{ .file = g.icon_files.path(b, "application.rc") });
    s.steps.check.dependOn(&app.step);
    for (fixtures) |fixture| step.dependOn(&tests.addGuiFixture(b, app, &.{ fixture[0], fixture[1] }).step);

    // Draft scoring through the real native processor.
    const manifest_fixture = b.addExecutable(.{ .name = "runner-manifest-fixture", .root_module = mods.root("src/runner/manifest_fixture.zig", h.manifest_fixture_deps) });
    const prepare = b.addRunArtifact(manifest_fixture);
    prepare.addArtifactArg(test_fixtures.runner.?);
    const draft = tests.addGuiFixture(b, app, &.{ "--offline-draft-frames", "600" });
    draft.addFileArg2(prepare.addOutputFileArg("runner-manifest.zon"), .{ .make_absolute = true });
    step.dependOn(&draft.step);

    // Installs and removes a real tray icon with a hidden window.
    const tray = b.addRunArtifact(app);
    tray.addArgs(&.{ "--native-tray-frames", "3" });
    s.steps.test_native.dependOn(&tray.step);
    return app;
}
