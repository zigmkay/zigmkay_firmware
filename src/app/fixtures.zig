//! Frame scripts and checks of the offline fixture modes. Fixtures inject SDL
//! events and verify native window state; none of them opens a device.
const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const boards = @import("catalog-project");
const project = @import("project");
const keyboard_onboarding = @import("onboarding-ui");
const editor = @import("editor-frame-ui");
const App = @import("App.zig");
const source_refresh_fixture = @import("source_refresh_fixture.zig");

const c = Backend.c;
const overlay_flags = c.SDL_WINDOW_BORDERLESS | c.SDL_WINDOW_ALWAYS_ON_TOP | c.SDL_WINDOW_NOT_FOCUSABLE;

pub const State = struct {
    /// The companion fixture's unsaved draft, which must survive hiding.
    retained: ?[32]u8 = null,
    draft_phase: enum { starting, input, paused } = .starting,
    build_checked: bool = false,
};

/// Scripts that replace the project or the onboarding stage before a frame.
pub fn beforeFrame(app: *App) !void {
    if (app.mode.is(.catalog)) try showCatalogEntry(app);
    if (app.mode.isOnboarding()) try advanceOnboarding(app);
    // The native gallery draws each page twice in the dark, then twice in the light theme.
    if (app.mode.is(.native_onboarding)) app.view.toolbar.light = app.count % 4 >= 2;
    if (app.mode.isDrawers()) try showDrawer(app);
    if (app.mode.is(.native_tutor)) try showTutor(app);
}

/// The tutor gallery shows four scenes for four frames each, twice in the
/// dark and then twice in the light theme: trying the keyboard, an English
/// test, a Zig lesson and a finished English test.
fn showTutor(app: *App) !void {
    app.view.toolbar.light = app.count % 4 >= 2;
    if (app.count % 4 != 0) return;
    const practice = &app.tutor.controller;
    const now: u64 = @intCast(@max(0, app.native.nanoTime()) / 1000);
    const scene = app.count / 4;
    if (scene == 0) return;
    const config: desktop.practice_controller.Config = if (scene == 2) .{ .mode = .zig, .level = 0 } else .{ .level = 1 };
    app.applyPractice(try practice.choose(config, now), &app.model, now);
    app.applyPractice(try practice.start(true, null, now), &app.model, now);
    const session = &practice.session;
    const count = switch (scene) {
        1 => 41,
        2 => 64,
        else => session.reference_len,
    };
    // Typed over the last seconds so that the live speed is plausible.
    const start = now -| 3_000_000 -| 180_000 * count;
    for (session.reference[0..count], 0..) |cp, index| {
        const at = start + 180_000 * index;
        // The English test shows one corrected mistake.
        if (scene == 1 and index == 30) {
            try session.insert("x", at, false);
            session.backspace();
        }
        var bytes: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &bytes);
        try session.insert(bytes[0..len], at, false);
    }
}

/// The drawers fixture shows the combo, callback and encoder drawers, each in
/// the dark and then the light theme for four frames. Combos and callbacks use
/// the Keycaprio 0.7 default; encoders use the first board with encoder slots.
/// A replaced project closes popups, so drawers open one frame after it.
fn showDrawer(app: *App) !void {
    const scene = app.count / 4;
    if (scene >= 6 or scene % 2 == 1) {
        if (app.count % 4 == 0) app.view.toolbar.light = scene % 2 == 1;
        return;
    }
    if (app.count % 4 == 0) {
        app.view.toolbar.light = false;
        var selector: []const u8 = "keycaprio_colemak_0_7";
        if (scene == 4) for (desktop.onboarding.catalog.entries) |entry| if (entry.encoder_action_slots > 0) {
            selector = entry.selector;
            break;
        };
        var selected = try boards.OwnedBoard.init(app.gpa, selector);
        defer selected.deinit();
        var template = try boards.createDefault(app.gpa, selected);
        defer template.deinit();
        var replacement = try desktop.model.Model.init(app.gpa, selected.board, template.snapshot);
        std.mem.swap(desktop.model.Model, &app.model, &replacement);
        replacement.deinit();
        app.owner_generation += 1;
        return;
    }
    if (app.count % 4 != 1) return;
    const view = &app.view;
    switch (scene) {
        0 => {
            view.combo = try desktop.combo_editor.Session.init(&app.model);
            if (app.model.document().combos.len != 0) try view.combo.?.pick(&app.model, 0);
            view.modal = .combo;
        },
        2 => view.modal = .callback,
        else => {
            view.encoders = try desktop.encoder_editor.Session.init(&app.model);
            // One staged, unapplied slot edit.
            if (view.encoders.?.count > 1) view.encoders.?.drafts[1] = .{ .media_key = .VolumeUp };
            view.modal = .encoders;
        },
    }
}

/// Shows each catalog board for four frames, the last two in the tutor.
fn showCatalogEntry(app: *App) !void {
    const entries = desktop.onboarding.catalog.entries;
    if (app.count % 4 == 0 and app.count / 4 < entries.len) {
        var selected = try boards.OwnedBoard.init(app.gpa, entries[app.count / 4].selector);
        defer selected.deinit();
        var template = try boards.createDefault(app.gpa, selected);
        defer template.deinit();
        var replacement = try desktop.model.Model.init(app.gpa, selected.board, template.snapshot);
        std.mem.swap(desktop.model.Model, &app.model, &replacement);
        replacement.deinit();
        app.owner_generation += 1;
    }
    app.practicing = app.count % 4 >= 2;
}

/// The onboarding gallery shows each page for four frames: the first launch,
/// My Keyboards with sample layouts, the catalog, New layout, the import source
/// and the import comparison. Sample layouts exist only in memory.
fn advanceOnboarding(app: *App) !void {
    const onboarding = &app.onboarding;
    switch (app.count) {
        4 => {
            onboarding.replaceLibrary(try sampleLibrary(app));
            onboarding.stage = .home;
        },
        8 => {
            onboarding.stage = .catalog;
            onboarding.catalog = .{ .family = 1, .confirmed = true };
        },
        12 => {
            onboarding.openNewLayout(entryOf("lk7"));
            onboarding.new_layout.template = 3;
        },
        16 => {
            onboarding.clearImport();
            onboarding.stage = .source;
        },
        20 => {
            // A Keycaprio 0.7 keymap, as an analysis would return it, compared
            // with a Keycaprio 0.4 that has four keys fewer.
            const defaults = desktop.onboarding.catalog.defaultData("keycaprio_colemak_0_7").?;
            onboarding.analysis = .{ .arena = .init(app.gpa), .captured = @splat(1), .data = .{
                .layers = defaults.layers,
                .combos = defaults.combos,
                .sides = defaults.sides,
                .encoders = defaults.encoder_actions orelse &.{},
                .has_callbacks = defaults.has_callbacks,
            } };
            onboarding.sample_sources = defaults.callback_sources;
            onboarding.selector = entryOf("keycaprio_colemak_0_4");
            try keyboard_onboarding.State.set(&onboarding.location, "https://github.com/example/keycaprio-keymap");
            try keyboard_onboarding.State.set(&onboarding.name, "Colemak Jan (imported)");
        },
        else => {},
    }
}

/// Layouts on three keyboards, one of them outside the collection.
fn sampleLibrary(app: *App) !desktop.library.Library {
    const gpa = app.gpa;
    var eurmac = try project.profiles.create(gpa, .eurmac);
    defer eurmac.deinit();
    var danish = try project.profiles.create(gpa, .danish);
    defer danish.deinit();
    var eurkey = try project.profiles.create(gpa, .eurkey);
    defer eurkey.deinit();
    var molekula_board = try boards.OwnedBoard.init(gpa, "molekula");
    defer molekula_board.deinit();
    var molekula = try boards.createDefault(gpa, molekula_board);
    defer molekula.deinit();
    var keycaprio_board = try boards.OwnedBoard.init(gpa, "keycaprio_colemak_0_4");
    defer keycaprio_board.deinit();
    var keycaprio = try boards.createDefault(gpa, keycaprio_board);
    defer keycaprio.deinit();
    const now = std.Io.Timestamp.now(app.io, .real).nanoseconds;
    const minute = 60 * std.time.ns_per_s;
    var renamed = eurmac.snapshot.document;
    renamed.name = "EurKEY Next Mac";
    var jan = keycaprio.snapshot.document;
    jan.name = "Colemak Jan";
    return desktop.library.fromSamples(gpa, &.{
        .{ .path = "/collection/keyboards/eurmac", .member = "keyboards/eurmac", .document = renamed, .modified = now - 2 * minute },
        .{ .path = "/collection/keyboards/rollercole", .member = "keyboards/rollercole", .document = danish.snapshot.document, .modified = now - 8 * 24 * 60 * minute },
        .{ .path = "/data/projects/eurkey", .document = eurkey.snapshot.document, .modified = now - 21 * 24 * 60 * minute },
        .{ .path = "/collection/keyboards/jan", .member = "keyboards/jan", .document = jan, .modified = now - 26 * 60 * minute },
        .{ .path = "/collection/keyboards/molekula", .member = "keyboards/molekula", .document = molekula.snapshot.document, .modified = now - 3 * 24 * 60 * minute },
    });
}

/// Starts a draft run on the native runner, typing "aa".
pub fn startDraftRun(app: *App, digest: anytype, now_us: u64) !void {
    const practice = &app.tutor.controller;
    _ = try practice.choose(.{ .source = .draft }, now_us);
    const effect = try practice.start(true, digest, now_us);
    try practice.session.load("aa", .draft);
    try app.draft_runtime.apply(practice, effect, app.build.runner, &app.model, now_us);
}

/// Once the managed startup build finished, verifies it and starts a draft run
/// on its runner.
pub fn checkBuild(app: *App) !void {
    if (!app.mode.is(.build) or app.fixture.build_checked or app.count < 2 or app.jobs.build != null) return;
    const artifact = app.build.artifact orelse {
        std.log.err("Managed editor build failed: {s}", .{std.mem.sliceTo(&app.view.diagnostic, 0)});
        return error.ManagedEditorBuildFailed;
    };
    if (!std.mem.eql(u8, &artifact.inputs.project_digest, &(try app.model.id()))) return error.ManagedEditorBuildStale;
    const runner = app.build.runner orelse return error.ManagedEditorRunnerMissing;
    try runner.verifyFile(app.gpa, app.io, artifact.inputs);
    app.fixture.build_checked = true;
    app.practicing = true;
    try startDraftRun(app, artifact.inputs.project_digest, @intCast(@max(0, app.native.nanoTime()) / 1000));
}

/// Clicks Build on the second frame of the managed startup build fixture.
pub fn requestBuild(app: *App, can_build: bool, rendered: *editor.Result) !void {
    if (!app.mode.is(.build) or app.count != 2) return;
    if (!can_build or app.build.artifact != null or app.jobs.busy()) {
        std.log.err("Managed editor startup: paths={any} resources={any} plan={any} can_build={any} built={any} busy={any}", .{
            app.user_paths != null,
            app.build.resources != null,
            app.build.plan != null,
            can_build,
            app.build.artifact != null,
            app.jobs.busy(),
        });
        return error.ManagedEditorStartupNotIdle;
    }
    const captured = try desktop.editor_dispatch.Request.capture(&app.model, .build);
    rendered.* = .{ .effect = try app.owner.request(&app.model, captured) };
}

/// Per-frame scripts of the window lifecycle and source fixtures.
pub fn script(app: *App) !void {
    if (app.mode.is(.companion)) try companionScript(app);
    if (app.mode.is(.source_refresh)) try source_refresh_fixture.run(app);
    if (app.mode.is(.native_tray)) try nativeTrayScript(app);
}

/// Hides and reopens the editor and the companion independently, then quits
/// once with a dirty draft (cancelled) and once clean (accepted).
fn companionScript(app: *App) !void {
    const life = &app.life;
    const overlay = &app.companion;
    switch (app.count) {
        2 => {
            try app.model.rename("Retained draft");
            app.fixture.retained = try app.model.id();
            life.action(.toggle_companion);
        },
        3 => {
            if (overlay.window == null) return error.CompanionWindowMissing;
            app.events.close = true;
        },
        4 => {
            if (life.editor_visible or app.owner.closed or !life.keepRunning()) return error.ResidentEditorCloseFailed;
            life.action(.open_editor);
            life.action(.toggle_companion);
            _ = c.SDL_ShowWindow(app.native.window);
        },
        5 => {
            if (overlay.window) |id| if (c.SDL_GetWindowFromID(id)) |child| {
                if (c.SDL_GetWindowFlags(child) & c.SDL_WINDOW_HIDDEN == 0) return error.CompanionNativeHideFailed;
            };
            life.action(.toggle_companion);
            overlay.view.overlay = true;
            overlay.view.applied_window = null;
        },
        6 => {
            const id = overlay.window orelse return error.CompanionWindowMissing;
            const child = c.SDL_GetWindowFromID(id) orelse return error.CompanionWindowMissing;
            if (overlay.view.applied_window != id) return error.CompanionModeNotApplied;
            const flags = c.SDL_GetWindowFlags(child);
            if (flags & c.SDL_WINDOW_HIDDEN != 0) return error.CompanionNativeShowFailed;
            const expected: @TypeOf(flags) = if (overlay.view.overlay) overlay_flags else 0;
            if ((flags & overlay_flags) != expected) {
                std.log.err("Companion mode flags: actual={x} expected={x} overlay={any}", .{
                    flags & overlay_flags,
                    expected,
                    overlay.view.overlay,
                });
                return error.CompanionModeFlagsMismatch;
            }
            var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
            event.window.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
            event.window.windowID = id;
            try pushEvent(&event);
        },
        7 => {
            if (life.companion_visible or !life.editor_visible or app.owner.closed) return error.CompanionCloseFailed;
            app.events.quit = true;
        },
        8 => {
            if (app.owner.close_requested == null or app.owner.closed) return error.ResidentDirtyQuitNotGuarded;
            const keep = try desktop.inspector_action.Action.capture(&app.owner.inspector, &app.model, .keep_close);
            _ = try app.owner.inspect(&app.model, keep);
            life.cancelQuit();
        },
        9 => {
            if (app.owner.closed or app.owner.close_requested != null or life.quit_requested or !life.keepRunning() or
                !std.mem.eql(u8, &app.fixture.retained.?, &(try app.model.id()))) return error.ResidentDraftRetentionFailed;
            // Simulate a clean saved document; the accepted Quit then ends the loop.
            app.model.saved_id = try app.model.id();
            var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
            event.type = c.SDL_EVENT_QUIT;
            try pushEvent(&event);
        },
        else => {},
    }
}

/// Shows the companion as an overlay with a real tray and window manager.
fn nativeTrayScript(app: *App) !void {
    const overlay = &app.companion;
    if (app.count == 2) {
        app.life.companion_visible = true;
        overlay.view.overlay = true;
        overlay.view.applied_window = null;
    }
    if (app.count == 3) {
        const id = overlay.window orelse return error.CompanionWindowMissing;
        if (overlay.view.applied_window != id) return error.CompanionModeNotApplied;
        const child = c.SDL_GetWindowFromID(id) orelse return error.CompanionWindowMissing;
        const flags = c.SDL_GetWindowFlags(child);
        const expected: @TypeOf(flags) = if (overlay.view.overlay) overlay_flags else 0;
        if ((flags & overlay_flags) != expected) return error.CompanionModeFlagsMismatch;
        std.log.info("Native companion overlay supported: {any}", .{overlay.view.overlay});
    }
}

/// The status fixture shows each toolbar state for four frames.
pub fn statusScene(app: *const App) usize {
    return if (app.mode.isStatus()) (app.count - 1) / 4 else 0;
}

pub fn resizeStatusWindow(app: *App) void {
    if (app.mode.isDrawers() and app.count == 1) _ = c.SDL_SetWindowSize(app.native.window, 1440, 1000);
    if (!app.mode.isStatus() or (app.count != 1 and app.count != 21)) return;
    const narrow = app.count == 21;
    _ = c.SDL_SetWindowSize(app.native.window, if (narrow) 900 else 1440, if (narrow) 600 else 1000);
}

pub fn showStatusDetails(app: *App) void {
    if (!app.mode.isStatus()) return;
    app.view.toolbar.auto_build = true;
    app.view.toolbar.details_open = statusScene(app) == 4;
    // Scene 3 shows the layout menu, opened by a click on the layout crumb.
    if (statusScene(app) != 3) app.view.toolbar.menu_open = false;
    // Scene 2 shows the Export Zig source sheet.
    app.view.modal = if (statusScene(app) == 2) .paths else .none;
    // Scene 3 shows the flash panel of a failed firmware build.
    app.flash.panel = statusScene(app) == 3;
    app.flash.failure = if (statusScene(app) == 3) error.FirmwareBuildFailed else null;
    // Scenes 0 and 1 open the key editor on F: its tap, then its hold, after
    // F gained a Shift hold.
    const scene = statusScene(app);
    if (scene <= 1 and app.count % 4 == 1) {
        app.model.select(13, false);
        if (scene == 1) {
            const tap = desktop.inspector_session.tapPart(app.model.action());
            app.model.apply(.{ .tap_hold = .{
                .tap = tap,
                .hold = .{ .hold_modifiers = .{ .left_shift = true } },
                .tapping_term = .{ .ms = 200 },
            } }) catch {};
        }
    }
    app.view.key_editor.open = switch (scene) {
        0 => .tap,
        1 => .hold,
        else => null,
    };
    app.view.key_editor.layer = app.model.layer;
}

pub fn statusToolbar(app: *const App, toolbar: *@FieldType(editor.Frame, "toolbar")) void {
    if (!app.mode.isStatus()) return;
    const scene = statusScene(app);
    toolbar.can_build = true;
    toolbar.can_flash = true;
    toolbar.build_active = scene == 0;
    toolbar.first_build = scene == 0;
    toolbar.flash_active = scene == 1;
    toolbar.flash_succeeded = scene == 2;
    toolbar.flash_failed = scene >= 3;
    toolbar.flash_status = switch (scene) {
        0 => "",
        1 => "Transferring firmware to keyboard…",
        2 => "Matching firmware reconnected",
        else => "Flash failed: the selected firmware could not be verified against the current project snapshot. " ++
            "Review the complete diagnostic here before starting a new transfer.",
    };
}

/// Injects the SDL events of the practice and draft fixtures before the pump.
pub fn injectEvents(app: *App) !void {
    if (app.mode.is(.practice) and app.count == 3) try pushFocusLost(app);
    if (app.mode.isStatus() and app.count == 13) try clickCanvas(app, 480, 32);
    if (!app.checkingDraft()) return;
    const state = &app.fixture;
    if (state.draft_phase == .starting and app.draft_runtime.router.runner_running) {
        // A key press and its auto-repeat must produce one practice input.
        var key: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        key.key.type = c.SDL_EVENT_KEY_DOWN;
        key.key.windowID = app.events.root;
        key.key.scancode = 4;
        key.key.down = true;
        try pushEvent(&key);
        key.key.repeat = true;
        try pushEvent(&key);
        state.draft_phase = .input;
    } else if (state.draft_phase == .input and app.tutor.controller.session.len == 1) {
        try pushFocusLost(app);
        state.draft_phase = .paused;
    }
}

/// Types the first reference codepoint as OS text after the pump.
pub fn injectText(app: *App) !void {
    if (!app.mode.is(.practice) or app.count != 2) return;
    var text: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(app.tutor.controller.session.reference[0], &text);
    _ = try app.window.addEventText(.{ .text = text[0..len] });
}

/// Moves the pointer to a point of the design canvas and clicks there.
fn clickCanvas(app: *App, x: f32, y: f32) !void {
    const scale = app.window.content_scale;
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.motion.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.windowID = app.events.root;
    event.motion.x = x * scale;
    event.motion.y = y * scale;
    try pushEvent(&event);
    for ([_]c_uint{ c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP }) |kind| {
        event = std.mem.zeroes(c.SDL_Event);
        event.button.type = kind;
        event.button.windowID = app.events.root;
        event.button.button = c.SDL_BUTTON_LEFT;
        event.button.down = kind == c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.clicks = 1;
        event.button.x = x * scale;
        event.button.y = y * scale;
        try pushEvent(&event);
    }
}

fn pushFocusLost(app: *App) !void {
    var lost: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    lost.window.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
    lost.window.windowID = app.events.root;
    try pushEvent(&lost);
}

fn pushEvent(event: *c.SDL_Event) !void {
    if (!c.SDL_PushEvent(event)) return error.FixtureEventRejected;
}

/// Verifies the drawn frame and saves screenshots of the screenshot fixtures.
pub fn capture(app: *App) !void {
    if (app.mode.isStatus() and app.count % 4 == 0) try captureStatus(app);
    if (app.mode.isDrawers() and app.count % 4 == 0) {
        app.window.endRendering(.{ .manage_backend = false });
        const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/editor-drawers/{d}.bmp", .{(app.count - 1) / 4}, 0);
        try screenshot(app, path, error.DrawerScreenshotRead, error.DrawerScreenshotSave);
    }
    if (app.mode.is(.native_tutor) and app.count % 2 == 0) try captureTutor(app);
    if (app.mode.isOnboarding() or app.mode.is(.catalog)) try captureOnboarding(app);
}

fn captureTutor(app: *App) !void {
    if (dvui.tagGet("practice.word") == null or dvui.tagGet("practice.metrics") == null) return error.TutorNotDrawn;
    app.window.endRendering(.{ .manage_backend = false });
    const scene = (app.count - 1) / 4;
    const theme = if (app.view.toolbar.light) "light" else "dark";
    const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/typing-practice-gallery/{d}-{s}.bmp", .{ scene, theme }, 0);
    try screenshot(app, path, error.TutorScreenshotRead, error.TutorScreenshotSave);
}

/// The activity row stays inside the toolbar, which spans the window.
fn captureStatus(app: *App) !void {
    const activity = dvui.tagGet("editor.activity") orelse return error.ActivityRowMissing;
    const toolbar = (dvui.tagGet("toolbar") orelse return error.ToolbarMissing).rect;
    const row = activity.rect;
    if (row.x < toolbar.x or row.x + row.w > toolbar.x + toolbar.w + 1 or row.y + row.h > toolbar.y + toolbar.h + 1)
        return error.ActivityRowOverflow;
    if (toolbar.x + toolbar.w < dvui.windowRectPixels().w - 3) {
        std.log.err("Activity bounds: toolbar={any}, window={any}, natural={any}, scale={d}", .{
            toolbar,
            dvui.windowRectPixels(),
            dvui.windowRect(),
            app.window.content_scale,
        });
        return error.ActivityToolbarGutter;
    }
    const message = dvui.tagGet("editor.activity.message") orelse return error.ActivityMessageMissing;
    const automatic = dvui.tagGet("firmware.auto_build") orelse return error.AutoBuildControlMissing;
    if (message.rect.x + message.rect.w > automatic.rect.x) return error.ActivityControlsOverlap;
    if (dvui.tagGet("system.status") != null) return error.SeparateStatusBarRetained;
    app.window.endRendering(.{ .manage_backend = false });
    const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/editor-status/{d}.bmp", .{statusScene(app)}, 0);
    try screenshot(app, path, error.StatusScreenshotRead, error.StatusScreenshotSave);
}

/// The wizard never exposes a target or creates its destination before commit.
fn captureOnboarding(app: *App) !void {
    const wizard = app.mode.isOnboarding();
    if (wizard) {
        if (dvui.tagGet("firmware.build") != null or dvui.tagGet("firmware.inspect") != null or app.onboarding.selected)
            return error.ImplicitOnboardingTargetExposed;
        if (app.count <= 3 and dvui.tagGet("onboarding.create") == null) return error.OnboardingControlsMissing;
        if (std.Io.Dir.cwd().statFile(app.io, std.mem.sliceTo(&app.onboarding.root, 0), .{})) |_| {
            return error.OnboardingCreatedDestinationBeforeCommit;
        } else |err| if (err != error.FileNotFound) return err;
    }
    app.window.endRendering(.{ .manage_backend = false });
    const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/keyboard-onboarding-gallery/{s}-{d}.bmp", .{
        if (wizard) "wizard" else "catalog",
        app.count,
    }, 0);
    try screenshot(app, path, error.OnboardingScreenshotRead, error.OnboardingScreenshotSave);
}

/// Saves the rendered frame as a BMP file in the cache.
pub fn screenshot(app: *App, path: [:0]const u8, read_error: anyerror, save_error: anyerror) !void {
    try std.Io.Dir.cwd().createDirPath(app.io, std.fs.path.dirname(path).?);
    const surface = c.SDL_RenderReadPixels(app.native.renderer, null) orelse return read_error;
    defer c.SDL_DestroySurface(surface);
    if (!c.SDL_SaveBMP(surface, path)) return save_error;
}

/// Checks the outcome of the fixtures once the frame loop ended.
pub fn finish(app: *App) !void {
    const session = &app.tutor.controller.session;
    const typed_once = session.len == 1 and session.matched() == 1 and session.state == .paused;
    if (app.mode.is(.practice) and !typed_once) return error.PracticeTextRoutingFailed;
    if (app.mode.isDraft() and (app.fixture.draft_phase != .paused or !typed_once or app.draft_runtime.owner != null))
        return error.DraftProcessorRoutingFailed;
    if (app.mode.is(.build) and !app.fixture.build_checked) return error.ManagedEditorBuildIncomplete;
    if (app.mode.is(.companion)) {
        const retained = app.fixture.retained orelse return error.ResidentDraftRetentionFailed;
        if (!std.mem.eql(u8, &retained, &(try app.model.id()))) return error.ResidentDraftRetentionFailed;
        if (!app.owner.closed) return error.ResidentCleanQuitFailed;
    }
    if (app.mode.is(.native_tray) and !app.tray.installed) return error.NativeTrayLifecycleFailed;
}

fn entryOf(selector: []const u8) usize {
    for (desktop.onboarding.catalog.entries, 0..) |entry, index| if (std.mem.eql(u8, entry.selector, selector)) return index;
    unreachable;
}
