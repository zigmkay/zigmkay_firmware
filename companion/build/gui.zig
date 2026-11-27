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
    "src/desktop/practice_key_change_ui.zig",
    "src/desktop/practice_tap_hold_ui.zig",
    "src/platform/companion_window.zig",
};

/// SDL dummy/software fixtures of the application: flag and frame count.
const fixtures = [_]struct { []const u8, []const u8 }{
    .{ "--offline-frames", "3" },
    .{ "--offline-host-layout-frames", "3" },
    .{ "--offline-linux-setup-frames", "8" },
    .{ "--offline-onboarding-frames", "24" },
    .{ "--offline-catalog-frames", "56" },
    .{ "--offline-status-frames", "68" },
    .{ "--offline-practice-frames", "3" },
    .{ "--offline-tutor-frames", "124" },
    .{ "--offline-companion-frames", "9" },
    .{ "--offline-source-refresh-frames", "3" },
};

/// Dark gallery scenes (`src/app/fixtures.zig`) the documentation shows,
/// relative to the companion directory.
const doc_screenshots = [_]struct { []const u8, []const u8 }{
    .{ "0", "docs/screenshots/typing-practice/active-practice.png" },
    .{ "0", "../assets/screenshots/tutor.png" },
    .{ "1", "docs/screenshots/typing-practice/shift-guidance.png" },
    .{ "2", "docs/screenshots/typing-practice/layers-combos.png" },
    .{ "3", "docs/screenshots/typing-practice/next-lesson.png" },
    .{ "4", "docs/screenshots/typing-practice/stages.png" },
    .{ "5", "docs/screenshots/typing-practice/progress.png" },
    .{ "6", "docs/screenshots/typing-practice/test-keys.png" },
    .{ "22", "docs/screenshots/typing-practice/test-layout-released.png" },
    .{ "15", "docs/screenshots/typing-practice/tap-hold-test-layout.png" },
    .{ "16", "docs/screenshots/typing-practice/tap-hold-tutor.png" },
    .{ "17", "docs/screenshots/typing-practice/tap-hold-progress.png" },
    .{ "24", "docs/screenshots/typing-practice/new-profile.png" },
    .{ "25", "docs/screenshots/typing-practice/profiles.png" },
    .{ "26", "docs/screenshots/typing-practice/refresh-lesson.png" },
    .{ "7", "docs/screenshots/typing-practice/settings.png" },
};

/// Returns the application executable.
pub fn add(s: *tests.Suite, test_fixtures: tests.Fixtures) *Compile {
    const b = s.b;
    const mods = s.mods;
    const g = mods.gui.?;
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
    if (s.cfg.target.result.os.tag == .windows) {
        app.root_module.addWin32ResourceFile(.{ .file = g.icon_files.path(b, "application.rc") });
        // A double-clicked release opens no console window next to the
        // editor. Development builds keep the console for their log output.
        if (s.cfg.release) app.subsystem = .windows;
    }
    s.steps.check.dependOn(&app.step);
    for (fixtures) |fixture| step.dependOn(&tests.addGuiFixture(b, app, &.{ fixture[0], fixture[1] }).step);

    // Renders the Tutor gallery again and rewrites the PNGs the docs show.
    const gallery = tests.addGuiFixture(b, app, &.{ "--offline-tutor-frames", "124" });
    gallery.setCwd(b.path("."));
    const converter = b.addExecutable(.{ .name = "doc-screenshots", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/doc_screenshots.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }) });
    s.steps.check.dependOn(&converter.step);
    const convert = b.addRunArtifact(converter);
    convert.setCwd(b.path("."));
    convert.addArg(".zig-cache/typing-practice-gallery");
    for (doc_screenshots) |shot| convert.addArg(b.fmt("{s}-dark.bmp={s}", .{ shot[0], shot[1] }));
    convert.step.dependOn(&gallery.step);
    s.steps.doc_screenshots.dependOn(&convert.step);

    // Installs and removes a real tray icon with a hidden window.
    const tray = b.addRunArtifact(app);
    tray.addArgs(&.{ "--native-tray-frames", "3" });
    s.steps.test_native.dependOn(&tray.step);
    return app;
}
