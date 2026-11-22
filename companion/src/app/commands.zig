//! Carries out what the editor frame requested: project files, callback
//! sources, folder choosers, navigation, layout commands, builds and Flash,
//! and saves the open layout automatically.
//!
//! Filesystem work and native choosers start only after the frame that
//! showed the request was displayed.
const std = @import("std");
const builtin = @import("builtin");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const boards = @import("catalog-project");
const editor = @import("editor-frame-ui");
const paths = @import("paths-ui");
const callbacks = @import("callback-ui");
const dialog = @import("folder-dialog");
const App = @import("App.zig");
const Flash = @import("Flash.zig");
const onboarding_flow = @import("onboarding_flow.zig");
const screens = @import("screens.zig");
const keyboard_onboarding = @import("onboarding-ui");
const workers = @import("workers.zig");

const Command = @FieldType(editor.Result, "layout");

/// A refused request skips the rest of the frame.
pub fn apply(app: *App, result: editor.Result, board: *const boards.OwnedBoard, can_build: bool) !App.Flow {
    const flow = switch (result) {
        .paths => |action| try projectFiles(app, action),
        .callback => |action| try callbackSource(app, action),
        .layout => |command| try layoutCommand(app, command, board),
        .effect => |effect| switch (effect) {
            .save, .save_close => |captured| try save(app, captured, effect == .save_close),
            .open => |target| open(app, target),
            .build => |captured| try build(app, captured),
            .flash => |captured| try Flash.request(app, captured, board, can_build),
            else => .proceed,
        },
    };
    if (flow == .proceed) try autosave(app);
    return flow;
}

fn projectFiles(app: *App, action: paths.Action) !App.Flow {
    switch (action.kind) {
        .cancel => app.jobs.cancel(),
        .choose_project => return chooseFolder(app, action.snapshot, .project),
        .choose_export => return chooseFolder(app, action.snapshot, .export_directory),
        .reveal_export => reveal(app, std.mem.sliceTo(&action.exported, 0)),
        else => {
            if (refuseWhileBusy(app)) return .next_frame;
            const next_job = try std.math.add(u64, app.job_generation, 1);
            app.jobs.file = workers.startFile(app, action, next_job) catch |err| return reported(app, err);
            app.job_generation = next_job;
        },
    }
    return .proceed;
}

fn callbackSource(app: *App, action: callbacks.Action) !App.Flow {
    if (action.kind == .cancel) {
        app.jobs.cancel();
        return .next_frame;
    }
    if (refuseWhileBusy(app)) return .next_frame;
    if (action.kind == .choose_root) return chooseFolder(app, action.snapshot, .callback_source);
    const next_job = try std.math.add(u64, app.job_generation, 1);
    app.jobs.source = workers.startSource(app, action, next_job) catch |err| return reported(app, err);
    app.job_generation = next_job;
    return .proceed;
}

fn chooseFolder(app: *App, snapshot: [32]u8, target: desktop.folder_selection.Target) App.Flow {
    const ticket = app.chooser.begin(app.owner_generation, snapshot, target) catch |err| return reported(app, err);
    dialog.startCorrelated(app.native.window, ticket.generation) catch |err| {
        _ = app.chooser.discard(ticket);
        app.view.report(err);
    };
    return .proceed;
}

fn save(app: *App, captured: desktop.editor_dispatch.Request, close: bool) !App.Flow {
    captured.validate(&app.model) catch |err| return reported(app, err);
    if (refuseWhileBusy(app)) return .next_frame;
    const next_job = try std.math.add(u64, app.job_generation, 1);
    const action = app.view.paths.action(try app.model.id(), .save);
    app.jobs.file = workers.startFile(app, action, next_job) catch |err| {
        app.view.report(err);
        return .next_frame;
    };
    app.job_generation = next_job;
    if (close) app.jobs.file.?.close = captured;
    return .proceed;
}

fn open(app: *App, target: desktop.editor_dispatch.Open) App.Flow {
    switch (target) {
        .practice => {
            app.practicing = true;
            app.view.diagnostic = @splat(0);
        },
        .keyboards => openKeyboards(app),
        else => app.view.report(error.NavigationNotConnected),
    }
    return .proceed;
}

/// Shows My Keyboards over the editor.
fn openKeyboards(app: *App) void {
    app.onboarding.reset();
    app.onboarding.reloadCollection(app.gpa, app.io) catch |err| app.onboarding.report(err);
    onboarding_flow.refreshLibrary(app);
}

fn layoutCommand(app: *App, command: Command, board: *const boards.OwnedBoard) !App.Flow {
    switch (command) {
        .open => |index| {
            var scratch: std.heap.ArenaAllocator = .init(app.gpa);
            defer scratch.deinit();
            const choices = try screens.layoutChoices(app, board, scratch.allocator());
            if (index >= choices.paths.len or choices.choices[index].current) return .proceed;
            try switchLayout(app, choices.paths[index]);
        },
        .new, .duplicate => {
            openKeyboards(app);
            const onboarding = &app.onboarding;
            onboarding.openNewLayout(keyboard_onboarding.entryIndex(board.entry));
            if (command == .duplicate) {
                const current = std.mem.sliceTo(&app.view.paths.project, 0);
                if (onboarding.library) |*library| if (library.find(current)) |index| {
                    onboarding.new_layout.start = .duplicate;
                    onboarding.new_layout.duplicate = index;
                };
            }
        },
        .rename => {},
        .export_source => app.view.modal = .paths,
        .reveal => reveal(app, std.mem.sliceTo(&app.view.paths.project, 0)),
        .keyboards => openKeyboards(app),
    }
    return .proceed;
}

/// Opens another layout. Unsaved edits are saved first.
fn switchLayout(app: *App, path: []const u8) !void {
    if (app.editorBusy()) return app.view.report(error.PendingEditorRequest);
    if (path.len >= app.view.paths.project.len) return app.view.report(error.InvalidProjectPath);
    if (app.model.dirty()) {
        if (!autosaves(app)) return app.view.report(error.UnsavedProject);
        var queued: [4096]u8 = @splat(0);
        @memcpy(queued[0..path.len], path);
        app.view.autosave.queued = queued;
        return;
    }
    try openLayout(app, path);
}

fn openLayout(app: *App, path: []const u8) !void {
    if (refuseWhileBusy(app)) return;
    const previous = app.view.paths.project;
    app.view.paths.project = @splat(0);
    @memcpy(app.view.paths.project[0..path.len], path);
    const next_job = try std.math.add(u64, app.job_generation, 1);
    const action = app.view.paths.action(try app.model.id(), .open);
    app.jobs.file = workers.startFile(app, action, next_job) catch |err| {
        app.view.paths.project = previous;
        return app.view.report(err);
    };
    // A failed open restores the path, so later saves keep their target.
    app.jobs.file.?.restore = previous;
    app.job_generation = next_job;
}

/// Whether edits of the open layout save automatically. Fixtures and the
/// built-in project before onboarding never write.
pub fn autosaves(app: *const App) bool {
    return app.frame_limit == null and app.user_paths != null and app.onboarding.selected and
        app.view.paths.project[0] != 0;
}

/// How long a draft rests before it is saved.
const autosave_delay_ms = 700;

/// Saves the open layout once its draft has rested, then opens a queued layout.
fn autosave(app: *App) !void {
    const state = &app.view.autosave;
    const now_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(app.io, .awake).nanoseconds, std.time.ns_per_ms));
    const id = try app.model.id();
    if (!std.mem.eql(u8, &id, &state.observed)) {
        state.observed = id;
        state.changed_ms = now_ms;
        state.failed = false;
    }
    if (app.jobs.busy() or app.editorBusy() or app.owner.closed) return;
    if (!app.model.dirty()) {
        if (state.queued) |target| {
            state.queued = null;
            try openLayout(app, std.mem.sliceTo(&target, 0));
        }
        return;
    }
    if (!autosaves(app) or state.failed) {
        if (state.queued != null) app.view.report(error.SaveBeforeSwitchFailed);
        state.queued = null;
        return;
    }
    if (state.queued == null and now_ms < state.changed_ms + autosave_delay_ms) return;
    const next_job = try std.math.add(u64, app.job_generation, 1);
    const action = app.view.paths.action(id, .save);
    app.jobs.file = workers.startFile(app, action, next_job) catch |err| {
        state.failed = true;
        return app.view.report(err);
    };
    app.job_generation = next_job;
}

/// Shows a folder in the system file manager.
fn reveal(app: *App, path: []const u8) void {
    if (app.frame_limit != null or path.len == 0) return;
    var url: std.Io.Writer.Allocating = .init(app.gpa);
    defer url.deinit();
    fileUrl(&url.writer, path) catch return app.view.report(error.OutOfMemory);
    if (!Backend.c.SDL_OpenURL(@ptrCast(url.written().ptr))) app.view.report(error.ShowInFolderFailed);
}

/// A zero-terminated `file://` URL of an absolute path.
fn fileUrl(writer: *std.Io.Writer, path: []const u8) !void {
    try writer.writeAll(if (builtin.os.tag == .windows) "file:///" else "file://");
    for (path) |byte| {
        const char = if (byte == '\\') '/' else byte;
        if (std.ascii.isAlphanumeric(char) or std.mem.indexOfScalar(u8, "/-._~:", char) != null) {
            try writer.writeByte(char);
        } else try writer.print("%{X:0>2}", .{char});
    }
    try writer.writeByte(0);
}

fn build(app: *App, captured: desktop.editor_dispatch.Request) !App.Flow {
    if (refuseWhileBusy(app)) return .next_frame;
    captured.validate(&app.model) catch |err| return reported(app, err);
    const plan = app.build.plan orelse return reported(app, error.MissingApplicationBundle);
    const next_job = try std.math.add(u64, app.job_generation, 1);
    app.jobs.build = workers.startBuild(app, plan.config, next_job) catch |err| return reported(app, err);
    app.job_generation = next_job;
    app.build.scheduler.manual(try app.model.id());
    app.view.diagnostic = @splat(0);
    return .proceed;
}

fn refuseWhileBusy(app: *App) bool {
    if (!app.jobs.busy()) return false;
    app.view.report(error.ProjectOperationAlreadyRunning);
    return true;
}

fn reported(app: *App, err: anyerror) App.Flow {
    app.view.report(err);
    return .next_frame;
}
