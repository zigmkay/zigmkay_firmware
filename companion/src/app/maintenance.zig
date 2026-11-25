//! Background cache upkeep of the interactive editor: one retention pass at
//! startup and after each accepted build, and one quiet warm-up build that
//! fills the compiler cache before the user's first Build or Flash. Neither
//! reports to the user; failures are only logged. Neither touches devices.
const std = @import("std");
const desktop = @import("desktop-core");
const jobs_api = @import("companion-jobs");
const project = @import("project");
const boards = @import("catalog-project");
const App = @import("App.zig");
const cli = @import("cli.zig");
const workers = @import("workers.zig");
const warmup = desktop.build_warmup;

pub const Warmup = struct {
    job: workers.BuildJob,
    ticket: warmup.Ticket,
};

/// Fixtures, light previews, offline sessions and the hardware trial never
/// build on their own.
fn interactive(app: *const App) bool {
    if (app.frame_limit != null) return false;
    return switch (app.mode) {
        .editor => |editor| !editor.offline and editor.light == null,
        else => false,
    };
}

/// Starts the startup retention pass. The warm-up waits for it.
pub fn startup(app: *App) void {
    if (app.frame_limit != null or app.mode != .editor) return;
    startCleanup(app);
}

/// Called every frame: collects finished background work and starts the
/// warm-up once the editor has settled.
pub fn step(app: *App) !void {
    pollCleanup(app);
    try pollWarmup(app);
    const now_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(app.io, .awake).nanoseconds, std.time.ns_per_ms));
    const first = app.build.first_frame_ms orelse blk: {
        app.build.first_frame_ms = now_ms;
        break :blk now_ms;
    };
    const decision = warmup.decide(.{
        .allowed = interactive(app),
        .attempted = app.build.warmup_attempted,
        .can_build = app.build.resources != null and app.user_paths != null,
        .idle = app.build.cleanup == null and !app.jobs.busy() and app.flash.pending == null and
            app.flash.session == null and !app.owner.closed and app.owner.close_requested == null,
        .since_start_ms = now_ms -| first,
    });
    switch (decision) {
        .wait => {},
        .skip => app.build.warmup_attempted = true,
        .check => {
            app.build.warmup_attempted = true;
            startWarmup(app) catch |err| std.log.info("Background build warm-up not started: {t}", .{err});
        },
    }
}

fn startWarmup(app: *App) !void {
    const bundle = app.build.resources orelse return;
    const owned = app.user_paths orelse return;
    // Without a project the editor holds the default layout; building it
    // still compiles the shared build runner and host tools.
    var selected = try boards.OwnedBoard.fromDocument(app.gpa, app.model.document());
    defer selected.deinit();
    const plan = try desktop.application_bundle.plan(app.gpa, bundle, owned.paths.cache, selected.entry.selector, app.model.board.id);
    defer project.owned_zon.free(app.gpa, plan);
    if (!jobs_api.managed_build.isFirstBuild(app.gpa, app.io, plan.config.request)) return;
    var config = plan.config;
    config.request.parallelism = jobs_api.compiler_cache.hostParallelism(true);
    const next_job = try std.math.add(u64, app.job_generation, 1);
    const job = try workers.startBuild(app, config, next_job);
    app.job_generation = next_job;
    app.build.warmup = .{ .job = job, .ticket = .{
        .job_generation = next_job,
        .editor_generation = app.owner_generation,
        .snapshot = try app.model.id(),
        .board_id = app.model.board.id,
    } };
    std.log.info("Background build warm-up started: {s} with -j{d}", .{ selected.entry.selector, config.request.parallelism.? });
}

fn currentState(app: *App) !warmup.Current {
    const plan_board: ?[8]u8 = if (app.onboarding.selected) if (app.build.plan) |plan| plan.config.board_id else null else null;
    return .{
        .job_generation = app.job_generation,
        .editor_generation = app.owner_generation,
        .snapshot = try app.model.id(),
        .plan_board = plan_board,
    };
}

/// A user build of the warm-up's snapshot takes the running warm-up over.
/// Any other user build starts and waits for the warm-up's cache lease.
pub fn adopt(app: *App) !bool {
    const running = app.build.warmup orelse return false;
    if (warmup.userBuild(running.ticket, try currentState(app)) != .adopt) return false;
    app.jobs.build = running.job;
    app.build.warmup = null;
    std.log.info("User build adopted the background warm-up", .{});
    return true;
}

fn pollWarmup(app: *App) !void {
    const running = app.build.warmup orelse return;
    const event = running.job.worker.poll() orelse return;
    app.build.warmup = null;
    defer running.job.worker.destroy();
    var prepared = event.result catch |err| {
        std.log.info("Background build warm-up failed: {t}", .{err});
        return;
    };
    defer prepared.deinit();
    defer startCleanup(app);
    const state = try currentState(app);
    if (warmup.finished(running.ticket, state, true, app.jobs.build != null) != .accept or
        !std.meta.eql(event.ticket, running.job.worker.ticket))
    {
        std.log.info("Background build warm-up finished; compiler cache ready", .{});
        return;
    }
    const bundle = prepared.takeBundle(&app.model, .{ .generation = app.job_generation, .snapshot = state.snapshot }) catch |err| {
        std.log.info("Background build warm-up result not used: {t}", .{err});
        return;
    };
    try app.flash.buildSucceeded(&app.model, app.owner_generation);
    if (app.build.artifact) |*previous| previous.deinit();
    app.build.artifact = bundle.firmware;
    app.build.generation = app.job_generation;
    app.build.tree = bundle.expected_export_tree;
    std.log.info("Background build warm-up built the open layout", .{});
}

/// Starts a retention pass unless a build, a warm-up or a pass is running.
pub fn startCleanup(app: *App) void {
    if (app.build.cleanup != null or app.build.warmup != null or app.jobs.build != null) return;
    const owned = app.user_paths orelse return;
    var format_buffer: [16]u8 = undefined;
    var options: jobs_api.cache_retention.Options = .{
        .now = std.Io.Timestamp.now(app.io, .real),
        .export_format = std.fmt.bufPrint(&format_buffer, "v{d}", .{project.exporter.contract.version}) catch return,
    };
    if (app.build.resources) |bundle| {
        options.compiler_cache = jobs_api.compiler_cache.name(bundle.manifest.compiler_hash orelse bundle.manifest.id);
        if (bundle.executable != null) options.runtime = std.fmt.bytesToHex(bundle.manifest.id, .lower);
    }
    var flash_name: [64 + 4]u8 = undefined;
    var export_name: [64]u8 = undefined;
    if (app.build.artifact) |artifact| {
        // `<builds>/build-<hex>/firmware/project.uf2`
        if (std.fs.path.dirname(artifact.uf2_path)) |firmware| if (std.fs.path.dirname(firmware)) |build| {
            options.keep.build = std.fs.path.basename(build);
        };
        export_name = std.fmt.bytesToHex(artifact.inputs.project_digest, .lower);
        options.keep.export_name = &export_name;
        flash_name[0..64].* = std.fmt.bytesToHex(artifact.uf2_hash, .lower);
        flash_name[64..].* = ".uf2".*;
        options.keep.flash = &flash_name;
    }
    app.build.cleanup = desktop.cache_cleanup.Owner.create(app.gpa, app.io, owned.paths.cache, options) catch |err| {
        std.log.info("Cache cleanup not started: {t}", .{err});
        return;
    };
}

fn pollCleanup(app: *App) void {
    const owner = app.build.cleanup orelse return;
    _ = owner.poll() orelse return;
    owner.destroy();
    app.build.cleanup = null;
}

/// Stops background work at quit; a warm-up's compiler is killed.
pub fn deinit(app: *App) void {
    if (app.build.warmup) |running| running.job.worker.destroy();
    app.build.warmup = null;
    if (app.build.cleanup) |owner| owner.destroy();
    app.build.cleanup = null;
}
