//! Background project, source and firmware jobs of the editor.
//!
//! At most one job runs at a time. Every job captures the editor generation
//! when it starts; a result is discarded when the editor moved on since.
const std = @import("std");
const desktop = @import("desktop-core");
const jobs_api = @import("companion-jobs");
const project = @import("project");
const boards = @import("catalog-project");
const editor = @import("editor-frame-ui");
const paths = @import("paths-ui");
const callbacks = @import("callback-ui");
const App = @import("App.zig");
const onboarding_flow = @import("onboarding_flow.zig");
const maintenance = @import("maintenance.zig");
const build_status = @import("build_status.zig");

pub const FileJob = struct {
    worker: *desktop.project_worker.Owner,
    action: paths.Action,
    editor_generation: u64,
    /// The close request to finish once the project is saved.
    close: ?desktop.editor_dispatch.Request = null,
    /// The project path to restore when opening another layout fails.
    restore: ?[4096]u8 = null,
};

pub const SourceJob = struct {
    worker: *desktop.source_worker.Owner,
    action: callbacks.Action,
    editor_generation: u64,
};

pub const BuildJob = struct {
    worker: *desktop.build_worker.Owner,
    editor_generation: u64,
    first_build: bool,
    trigger: desktop.build_activity.Trigger,
    /// Start on the awake clock, in milliseconds.
    started_ms: u64,
};

pub const Jobs = struct {
    file: ?FileJob = null,
    source: ?SourceJob = null,
    build: ?BuildJob = null,

    pub fn busy(self: *const Jobs) bool {
        return self.file != null or self.source != null or
            self.build != null;
    }

    pub fn cancel(self: *Jobs) void {
        if (self.file) |job| job.worker.destroy();
        if (self.source) |job| job.worker.destroy();
        if (self.build) |job| job.worker.destroy();
        self.* = .{};
    }
};

/// Captures a project file request, reading the board of a project to open.
pub fn captureFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    view: *editor.View,
    model: *desktop.model.Model,
    action: paths.Action,
) !desktop.project_files.Request {
    var selected: ?boards.OwnedBoard = null;
    defer if (selected) |*board| board.deinit();
    if (action.kind == .open or action.kind == .open_discard) {
        try paths.validate(action, view.paths, model);
        var directory = try std.Io.Dir.cwd().openDir(io, std.mem.sliceTo(&action.project, 0), .{});
        defer directory.close(io);
        const bytes = try directory.readFileAlloc(io, "project.zon", gpa, .limited(project.Limits.document_bytes));
        defer gpa.free(bytes);
        const document = try project.parse(gpa, bytes, null);
        defer project.deinit(gpa, document);
        selected = try boards.OwnedBoard.fromDocument(gpa, document);
    }
    return paths.request(action, view.paths, model, if (selected) |board| board.board else null);
}

/// Runs a project file operation on the calling thread. Returns the exported
/// snapshot id, if any.
pub fn fileOperation(
    gpa: std.mem.Allocator,
    io: std.Io,
    view: *editor.View,
    model: *desktop.model.Model,
    action: paths.Action,
) !?[32]u8 {
    var request = try captureFile(gpa, io, view, model, action);
    defer request.deinit();
    var prepared = try request.prepare(gpa, io);
    defer prepared.deinit();
    _ = try prepared.promote(model);
    return prepared.exported;
}

pub fn startFile(app: *App, action: paths.Action, generation: u64) !FileJob {
    var request = try captureFile(app.gpa, app.io, &app.view, &app.model, action);
    errdefer request.deinit();
    return .{
        .worker = try desktop.project_worker.Owner.create(app.gpa, app.io, &request, generation),
        .action = action,
        .editor_generation = app.owner_generation,
    };
}

pub fn startBuild(app: *App, config: desktop.build_worker.Config, generation: u64, trigger: desktop.build_activity.Trigger) !BuildJob {
    var request = try desktop.build_worker.Request.capture(&app.model, config, app.environ_map, generation);
    errdefer request.deinit();
    const first_build = jobs_api.managed_build.isFirstBuild(app.gpa, app.io, config.request);
    return .{
        .worker = try desktop.build_worker.Owner.create(app.gpa, app.io, &request, generation),
        .editor_generation = app.owner_generation,
        .first_build = first_build,
        .trigger = trigger,
        .started_ms = build_status.awakeMs(app),
    };
}

/// Starts the user's build. A background warm-up of the same snapshot
/// becomes this build; any other build waits for the warm-up's cache lease.
pub fn beginBuild(app: *App, config: desktop.build_worker.Config, trigger: desktop.build_activity.Trigger) !void {
    if (try maintenance.adopt(app)) return;
    const next_job = try std.math.add(u64, app.job_generation, 1);
    app.jobs.build = try startBuild(app, config, next_job, trigger);
    app.job_generation = next_job;
    build_status.buildStarted(app, app.jobs.build.?);
}

pub fn startSource(app: *App, action: callbacks.Action, generation: u64) !SourceJob {
    var request = try captureSource(&app.view, &app.model, action);
    errdefer request.deinit();
    return .{
        .worker = try desktop.source_worker.Owner.create(app.gpa, app.io, &request, generation),
        .action = action,
        .editor_generation = app.owner_generation,
    };
}

fn captureSource(view: *editor.View, model: *desktop.model.Model, action: callbacks.Action) !desktop.source_worker.Request {
    try callbacks.validate(action, view.callback, model);
    const path = std.mem.sliceTo(&action.root, 0);
    if (action.kind == .checkout) return desktop.source_worker.Request.captureCheckout(model, path, action.index);
    var request = try callbacks.request(action, view.callback, model);
    errdefer request.deinit();
    return desktop.source_worker.Request.prepareCallback(&request, path);
}

/// Accepts finished job results. A failed or stale result skips the frame.
pub fn poll(app: *App) !App.Flow {
    inline for (.{ pollBuild, pollFile, pollSource }) |pollJob| {
        const flow = try pollJob(app);
        if (flow != .proceed) return flow;
    }
    return .proceed;
}

fn pollBuild(app: *App) !App.Flow {
    const job = app.jobs.build orelse return .proceed;
    const event = job.worker.poll() orelse return .proceed;
    app.jobs.build = null;
    defer job.worker.destroy();
    var prepared = event.result catch |err| {
        build_status.buildFinished(app, job, err);
        app.flash.buildFailed(&app.view, err);
        return .next_frame;
    };
    defer prepared.deinit();
    if (job.editor_generation != app.owner_generation or !std.meta.eql(event.ticket, job.worker.ticket)) {
        build_status.buildFinished(app, job, error.StaleBuild);
        app.flash.buildFailed(&app.view, error.StaleBuild);
        return .next_frame;
    }
    const snapshot = try app.model.id();
    const bundle = prepared.takeBundle(&app.model, .{ .generation = app.job_generation, .snapshot = snapshot }) catch |err| {
        build_status.buildFinished(app, job, err);
        app.flash.buildFailed(&app.view, err);
        return .next_frame;
    };
    build_status.buildFinished(app, job, bundle.firmware.uf2_size);
    try app.flash.buildSucceeded(&app.model, app.owner_generation);
    if (app.build.artifact) |*previous| previous.deinit();
    app.build.artifact = bundle.firmware;
    app.build.generation = app.job_generation;
    app.build.tree = bundle.expected_export_tree;
    app.flash.panel = false;
    app.view.diagnostic = @splat(0);
    maintenance.startCleanup(app);
    return .proceed;
}

fn pollFile(app: *App) !App.Flow {
    const job = app.jobs.file orelse return .proceed;
    const event = job.worker.poll() orelse return .proceed;
    app.jobs.file = null;
    defer job.worker.destroy();
    var prepared = event.result catch |err| return refuseFile(app, job, err);
    defer prepared.deinit();
    if (job.editor_generation != app.owner_generation or !std.meta.eql(event.ticket, job.worker.ticket))
        return refuseFile(app, job, error.StaleProjectAction);
    paths.validateCompletion(job.action, app.view.paths, &app.model) catch |err| return refuseFile(app, job, err);
    const opens = job.action.kind == .open or job.action.kind == .open_discard;
    if (opens and app.editorBusy()) return refuseFile(app, job, error.PendingEditorRequest);
    _ = prepared.promote(&app.model) catch |err| return refuseFile(app, job, err);
    if (opens) app.owner_generation = try std.math.add(u64, app.owner_generation, 1);
    if (opens or job.action.kind == .save) {
        app.view.autosave.failed = false;
        app.associateProfile(std.mem.sliceTo(&app.view.paths.project, 0));
        app.rememberProject();
        onboarding_flow.refreshLibrary(app);
    }
    if (prepared.exported) |id| app.exported = id;
    if (job.close) |captured| {
        if (app.owner.savedClose(&app.model, captured)) |_| {} else |err| app.view.report(err);
    }
    return if (app.owner.closed) .stop else .proceed;
}

/// Reports a failed or stale project operation. A failed save stops automatic
/// saving until the next edit; a failed open keeps the previous project path.
fn refuseFile(app: *App, job: FileJob, err: anyerror) App.Flow {
    if (job.restore) |previous| app.view.paths.project = previous;
    if (job.action.kind == .save) app.view.autosave.failed = true;
    app.view.report(err);
    return .next_frame;
}

fn pollSource(app: *App) !App.Flow {
    const job = app.jobs.source orelse return .proceed;
    const event = job.worker.poll() orelse return .proceed;
    app.jobs.source = null;
    defer job.worker.destroy();
    var prepared = event.result catch |err| {
        app.view.report(err);
        return .next_frame;
    };
    defer prepared.deinit();
    if (job.editor_generation != app.owner_generation or !std.meta.eql(event.ticket, job.worker.ticket)) {
        app.view.report(error.StaleCallbackAction);
        return .next_frame;
    }
    callbacks.validate(job.action, app.view.callback, &app.model) catch |err| {
        app.view.report(err);
        return .next_frame;
    };
    if ((job.action.kind == .attach or job.action.kind == .refresh) and app.editorBusy()) {
        app.view.report(error.PendingEditorRequest);
        return .next_frame;
    }
    const changed = prepared.promote(&app.model) catch |err| {
        app.view.report(err);
        return .next_frame;
    };
    if (job.action.kind == .check) app.setDiagnostic(if (changed)
        "External source differs · refresh explicitly to accept"
    else
        "External source matches the attached snapshot");
    return .proceed;
}
