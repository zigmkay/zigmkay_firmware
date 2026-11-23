//! The native editor and companion (`-Ddesktop`): the application
//! executable, `test-desktop` SDL dummy/software fixtures and the explicit
//! `test-native` tray fixture.
const std = @import("std");
const Modules = @import("Modules.zig");
const tests = @import("tests.zig");
const Compile = std.Build.Step.Compile;

/// Consolidated desktop test roots wired when `-Ddesktop` is enabled.
pub const test_roots = [_][]const u8{
    "src/desktop/test_gui_all.zig",
    "src/desktop/icon_resources.zig",
    "src/desktop/key_editor_ui.zig",
    "src/platform/test_gui_all.zig",
    "tests/test_desktop_all.zig",
};

/// Individual desktop test files deferred by `tests-reached` when `-Ddesktop`
/// is disabled.
pub const deferred_test_files = [_][]const u8{
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
    "src/desktop/practice_keyboard_ui.zig",
    "src/desktop/practice_sheets_ui.zig",
    "src/platform/companion_window.zig",
};

/// SDL dummy/software fixtures of the application: flag and frame count.
const fixtures = [_]struct { []const u8, []const u8 }{
    .{ "--offline-frames", "3" },
    .{ "--offline-onboarding-frames", "24" },
    .{ "--offline-catalog-frames", "56" },
    .{ "--offline-status-frames", "24" },
    .{ "--offline-practice-frames", "3" },
    .{ "--offline-tutor-frames", "32" },
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

    const desktop_gui_tests = mods.root("src/desktop/test_gui_all.zig", g.desktop_gui_test_deps);
    for ([_][]const u8{ "tray.png", "tray-template.png", "tray.ico", "window.png", "window@2x.png" }) |name|
        desktop_gui_tests.addAnonymousImport(name, .{ .root_source_file = g.icon_files.path(b, name) });
    _ = s.add(step, .desktop, desktop_gui_tests);
    _ = s.add(step, .desktop, g.icon_resources);
    _ = s.add(step, .desktop, g.key_editor_ui);
    _ = s.unit(step, .desktop, "src/platform/test_gui_all.zig", g.platform_gui_test_deps);
    tests.headless(s.unit(step, .desktop, "tests/test_desktop_all.zig", g.tests_desktop_deps));
    if (test_fixtures.app_tests) |run| step.dependOn(&run.step);

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
