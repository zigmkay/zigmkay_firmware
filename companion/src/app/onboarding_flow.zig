//! Keyboard onboarding: the wizard's requests and the project it opens.
const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("desktop-core");
const keyboard_onboarding = @import("onboarding-ui");
const dialog = @import("folder-dialog");
const project = @import("project");
const App = @import("App.zig");
const LiveKeyboard = @import("LiveKeyboard.zig");
const commands = @import("commands.zig");
const workers = @import("workers.zig");

/// Accepts a project or collection that the wizard finished opening.
pub fn poll(app: *App) !void {
    const onboarding = &app.onboarding;
    // A new collection location from the chooser reloads My Keyboards.
    if (!std.mem.eql(u8, &onboarding.root, &onboarding.listed_root)) {
        onboarding.listed_root = onboarding.root;
        onboarding.reloadCollection(app.gpa, app.io) catch |err| onboarding.report(err);
        refreshLibrary(app);
    }
    try openWhenSaved(app);
    onboarding.refreshCandidate(app.gpa, app.io);
    onboarding.refreshComparison(app.gpa, app.io);
    if (onboarding.create_ready and onboarding.worker == null) {
        onboarding.create_ready = false;
        try start(app, .create);
    }
    const result = onboarding.poll(app.owner_generation) catch |err| failed: {
        onboarding.report(err);
        break :failed null;
    };
    var opened = result orelse return;
    defer opened.deinit();
    if (opened.model == null) {
        try keyboard_onboarding.State.set(&onboarding.root, opened.collection.?);
        try onboarding.reloadCollection(app.gpa, app.io);
        refreshLibrary(app);
        onboarding.active = true;
        onboarding.stage = .home;
    } else if (app.unsavedChanges() and !onboarding.discard) {
        onboarding.report(error.UnsavedProjectChanges);
    } else try switchProject(app, &opened);
}

fn switchProject(app: *App, opened: *desktop.onboarding.Opened) !void {
    const onboarding = &app.onboarding;
    app.discardEditorWork();
    app.closePopups();
    app.owner.deinit();
    app.model.deinit();
    app.model = opened.model.?;
    opened.model = null;
    app.owner = try desktop.editor_dispatch.State.init(&app.model);
    app.owner_generation = try std.math.add(u64, app.owner_generation, 1);
    app.accepted_editor_generation = app.owner_generation;
    if (app.tutor.controller.active or app.draft_runtime.owner != null)
        app.draft_runtime.fail(&app.tutor.controller, error.PracticeProjectSwitched, 0);
    app.practicing = false;
    try keyboard_onboarding.State.set(&app.view.paths.project, opened.path);
    onboarding.selected = true;
    if (opened.collection) |root| try keyboard_onboarding.State.set(&onboarding.root, root);
    try onboarding.reloadCollection(app.gpa, app.io);
    refreshLibrary(app);
    // A created or opened layout goes straight to the editor.
    onboarding.stage = .home;
    onboarding.active = false;
    onboarding.discard = false;
    app.rememberProject();
    // Monitoring starts with the first project the user selects.
    if (app.live_enabled and app.live.driver == null) {
        var replacement = try desktop.model.Model.init(app.gpa, app.model.board, app.model.current.snapshot);
        defer replacement.deinit();
        var binding = try app.prepareBinding(&replacement);
        defer binding.deinit();
        app.live.identity = try project.snapshot.identity(app.gpa, replacement.current.snapshot, replacement.board);
        app.live.driver = try LiveKeyboard.Driver.init(.{ .io = app.io }, app.live.identity.?, app.live.seed, null);
        app.live.swap(&replacement, &binding);
    }
}

/// Carries out the wizard's request after the frame was displayed.
pub fn apply(app: *App, action: keyboard_onboarding.Action) !void {
    const onboarding = &app.onboarding;
    switch (action) {
        .none => {},
        .cancel => onboarding.reset(),
        .cancel_tutor => cancelRunnerBuild(app),
        .editor => if (onboarding.selected) {
            cancelRunnerBuild(app);
            onboarding.active = false;
        },
        .tutor => try prepareTutor(app),
        .toggle_theme => app.view.toolbar.light = !app.view.toolbar.light,
        .open => if (app.unsavedChanges() and commands.autosaves(app)) {
            onboarding.open_when_saved = true;
        } else try start(app, .open),
        .choose_source => try chooseFolder(app, .onboarding_source),
        .choose_location => try chooseFolder(app, .onboarding_location),
        .choose_open => try chooseFolder(app, .onboarding_open),
        .inspect, .analyze, .prepare, .create, .add_existing => try start(app, action),
    }
}

fn cancelRunnerBuild(app: *App) void {
    if (app.jobs.runner) |job| job.worker.destroy();
    app.jobs.runner = null;
}

/// Builds the native tutor runner of the selected project.
fn prepareTutor(app: *App) !void {
    if (!app.onboarding.selected or app.jobs.busy()) return;
    const plan = app.build.plan orelse return app.onboarding.report(error.MissingApplicationBundle);
    var config = plan.config;
    config.request.native_only = true;
    const next_job = try std.math.add(u64, app.job_generation, 1);
    app.jobs.runner = workers.startBuild(app, config, next_job) catch |err| return app.onboarding.report(err);
    app.job_generation = next_job;
}

fn chooseFolder(app: *App, target: desktop.folder_selection.Target) !void {
    const ticket = app.chooser.begin(app.owner_generation, try app.model.id(), target) catch |err|
        return app.onboarding.report(err);
    app.onboarding_chooser_generation = app.onboarding.generation;
    dialog.startCorrelated(app.native.window, ticket.generation) catch |err| {
        _ = app.chooser.discard(ticket);
        app.onboarding.report(err);
    };
}

/// Starts an import, analysis, preparation or project operation with the
/// toolchain of the application bundle.
fn start(app: *App, action: keyboard_onboarding.Action) !void {
    const onboarding = &app.onboarding;
    if (app.jobs.busy()) return onboarding.report(error.ProjectOperationAlreadyRunning);
    const replaces_project = action == .create or action == .open or action == .add_existing;
    if (replaces_project and app.unsavedChanges() and !onboarding.discard) return onboarding.report(error.UnsavedProjectChanges);
    const owned = app.user_paths orelse return onboarding.report(error.UserPathsUnavailable);
    if (action == .create or action == .add_existing) onboarding.reloadCollection(app.gpa, app.io) catch |err|
        return onboarding.report(err);
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var toolchain: desktop.onboarding.importer.Toolchain = .{
        .compiler = "",
        .build_root = "",
        .cache = try std.fs.path.join(arena, &.{ owned.paths.cache, "imports" }),
    };
    if (app.build.resources) |bundle| {
        toolchain.compiler = try bundle.path(arena, "toolchain/zig" ++ if (builtin.os.tag == .windows) ".exe" else "");
        toolchain.build_root = try bundle.path(arena, "build");
        toolchain.packages = try bundle.path(arena, "dependencies/p");
        toolchain.payload_executable = bundle.executable;
        toolchain.payload_root = bundle.root;
    } else if (action == .analyze) return onboarding.report(error.MissingApplicationBundle);
    onboarding.start(app.gpa, app.io, app.environ_map, toolchain, action, app.owner_generation) catch |err| onboarding.report(err);
}

/// Reloads the layouts of every known keyboard: the collection's members,
/// remembered profile projects, the open project and the legacy profile
/// folders. Reading never changes a project.
pub fn refreshLibrary(app: *App) void {
    var extra: std.ArrayList([]const u8) = .empty;
    defer extra.deinit(app.gpa);
    for (app.registry.entries.items) |entry| extra.append(app.gpa, entry.directory) catch {};
    if (app.onboarding.selected) extra.append(app.gpa, std.mem.sliceTo(&app.view.paths.project, 0)) catch {};
    const root = std.mem.sliceTo(&app.onboarding.root, 0);
    const loaded = desktop.library.load(app.gpa, app.io, .{
        .collection = if (root.len != 0) root else null,
        .projects = if (app.user_paths) |owned| owned.paths.projects else null,
        .extra = extra.items,
    }) catch |err| return app.onboarding.report(err);
    app.onboarding.replaceLibrary(loaded);
}

/// Opens the layout chosen on My Keyboards once the open one is saved.
fn openWhenSaved(app: *App) !void {
    const onboarding = &app.onboarding;
    if (!onboarding.open_when_saved or app.jobs.busy()) return;
    if (app.view.autosave.failed) {
        onboarding.open_when_saved = false;
        return onboarding.report(error.SaveBeforeSwitchFailed);
    }
    if (app.unsavedChanges()) return;
    onboarding.open_when_saved = false;
    try start(app, .open);
}
