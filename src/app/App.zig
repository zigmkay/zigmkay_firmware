//! The desktop application: the keyboard editor, the typing tutor, the
//! companion overlay and the tray, driven by one SDL frame loop.
//!
//! `App` must not move after `init`: the DVUI window, the SDL event hooks
//! and the tutor keep pointers into it.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const jobs_api = @import("companion-jobs");
const project = @import("project");
const boards = @import("catalog-project");
const editor = @import("editor-frame-ui");
const keyboard_onboarding = @import("onboarding-ui");
const dialog = @import("folder-dialog");
const Source = @import("input-source").Source;
const installed = @import("app-paths");
const tray_backend = @import("native-tray");
const native_events = @import("native-events");
const editor_fonts = @import("editor-fonts");
const editor_ui = @import("editor-ui");
const window_icon = @import("window_icon.zig");

const Captions = @import("Captions.zig");
const CompanionOverlay = @import("CompanionOverlay.zig");
const Events = @import("Events.zig");
const Flash = @import("Flash.zig");
const LiveKeyboard = @import("LiveKeyboard.zig");
const OfflineTranslator = @import("OfflineTranslator.zig");
const Tutor = @import("Tutor.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const fixtures = @import("fixtures.zig");
const onboarding_flow = @import("onboarding_flow.zig");
const preferences = @import("preferences.zig");
const screens = @import("screens.zig");
const tray_menu = @import("tray_menu.zig");
const workers = @import("workers.zig");

const App = @This();

/// How the frame loop continues after one step of a frame.
pub const Flow = enum {
    proceed,
    /// Skip the rest of this frame.
    next_frame,
    /// Leave the frame loop.
    stop,
};

/// Firmware build inputs and the accepted build products.
pub const Build = struct {
    plan: ?desktop.build_worker.Plan = null,
    resources: ?desktop.application_bundle.Bundle = null,
    tools: ?jobs_api.flash_inputs.Tools = null,
    artifact: ?desktop.build_worker.Artifact = null,
    /// Native tutor runner of the accepted build.
    runner: ?desktop.build_worker.Runner = null,
    /// Job generation of the accepted build.
    generation: u64 = 0,
    tree: jobs_api.firmware.Digest = @splat(0),
    scheduler: desktop.auto_build.Scheduler = .{},
};

gpa: std.mem.Allocator,
io: std.Io,
environ_map: *const std.process.Environ.Map,
mode: cli.Mode,
frame_limit: ?usize,
live_enabled: bool,

model: desktop.model.Model,
owner: desktop.editor_dispatch.State,
/// Increments whenever the editor's project is replaced.
owner_generation: u64 = 1,
accepted_editor_generation: u64 = 1,
view: editor.View = .{},
onboarding: keyboard_onboarding.State,
onboarding_chooser_generation: ?u64 = null,
registry: desktop.profile_projects.Registry,
user_paths: ?installed.OwnedPaths = null,
chooser: desktop.folder_selection.State = .{},
exported: ?[32]u8 = null,

/// Host keyboard layout; fixtures translate with `translator` instead.
source: ?Source = null,
translator: OfflineTranslator = .{},
/// Increments whenever the host input source changes.
revision: u64 = 1,
captions: Captions,

native: Backend,
window: dvui.Window,
tray: tray_backend.NativeTray,
life: desktop.tray_lifecycle.Lifecycle,
companion: CompanionOverlay = .{},
events: Events,
interrupted: bool = false,
fonts_installed: bool = false,
count: usize = 0,

live: LiveKeyboard,

practicing: bool,
tutor: Tutor,
draft_runtime: desktop.runner_runtime.Runtime,

job_generation: u64 = 0,
jobs: workers.Jobs = .{},
build: Build = .{},
flash: Flash = .{},
fixture: fixtures.State = .{},

pub fn init(app: *App, process: std.process.Init, mode: cli.Mode) !void {
    const gpa = process.gpa;
    const io = process.io;
    const frame_limit = mode.frameLimit();
    const live_enabled = mode.liveEnabled();
    std.log.info("Keyboard monitoring: {s}", .{if (live_enabled) "enabled" else "offline"});
    app.* = .{
        .gpa = gpa,
        .io = io,
        .environ_map = process.environ_map,
        .mode = mode,
        .frame_limit = frame_limit,
        .live_enabled = live_enabled,
        .model = try initialModel(gpa, mode),
        .owner = undefined,
        .onboarding = undefined,
        .registry = desktop.profile_projects.Registry.init(gpa),
        .captions = undefined,
        .native = undefined,
        .window = undefined,
        .tray = undefined,
        .life = undefined,
        .events = undefined,
        .live = undefined,
        .practicing = mode.is(.practice) or mode.is(.native_tutor) or mode.is(.draft) or mode.light() == .tutor,
        .tutor = undefined,
        .draft_runtime = undefined,
    };
    errdefer app.model.deinit();
    errdefer app.registry.deinit();
    app.owner = try desktop.editor_dispatch.State.init(&app.model);
    errdefer app.owner.deinit();
    try app.initOnboarding();
    errdefer app.onboarding.deinit();
    app.view.toolbar.light = mode.light() != null;
    errdefer if (app.user_paths) |*owned| owned.deinit();
    if (frame_limit == null or mode.is(.build)) try app.loadUserPaths();
    if (mode.live()) |live| if (live.project) |path| try app.openLiveProject(path);

    app.source = if (frame_limit == null) Source.init() else null;
    errdefer if (app.source) |*source| source.deinit();
    app.captions = try app.captionsFor(&app.model, "Offline launch fixture");
    errdefer app.captions.deinit();
    if (builtin.os.tag == .linux) _ = Backend.c.SDL_SetHint(Backend.c.SDL_HINT_APP_ID, "zigmkay");
    app.native = try Backend.initWindow(.{
        .io = io,
        .size = if (frame_limit != null) .{ .w = 1536, .h = 1024 } else .{
            .w = desktop.geometry.initial.w,
            .h = desktop.geometry.initial.h,
        },
        .min_size = .{ .w = desktop.geometry.minimum.w, .h = desktop.geometry.minimum.h },
        .title = "Zigmkay Editor",
        .vsync = true,
        .hidden = frame_limit != null or mode.background(),
        .persist_window_geometry = false,
    });
    errdefer app.native.deinit();
    window_icon.apply(app.native.window);
    app.window = try dvui.Window.init(@src(), gpa, app.native.backend(), .{});
    errdefer app.window.deinit();
    app.tray = tray_backend.NativeTray.init(.{ .allocator = gpa, .io = io }, frame_limit == null or mode.is(.native_tray));
    errdefer app.tray.deinit();
    if (mode.is(.native_tray) and !app.tray.installed) return error.NativeTrayUnavailable;
    if (mode.background() and !app.tray.installed) return error.BackgroundTrayUnavailable;
    app.life = .{
        .resident = app.tray.installed or mode.is(.companion),
        .editor_visible = !mode.background(),
        .companion_visible = mode.light() == .companion,
    };

    try app.initLive();
    errdefer app.live.deinit();
    app.events = .{ .io = io, .root = Backend.c.SDL_GetWindowID(app.native.window) };
    try app.initTutor();
    errdefer app.tutor.deinit();
    errdefer if (app.build.tools) |*tools| tools.deinit();
    errdefer if (app.build.resources) |*resources| resources.deinit();
    try app.loadBundle();
    errdefer if (app.build.runner) |*runner| runner.deinit();
    app.draft_runtime = desktop.runner_runtime.Runtime.init(gpa, io, app.events.root, frame_limit != null);
    errdefer app.draft_runtime.deinit();
    app.events.draft = &app.draft_runtime;
    app.events.practice = &app.tutor.controller;
    app.events.model = &app.model;
    app.events.view = &app.view;
    if (mode.fixtureKind()) |kind| if (kind == .draft) try app.loadRunnerManifest(kind.draft);
}

/// Releases everything in the reverse order of `init`.
pub fn deinit(app: *App) void {
    app.draft_runtime.deinit();
    if (app.build.runner) |*runner| runner.deinit();
    if (app.build.artifact) |*artifact| artifact.deinit();
    app.flash.deinit();
    if (app.build.resources) |*resources| resources.deinit();
    if (app.build.tools) |*tools| tools.deinit();
    app.jobs.cancel();
    app.tutor.deinit();
    app.live.deinit();
    app.tray.deinit();
    app.window.deinit();
    app.native.deinit();
    app.captions.deinit();
    if (app.source) |*source| source.deinit();
    if (app.user_paths) |*owned| owned.deinit();
    app.registry.deinit();
    app.onboarding.deinit();
    app.owner.deinit();
    app.model.deinit();
    if (app.build.plan) |plan| project.owned_zon.free(app.gpa, plan);
    app.* = undefined;
}

fn initialModel(gpa: std.mem.Allocator, mode: cli.Mode) !desktop.model.Model {
    var template = try project.profiles.create(gpa, if (mode.is(.draft)) .eurkey else .qwerty);
    defer template.deinit();
    return desktop.model.Model.init(gpa, project.profiles.board, template.snapshot);
}

/// Onboarding opens first, except in fixtures and in the tutor and companion
/// previews, which start with the built-in project.
fn initOnboarding(app: *App) !void {
    const wizard = app.mode.isOnboarding();
    const preview = app.mode.light() == .tutor or app.mode.light() == .companion;
    app.onboarding = .{
        .active = wizard or (app.frame_limit == null and !preview),
        .selected = !wizard and (app.frame_limit != null or preview),
    };
    if (!wizard) return;
    errdefer app.onboarding.deinit();
    // The wizard fixture must never create its destination.
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(app.io, ".", app.gpa);
    defer app.gpa.free(cwd);
    const root = try std.fs.path.join(app.gpa, &.{ cwd, ".zig-cache/onboarding-uncreated/My Keyboards" });
    defer app.gpa.free(root);
    try app.onboarding.defaults(root);
}

fn loadUserPaths(app: *App) !void {
    app.user_paths = preferences.installedPaths(app.gpa, app.io, app.environ_map) catch |err| {
        if (app.mode.is(.build)) {
            std.log.err("Managed editor startup path resolution failed: {s}", .{@errorName(err)});
            return err;
        }
        return app.view.report(err);
    };
    try preferences.loadStartup(app, app.user_paths.?.paths);
}

/// Opens the absolute project directory given to a `--live` mode.
fn openLiveProject(app: *App, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or path.len >= app.view.paths.project.len) return error.AbsoluteProjectPathRequired;
    app.view.paths.project = @splat(0);
    @memcpy(app.view.paths.project[0..path.len], path);
    _ = try workers.fileOperation(app.gpa, app.io, &app.view, &app.model, app.view.paths.action(try app.model.id(), .open));
    app.onboarding.active = false;
    app.onboarding.selected = true;
    try app.owner.sync(&app.model);
}

/// Binds the live session to the startup project, frozen independently of
/// all later editor changes. Monitoring waits for a selected project.
fn initLive(app: *App) !void {
    const gpa = app.gpa;
    var model = try desktop.model.Model.init(gpa, app.model.board, app.model.current.snapshot);
    errdefer model.deinit();
    var binding = try app.prepareBinding(&model);
    errdefer binding.deinit();
    const identity = if (app.live_enabled and app.onboarding.selected)
        try project.snapshot.identity(gpa, model.current.snapshot, model.board)
    else
        null;
    var seed: u32 = 0;
    if (app.live_enabled) try std.Io.randomSecure(app.io, std.mem.asBytes(&seed));
    const driver = if (identity) |value| try LiveKeyboard.Driver.init(.{ .io = app.io }, value, seed, null) else null;
    const visibility: @FieldType(desktop.live_keyboard.Visibility, "mode") = if (app.mode.live()) |live| switch (live.visibility) {
        .tap_hold => .tap_hold,
        .hold => .hold,
        .toggle => .toggle,
    } else .tap_hold;
    app.live = .{
        .model = model,
        .captions = binding.captions,
        .board = binding.board,
        .identity = identity,
        .driver = driver,
        .seed = seed,
        .visibility = .{ .mode = visibility },
    };
}

fn initTutor(app: *App) !void {
    app.tutor = .{ .controller = desktop.practice_controller.Controller.init(try app.model.id()) };
    const practice = &app.tutor.controller;
    if (app.mode.is(.practice)) _ = try practice.dispatch(practice.action(.{ .start = true }), null, 0);
    if (app.frame_limit == null) try std.Io.randomSecure(app.io, std.mem.asBytes(&practice.seed));
}

/// Opens the application bundle that holds the build toolchain and the
/// flash tools.
fn loadBundle(app: *App) !void {
    const executable = try std.process.executablePathAlloc(app.io, app.gpa);
    defer app.gpa.free(executable);
    const owned = app.user_paths orelse return;
    const Bundle = desktop.application_bundle.Bundle;
    const opened = if (builtin.os.tag == .windows)
        Bundle.fromExecutable(app.gpa, app.io, executable, owned.paths.cache)
    else
        Bundle.open(app.gpa, app.io, owned.paths.resources);
    app.build.resources = opened catch |err| {
        if (app.mode.is(.build)) {
            std.log.err("Managed editor startup bundle loading failed: {s}", .{@errorName(err)});
            return err;
        }
        return;
    };
    app.build.tools = try desktop.application_bundle.tools(app.gpa, app.build.resources.?);
}

/// Prepares a draft run on the runner of the `--offline-draft-frames` manifest.
fn loadRunnerManifest(app: *App, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(32 * 1024));
    defer app.gpa.free(bytes);
    app.build.runner = try desktop.build_worker.Runner.parse(app.gpa, bytes);
    try fixtures.startDraftRun(app, app.build.runner.?.record.inputs.project_digest, 0);
}

pub fn run(app: *App) !void {
    while (!app.owner.closed) {
        if (try app.frame() == .stop) break;
    }
    try fixtures.finish(app);
}

fn frame(app: *App) !Flow {
    try fixtures.beforeFrame(app);
    try onboarding_flow.poll(app);
    if (try Flash.monitorTrial(app) == .stop) return .stop;
    try app.pollLive();
    try fixtures.checkBuild(app);
    if (app.draftFinished()) return .stop;
    if (app.frame_limit) |limit| if (app.count == limit) return .stop;
    app.count += 1;

    tray_menu.handle(app);
    tray_menu.updateResidency(app);
    try app.refreshBuildPlan();
    if (try tray_menu.waitWhileIdle(app) == .next_frame) return .next_frame;
    try fixtures.script(app);
    const polled = try workers.poll(app);
    if (polled != .proceed) return polled;

    const now_us: u64 = @intCast(@max(0, app.native.nanoTime()) / 1000);
    app.acceptEditorGeneration(now_us);
    try Flash.step(app, now_us);
    try app.refreshSource(now_us);
    const control_model = try Tutor.observe(app, now_us);
    app.prepareEvents(control_model, now_us);
    try app.refreshCaptions();
    try app.pollFolderDialog();

    var board = try boards.OwnedBoard.fromDocument(app.gpa, app.model.document());
    defer board.deinit();
    const drawn = try app.draw(&board, now_us);
    return app.finishFrame(&board, drawn, control_model, now_us);
}

/// Values of the displayed frame that are acted on after it.
const Drawn = struct {
    delay: ?u32,
    can_build: bool,
    screen: screens.Screen,
    flash_panel: Flash.Panel,
};

fn draw(app: *App, board: *const boards.OwnedBoard, now_us: u64) !Drawn {
    fixtures.resizeStatusWindow(app);
    app.fitWindow();
    try app.window.begin(if (app.frame_limit == null) app.window.beginWait(app.interrupted) else app.native.nanoTime());
    errdefer _ = app.window.end(.{ .manage_backend = app.frame_limit == null }) catch {};
    // DVUI rounds its render scale to hundredths. Keep the fitted editor
    // aligned with the exact pixel edge, including on Retina displays.
    if (!app.practicing and app.window.data().rect.w > 0) app.window.natural_scale = app.window.rect_pixels.w / app.window.data().rect.w;
    if (!app.fonts_installed and (app.frame_limit == null or app.mode.is(.native_tutor) or app.mode.isStatus() or app.mode.isDrawers() or
        app.mode.isOnboarding() or app.mode.is(.catalog)))
    {
        try editor_fonts.install(app.gpa, app.io);
        app.fonts_installed = true;
    }
    try fixtures.injectEvents(app);
    app.events.time_count = 0;
    try native_events.pump(&app.native, &app.window, &app.events);
    try fixtures.injectText(app);
    if (app.events.lost_focus) {
        app.events.lost_focus = false;
        app.applyPractice(app.tutor.controller.pause(now_us), &app.model, now_us);
    }

    const can_build = app.canBuild(board);
    fixtures.showStatusDetails(app);
    app.view.callback.busy = app.jobs.busy();
    const practice = try Tutor.prepareFrame(app, board);
    var screen = try screens.draw(app, board, practice, can_build, now_us);
    const flash_panel = Flash.drawPanel(app);
    try Flash.startTrial(app, can_build, &screen.rendered);
    try fixtures.requestBuild(app, can_build, &screen.rendered);
    try CompanionOverlay.update(app, board, practice);
    app.tray.update(.{ .live_mode = app.live_enabled, .status = app.live.status(), .companion_visible = app.life.companion_visible });
    try fixtures.capture(app);

    const delay = try app.window.end(.{ .manage_backend = app.frame_limit == null });
    if (app.frame_limit != null) app.native.renderPresent();
    return .{ .delay = delay, .can_build = can_build, .screen = screen, .flash_panel = flash_panel };
}

/// Scales the design canvas to the window and applies the theme.
fn fitWindow(app: *App) void {
    const window = &app.window;
    const available = window.backend.windowSize();
    const system_scale = window.backend.contentScale();
    // Match the reference editor: fit the whole design canvas, accounting for
    // macOS display density. Menu zoom is relative to that fitted size.
    const fitted_scale = desktop.geometry.fitScale(available.w / system_scale, available.h / system_scale);
    // Practice has a responsive canvas; keep its controls readable in the
    // native minimum window instead of shrinking the editor's fixed canvas.
    const scale = if (app.practicing) @max(@as(f32, 0.8), fitted_scale) else fitted_scale;
    window.content_scale = scale * app.life.editor_scale;
    window.snap_to_pixels = window.content_scale == 1;
    window.themeSet(editor_ui.dvuiTheme(window, app.view.toolbar.light));
}

fn finishFrame(app: *App, board: *const boards.OwnedBoard, drawn: Drawn, control_model: *desktop.model.Model, now_us: u64) !Flow {
    Tutor.finishFrame(app, drawn.screen.tutor, control_model, now_us);
    try Flash.afterFrame(app, drawn.flash_panel, now_us);
    try onboarding_flow.apply(app, drawn.screen.onboarding);
    if (try commands.apply(app, drawn.screen.rendered, board, drawn.can_build) != .proceed) return .next_frame;
    try app.handleWindowRequests(now_us);
    try app.scheduleBuild(drawn.can_build, now_us);
    // Never enter SDL's potentially unbounded wait after accepting Quit.
    if (app.owner.closed) {
        if (app.mode.is(.companion) and (app.count != 9 or !app.life.quit_requested)) return error.ResidentCleanQuitFailed;
        return .stop;
    }
    if (app.frame_limit == null) {
        const busy = app.jobs.busy() or app.draft_runtime.owner != null;
        const budget = desktop.live_keyboard.waitBudget(app.live_enabled, busy, false);
        app.interrupted = try app.native.waitEventTimeout(@min(app.window.waitTime(drawn.delay), budget));
    }
    if (app.mode.isDraft()) try std.Io.sleep(app.io, .fromMilliseconds(10), .awake);
    return .proceed;
}

fn draftFinished(app: *const App) bool {
    return app.checkingDraft() and app.fixture.draft_phase == .paused and
        app.tutor.controller.session.state == .paused and app.draft_runtime.owner == null;
}

/// Whether a draft fixture is feeding key events through the runner.
pub fn checkingDraft(app: *const App) bool {
    return app.mode.is(.draft) or (app.mode.is(.build) and app.fixture.build_checked);
}

fn pollLive(app: *App) !void {
    const visible = try app.live.poll() orelse return;
    app.life.companion_visible = visible;
    CompanionOverlay.hideIfSuppressed(app);
}

/// Plans builds for the editor's board with the bundled toolchain.
fn refreshBuildPlan(app: *App) !void {
    if (!app.onboarding.selected) return;
    const bundle = app.build.resources orelse return;
    const owned = app.user_paths orelse return;
    if (app.build.plan) |plan| if (std.mem.eql(u8, &plan.config.board_id, &app.model.board.id)) return;
    var selected = try boards.OwnedBoard.fromDocument(app.gpa, app.model.document());
    defer selected.deinit();
    if (app.build.plan) |old| project.owned_zon.free(app.gpa, old);
    app.build.plan = null;
    app.build.plan = try desktop.application_bundle.plan(app.gpa, bundle, owned.paths.cache, selected.entry.selector, app.model.board.id);
}

/// Drops build products and editor popups of a replaced project.
fn acceptEditorGeneration(app: *App, now_us: u64) void {
    if (app.accepted_editor_generation == app.owner_generation) return;
    app.accepted_editor_generation = app.owner_generation;
    app.discardEditorWork();
    app.closePopups();
    app.view.host.drag = null;
    app.view.keyboard.drag = null;
    if (app.tutor.controller.active or app.draft_runtime.owner != null)
        app.draft_runtime.fail(&app.tutor.controller, error.PracticeProjectSwitched, now_us);
}

/// A host input source change pauses the run, which can no longer be scored.
fn refreshSource(app: *App, now_us: u64) !void {
    const source = if (app.source) |*value| value else return;
    if (!source.refresh()) return;
    app.revision = try std.math.add(u64, app.revision, 1);
    const practice = &app.tutor.controller;
    app.applyPractice(practice.pause(now_us), &app.model, now_us);
    if (practice.active) {
        practice.session.scored = false;
        practice.failure = error.PracticeContextChanged;
    }
}

fn prepareEvents(app: *App, control_model: *desktop.model.Model, now_us: u64) void {
    app.events.now_us = now_us;
    app.events.model = control_model;
    app.draft_runtime.router.owns_practice_input = app.practicing;
    app.draft_runtime.router.focused = app.focused();
}

fn refreshCaptions(app: *App) !void {
    if (app.captions.revision != app.revision or !std.mem.eql(u8, &app.captions.snapshot, &(try app.model.id()))) {
        const replacement = try app.captionsFor(&app.model, "Offline launch fixture");
        app.captions.deinit();
        app.captions = replacement;
    }
    // Running captions follow the source only: they must never take the
    // labels of an unsaved editor draft.
    if (app.source) |*source| {
        app.live.captions.refresh(app.gpa, &app.live.model, source, source.id(), app.revision) catch |err| app.view.report(err);
    }
}

/// Accepts the folder of a chooser that still belongs to the same editor.
fn pollFolderDialog(app: *App) !void {
    const completion = dialog.pollCorrelated() orelse return;
    const ticket = app.chooser.pending orelse return;
    if (completion.token != ticket.generation or !app.chooser.accept(ticket, app.owner_generation, try app.model.id())) return;
    const path = completion.path catch |err| return app.view.report(err);
    if (path[0] == 0) return;
    const wizard_current = app.onboarding_chooser_generation == app.onboarding.generation;
    switch (ticket.target) {
        .project => app.view.paths.project = path,
        .export_directory => app.view.paths.exported = path,
        .callback_source => app.view.callback.root = path,
        .onboarding_source, .onboarding_open => if (wizard_current) {
            app.onboarding.location = path;
        },
        .onboarding_location => if (wizard_current) {
            app.onboarding.root = path;
        },
    }
}

/// Hides the editor on close while resident; Quit closes the project.
fn handleWindowRequests(app: *App, now_us: u64) !void {
    if (app.events.close) {
        app.events.close = false;
        app.leaveEditorModes(now_us);
        if (app.life.resident) {
            app.life.editor_visible = false;
            _ = Backend.c.SDL_HideWindow(app.native.window);
        } else app.events.quit = true;
    }
    if (app.events.quit) {
        app.events.quit = false;
        app.leaveEditorModes(now_us);
        app.life.action(.quit);
        const close = try desktop.editor_dispatch.Request.capture(&app.model, .close);
        if (app.owner.request(&app.model, close)) |_| {} else |err| app.view.report(err);
        if (!app.owner.closed) {
            app.life.editor_visible = true;
            _ = Backend.c.SDL_ShowWindow(app.native.window);
        }
    }
}

fn leaveEditorModes(app: *App, now_us: u64) void {
    app.closePopups();
    app.practicing = false;
    app.applyPractice(app.tutor.controller.pause(now_us), &app.model, now_us);
}

/// Starts an automatic build once the editor settles on a new snapshot.
fn scheduleBuild(app: *App, can_build: bool, now_us: u64) !void {
    const scheduler = &app.build.scheduler;
    scheduler.observe(try app.model.id(), now_us / 1000);
    const blocked = app.onboarding.active or !app.onboarding.selected or !app.view.toolbar.auto_build or
        app.build.plan == null or !can_build or app.jobs.busy() or app.flash.pending != null or
        desktop.flash_presenter.blocksAutoBuild(app.flash.phase()) or app.practicing or app.view.modal != .none or
        app.owner.closed or app.owner.close_requested != null or app.editorBusy();
    if (!scheduler.take(now_us / 1000, blocked)) return;
    const next_job = try std.math.add(u64, app.job_generation, 1);
    app.jobs.build = workers.startBuild(app, app.build.plan.?.config, next_job) catch |err| return app.view.report(err);
    app.job_generation = next_job;
    app.flash.discard();
    app.view.diagnostic = @splat(0);
}

/// Whether the editor's board can be built with the planned toolchain.
fn canBuild(app: *App, board: *const boards.OwnedBoard) bool {
    if (!app.onboarding.selected) return false;
    const plan = app.build.plan orelse return false;
    return !app.jobs.busy() and std.mem.eql(u8, &plan.config.board_id, &app.model.board.id) and
        std.mem.eql(u8, plan.config.build_board, board.entry.selector);
}

pub fn applyPractice(app: *App, effect: desktop.practice_controller.Effect, model: *const desktop.model.Model, now_us: u64) void {
    const practice = &app.tutor.controller;
    app.draft_runtime.apply(practice, effect, app.build.runner, model, now_us) catch |err| {
        app.draft_runtime.fail(practice, err, now_us);
        app.view.report(err);
    };
}

pub fn focused(app: *const App) bool {
    return app.frame_limit != null or Backend.c.SDL_GetWindowFlags(app.native.window) & Backend.c.SDL_WINDOW_INPUT_FOCUS != 0;
}

/// Whether an inspector edit or an editor request is unfinished.
pub fn editorBusy(app: *const App) bool {
    return app.owner.inspector.dirty() or app.owner.pending != null;
}

pub fn unsavedChanges(app: *const App) bool {
    return app.model.dirty() or app.editorBusy();
}

pub fn setDiagnostic(app: *App, message: []const u8) void {
    app.view.diagnostic = @splat(0);
    @memcpy(app.view.diagnostic[0..message.len], message);
}

/// Drops jobs and build products of the editor's previous project.
pub fn discardEditorWork(app: *App) void {
    app.jobs.cancel();
    if (app.build.artifact) |*artifact| artifact.deinit();
    app.build.artifact = null;
    if (app.build.runner) |*runner| runner.deinit();
    app.build.runner = null;
    app.exported = null;
    app.flash.pending = null;
    app.flash.advance = false;
    app.build.scheduler = .{};
}

pub fn closePopups(app: *App) void {
    app.view.modal = .none;
    app.view.combo = null;
    app.view.encoders = null;
}

fn profileKey(app: *const App) desktop.profile_projects.Key {
    return .{ .board_id = app.model.document().board_id, .profile_id = app.model.document().profile_id };
}

/// Associates `path` with the board profile of the editor's project.
pub fn associateProfile(app: *App, path: []const u8) void {
    app.registry.set(app.profileKey(), path) catch |err| app.view.report(err);
}

/// Remembers the editor's project for the next startup.
pub fn rememberProject(app: *App) void {
    const owned = app.user_paths orelse return;
    const path = std.mem.sliceTo(&app.view.paths.project, 0);
    preferences.remember(app.gpa, app.io, owned.paths, path, app.profileKey()) catch |err| app.view.report(err);
}

/// Translates the labels of `model` through the host input source.
pub fn captionsFor(app: *App, model: *const desktop.model.Model, offline_identity: []const u8) !Captions {
    if (app.source) |*source| return Captions.init(app.gpa, model, source, source.id(), app.revision);
    return Captions.init(app.gpa, model, &app.translator, offline_identity, app.revision);
}

pub fn prepareBinding(app: *App, model: *const desktop.model.Model) !LiveKeyboard.Binding {
    var captions = try app.captionsFor(model, "Offline live fixture");
    errdefer captions.deinit();
    return .{ .captions = captions, .board = try boards.OwnedBoard.fromDocument(app.gpa, model.document()) };
}
