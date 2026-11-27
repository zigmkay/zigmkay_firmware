//! Build and Flash progress of the editor head: the session timeline, the
//! compiler output, clicks queued behind the cache warm-up, and the state
//! the toolbar draws. Touches no device; the only file it reads or writes is
//! the remembered warm-up duration in the shared compiler cache directory.
const std = @import("std");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const jobs_api = @import("companion-jobs");
const editor = @import("editor-frame-ui");
const release = @import("release-options");
const App = @import("App.zig");
const workers = @import("workers.zig");

const flow = desktop.build_flash_state;
const activity = desktop.build_activity;
const Phase = desktop.flash_controller.Phase;

/// A Build or Flash click made while the build caches were prepared.
pub const Queued = union(enum) {
    build,
    /// The snapshot the Flash click authorized.
    flash: [32]u8,
};

/// The accepted build, for the status row.
pub const Accepted = struct {
    trigger: activity.Trigger,
    duration_ms: u64,
};

/// The last failed build of a snapshot, until it changes or builds again.
pub const Failed = struct {
    snapshot: [32]u8,
    errors: activity.Errors,
    reason: [64]u8 = @splat(0),
};

/// Session bookkeeping the state derivation reads.
pub const Status = struct {
    queued: ?Queued = null,
    accepted: ?Accepted = null,
    failed: ?Failed = null,
    /// When the running warm-up started, on the awake clock.
    warmup_started_ms: u64 = 0,
    /// How long the last long warm-up took, read once at startup.
    warmup_estimate_ms: ?u64 = null,
    /// The flash phase seen last frame, to log each step once.
    flash_phase: ?Phase = null,
    /// When the flashed keyboard reconnected, on the awake clock.
    flashed_ms: ?u64 = null,
    /// The editor diagnostic logged last.
    diagnostic_hash: u64 = 0,
};

pub fn awakeMs(app: *const App) u64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(app.io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn wallMs(app: *const App) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(app.io, .real).nanoseconds, std.time.ns_per_ms));
}

pub fn log(app: *App, kind: activity.Kind, comptime fmt: []const u8, args: anytype) void {
    app.activity.add(wallMs(app), kind, fmt, args);
}

/// Sets the local clock of the timeline and notes the start.
pub fn startup(app: *App) void {
    var ticks: Backend.c.SDL_Time = 0;
    var local: Backend.c.SDL_DateTime = undefined;
    if (Backend.c.SDL_GetCurrentTime(&ticks) and Backend.c.SDL_TimeToDateTime(ticks, &local, true)) {
        app.activity.utc_offset_s = local.utc_offset;
    }
    if (app.build.resources) |bundle| {
        const revision = bundle.manifest.firmware_revision;
        log(app, .info, "App started · Zigmkay {s} ({s})", .{ release.application_version, revision[0..@min(7, revision.len)] });
    } else log(app, .info, "App started · Zigmkay {s} · no build tools in this copy", .{release.application_version});
}

pub fn cleanupFinished(app: *App, report: jobs_api.cache_retention.Report) void {
    if (report.failed != 0) {
        log(app, .warn, "Cache cleanup · {d} entries could not be removed", .{report.failed});
    } else if (report.deleted == 0) {
        log(app, .info, "Cache cleanup: nothing to remove", .{});
    } else if (report.compiler_cache_bytes >= 1024 * 1024) {
        log(app, .info, "Cache cleanup: removed {d} old {s} · {d} MB", .{
            report.deleted,
            if (report.deleted == 1) "entry" else "entries",
            report.compiler_cache_bytes / (1024 * 1024),
        });
    } else log(app, .info, "Cache cleanup: removed {d} old {s}", .{ report.deleted, if (report.deleted == 1) "entry" else "entries" });
}

// The warm-up -------------------------------------------------------------------

const estimate_file = "warmup-ms";

/// Reads the last long warm-up's duration and notes the start.
pub fn warmupStarted(app: *App, config: desktop.build_worker.Config, board: []const u8) void {
    app.build.status.warmup_started_ms = awakeMs(app);
    if (app.build.status.warmup_estimate_ms == null) app.build.status.warmup_estimate_ms = readEstimate(app, config);
    const cores = std.Thread.getCpuCount() catch 0;
    log(app, .warn, "Preparing build caches · {s} · {d} of {d} cores", .{ board, config.request.parallelism orelse 0, cores });
}

/// Logs the end of the warm-up and remembers a long one as the next estimate.
pub fn warmupFinished(app: *App, job: workers.BuildJob, result: anyerror!void, built_layout: bool) void {
    const duration = awakeMs(app) -| app.build.status.warmup_started_ms;
    captureOutput(app, job, result, duration);
    if (result) |_| {
        log(app, .ok, "Build caches ready · {f}{s}", .{ activity.seconds(duration), if (built_layout) " · the open layout is built" else "" });
        if (built_layout) app.build.status.accepted = .{ .trigger = .warmup, .duration_ms = duration };
        if (duration >= flow.long_warmup_ms) {
            app.build.status.warmup_estimate_ms = duration;
            writeEstimate(app, job.worker.request.config, duration);
        }
    } else |err| log(app, .warn, "Preparing build caches failed · {t} · Build still works, only slower", .{err});
}

fn cacheRoot(config: desktop.build_worker.Config, buffer: []u8) ?[]const u8 {
    var fixed: std.heap.FixedBufferAllocator = .init(buffer);
    const layout = config.request.compilerCache(fixed.allocator()) catch return null;
    return layout.root;
}

fn readEstimate(app: *App, config: desktop.build_worker.Config) ?u64 {
    var buffer: [4096]u8 = undefined;
    const root = cacheRoot(config, &buffer) orelse return null;
    var dir = std.Io.Dir.cwd().openDir(app.io, root, .{}) catch return null;
    defer dir.close(app.io);
    var bytes: [32]u8 = undefined;
    const text = dir.readFile(app.io, estimate_file, &bytes) catch return null;
    const value = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \r\n"), 10) catch return null;
    // Ignore nonsense rather than draw a bar that never moves.
    return if (value >= flow.long_warmup_ms and value <= 30 * std.time.ms_per_min) value else null;
}

fn writeEstimate(app: *App, config: desktop.build_worker.Config, duration: u64) void {
    var buffer: [4096]u8 = undefined;
    const root = cacheRoot(config, &buffer) orelse return;
    var dir = std.Io.Dir.cwd().createDirPathOpen(app.io, root, .{}) catch return;
    defer dir.close(app.io);
    var text: [24]u8 = undefined;
    const data = std.fmt.bufPrint(&text, "{d}\n", .{duration}) catch return;
    dir.writeFile(app.io, .{ .sub_path = estimate_file, .data = data }) catch |err|
        std.log.info("Warm-up duration not remembered: {t}", .{err});
}

// Builds ------------------------------------------------------------------------

pub fn buildStarted(app: *App, job: workers.BuildJob) void {
    app.build.status.failed = null;
    const board = boardName(app);
    switch (job.trigger) {
        .click => log(app, .info, "Build started · {s}", .{board}),
        .auto_build => log(app, .info, "Build started · Auto-build after a change · {s}", .{board}),
        .flash => log(app, .info, "Build started · for Flash · {s}", .{board}),
        .warmup, .warmup_adopted => {},
    }
}

/// A Build click took over the running warm-up of the same layout.
pub fn warmupAdopted(app: *App) void {
    app.build.status.failed = null;
    log(app, .info, "Build started · continues the cache warm-up of this layout", .{});
}

/// Logs a finished user build: its UF2 size, or why it failed.
pub fn buildFinished(app: *App, job: workers.BuildJob, result: anyerror!usize) void {
    const duration = awakeMs(app) -| job.started_ms;
    captureOutput(app, job, if (result) |_| {} else |err| err, duration);
    const size = result catch |err| {
        const errors = app.activity.output.errors;
        if (errors.count != 0) {
            log(app, .err, "Build failed after {f} · {f}", .{ activity.seconds(duration), errors });
        } else log(app, .err, "Build failed after {f} · {t}", .{ activity.seconds(duration), err });
        // A build the editor moved past is no failure of the current layout.
        if (err != error.StaleBuild and std.mem.eql(u8, &job.worker.request.captured, &(app.model.id() catch return))) {
            var failed: Failed = .{ .snapshot = job.worker.request.captured, .errors = errors };
            const name = @errorName(err);
            @memcpy(failed.reason[0..@min(name.len, failed.reason.len - 1)], name[0..@min(name.len, failed.reason.len - 1)]);
            app.build.status.failed = failed;
        }
        return;
    };
    log(app, .ok, "Built in {f} · UF2 {f}", .{ activity.seconds(duration), activity.kilobytes(size) });
    app.build.status.accepted = .{ .trigger = job.trigger, .duration_ms = duration };
    app.build.status.flashed_ms = null;
}

fn captureOutput(app: *App, job: workers.BuildJob, result: anyerror!void, duration: u64) void {
    const output = job.worker.request.output;
    app.activity.setOutput(app.gpa, output.stderr, output.stdout, .{
        .at_ms = wallMs(app),
        .trigger = job.trigger,
        .succeeded = if (result) |_| true else |_| false,
        .duration_ms = duration,
    }) catch |err| std.log.info("Compiler output not kept: {t}", .{err});
}

fn boardName(app: *const App) []const u8 {
    if (app.build.plan) |plan| return plan.config.build_board;
    return "this keyboard";
}

// Queued clicks -------------------------------------------------------------------

/// Queues a Build or Flash click while the caches are prepared; a second
/// click on the queued step cancels it. False when nothing is being prepared.
pub fn queue(app: *App, effect: std.meta.Tag(desktop.editor_dispatch.Effect)) !bool {
    if (app.build.warmup == null) return false;
    const status = &app.build.status;
    const step: std.meta.Tag(Queued) = if (effect == .build) .build else .flash;
    if (status.queued) |queued| if (queued == step) {
        status.queued = null;
        log(app, .info, "Queued {s} cancelled", .{if (step == .build) "build" else "Flash"});
        return true;
    };
    status.queued = if (step == .build) .build else .{ .flash = try app.model.id() };
    log(app, .info, "{s} queued until the build caches are ready", .{if (step == .build) "Build" else "Flash"});
    return true;
}

/// The queued click, once the warm-up ended, as the request it stands for.
pub fn takeQueued(app: *App) !?editor.Result {
    if (app.build.warmup != null) return null;
    const queued = app.build.status.queued orelse return null;
    app.build.status.queued = null;
    const snapshot = try app.model.id();
    switch (queued) {
        .build => {
            // The warm-up built exactly this layout: that is the build.
            if (fresh(app, snapshot)) {
                if (app.build.status.accepted) |*accepted| accepted.trigger = .warmup_adopted;
                log(app, .ok, "Built · the cache warm-up already built this layout", .{});
                return null;
            }
            return .{ .effect = .{ .build = try desktop.editor_dispatch.Request.capture(&app.model, .build) } };
        },
        .flash => |clicked| {
            // A Flash click authorizes only the layout it was made on.
            if (!std.mem.eql(u8, &clicked, &snapshot)) {
                log(app, .warn, "Queued Flash dropped · the layout changed since the click", .{});
                return null;
            }
            return .{ .effect = .{ .flash = try desktop.editor_dispatch.Request.capture(&app.model, .flash) } };
        },
    }
}

fn fresh(app: *const App, snapshot: [32]u8) bool {
    const artifact = app.build.artifact orelse return false;
    return std.mem.eql(u8, &artifact.inputs.project_digest, &snapshot);
}

// Flash and other errors -------------------------------------------------------------

/// Logs each new Flash step and editor error once.
pub fn observe(app: *App) void {
    const status = &app.build.status;
    const phase = app.flash.phase();
    if (phase != status.flash_phase) {
        status.flash_phase = phase;
        if (phase) |value| logFlash(app, value);
    }
    const diagnostic = std.mem.sliceTo(&app.view.diagnostic, 0);
    const hash = std.hash.Wyhash.hash(0, diagnostic);
    if (hash != status.diagnostic_hash) {
        status.diagnostic_hash = hash;
        if (diagnostic.len != 0) log(app, .err, "Error · {s}", .{diagnostic});
    }
}

fn logFlash(app: *App, phase: Phase) void {
    switch (phase) {
        .preparing => log(app, .info, "Flash started · checking the firmware", .{}),
        .awaiting_confirmation => log(app, .info, "Flash · asking the keyboard to enter the bootloader", .{}),
        .verifying => log(app, .info, "Flash · writing firmware", .{}),
        .rebooting => log(app, .info, "Flash · firmware written, restarting the keyboard", .{}),
        .reconnecting => log(app, .info, "Flash · waiting for the keyboard to reconnect", .{}),
        .ready => {
            app.build.status.flashed_ms = awakeMs(app);
            log(app, .ok, "Flashed · the keyboard reconnected with this layout", .{});
        },
        .flashed_unverified => {
            app.build.status.flashed_ms = awakeMs(app);
            log(app, .ok, "Flashed · keyboard restarted (allow Linux access to verify live)", .{});
        },
        .cancelled => log(app, .warn, "Flash cancelled", .{}),
        .stale => log(app, .warn, "Flash stopped · the layout changed", .{}),
        .failed => log(app, .err, "Flash failed · {s}", .{if (app.flash.failure) |err| @errorName(err) else "see the flash window"}),
        .reconnect_timeout => log(app, .warn, "Flash · the keyboard did not reconnect in time", .{}),
        else => {},
    }
}

// The toolbar state -------------------------------------------------------------------

/// The state the editor head shows this frame.
pub fn state(app: *App, can_build: bool) !flow.State {
    var input = try stateInput(app, can_build);
    @import("fixtures.zig").statusInput(app, &input);
    const text = try app.window.arena().create(flow.Text);
    return flow.derive(input, text);
}

fn stateInput(app: *App, can_build: bool) !flow.Input {
    const status = &app.build.status;
    const now = awakeMs(app);
    const snapshot = try app.model.id();
    var input: flow.Input = .{
        .toolchain = app.build.plan != null,
        .can_build = can_build,
        .can_flash = (app.build.tools != null and app.build.plan != null and can_build and app.frame_limit == null) or app.flash.active(),
        .auto_build = app.view.toolbar.auto_build,
        .changed = app.build.scheduler.pending,
        .keyboard_runs_layout = keyboardRuns(app),
        .flash = flashState(app, now),
    };
    if (status.queued) |queued| input.queued = switch (queued) {
        .build => .build,
        .flash => .flash,
    };
    if (app.build.warmup != null) input.warmup = .{
        .elapsed_ms = now -| status.warmup_started_ms,
        .estimate_ms = status.warmup_estimate_ms,
    };
    if (app.jobs.build) |job| input.building = .{
        .trigger = job.trigger,
        .elapsed_ms = now -| job.started_ms,
        .first = job.first_build,
    };
    if (fresh(app, snapshot)) {
        const accepted = status.accepted orelse Accepted{ .trigger = .warmup, .duration_ms = 0 };
        input.built = .{ .duration_ms = accepted.duration_ms, .by_user = accepted.trigger != .warmup };
    }
    if (status.failed) |*failed| if (std.mem.eql(u8, &failed.snapshot, &snapshot)) {
        input.build_failed = failed.errors;
        input.build_failure = std.mem.sliceTo(&failed.reason, 0);
    };
    if (app.flash.session) |*session| input.flash_status = try session.status(app.window.arena(), now);
    if (app.flash.failure) |err| input.flash_failure = @errorName(err);
    return input;
}

fn flashState(app: *const App, now: u64) flow.Flash {
    if (app.flash.prep != null) return .{ .working = .preparing };
    const phase = app.flash.phase() orelse return if (app.flash.failure != null and app.flash.pending == null) .failed else .idle;
    return switch (phase) {
        .idle, .cancelled, .stale => .idle,
        .preparing, .prepared, .building, .built, .freezing, .frozen => .{ .working = .preparing },
        .awaiting_confirmation => .{ .working = .bootloader },
        .verifying => .{ .working = .writing },
        .rebooting => .{ .working = .restarting },
        .reconnecting => .{ .working = .reconnecting },
        .cancelling => .{ .working = .cancelling },
        .ready, .flashed_unverified => .{ .done = now -| (app.build.status.flashed_ms orelse now) },
        .failed, .reconnect_timeout => .failed,
    };
}

/// The connected keyboard verified that it runs exactly the editor's layout.
fn keyboardRuns(app: *const App) bool {
    if (app.live.status() != .live or !app.live.verified()) return false;
    const running = app.live.model.id() catch return false;
    const open = app.model.id() catch return false;
    return std.mem.eql(u8, &running, &open);
}
