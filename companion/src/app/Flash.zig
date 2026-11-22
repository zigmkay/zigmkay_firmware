//! Flash orchestration: from the toolbar click through the build, the frozen
//! UF2, the BOOTSEL request and the transfer to the reconnected keyboard.
//!
//! The Flash click is the only user authorization. Every later stage is bound
//! to the snapshot, build and selection that were displayed at that moment.
const std = @import("std");
const desktop = @import("desktop-core");
const jobs_api = @import("companion-jobs");
const project = @import("project");
const boards = @import("catalog-project");
const flash_ui = @import("flash-ui");
const editor = @import("editor-frame-ui");
const flash_session = @import("flash_session.zig");
const flash_request = @import("flash_request.zig");
const bootloader = @import("flash_bootloader.zig");
const App = @import("App.zig");
const LiveKeyboard = @import("LiveKeyboard.zig");
const workers = @import("workers.zig");

const Flash = @This();
const Phase = desktop.flash_controller.Phase;
const Watch = @FieldType(desktop.flash_controller.Effect, "watch_reconnect");

session: ?flash_session.Session = null,
panel: bool = false,
details_open: bool = false,
failure: ?anyerror = null,
gate: bootloader.Gate = .{},
/// The view the user confirmed, kept until the gate starts the transfer.
retained_view: ?desktop.flash_presenter.View = null,
/// A Flash click waiting for its firmware build.
pending: ?Pending = null,
/// Admit and prepare the session after the current frame.
advance: bool = false,
/// Start of the `--physical-flash-once` trial.
trial_start: ?i128 = null,

pub const Pending = struct { snapshot: [32]u8, generation: u64 };

pub fn deinit(self: *Flash) void {
    if (self.session) |*session| session.deinit();
}

pub fn fail(self: *Flash, view: *editor.View, err: anyerror) void {
    self.failure = err;
    view.report(err);
}

pub fn cancelConfirmation(self: *Flash) void {
    self.gate.cancel();
    self.retained_view = null;
}

pub fn phase(self: *const Flash) ?Phase {
    return if (self.session) |*session| session.owner.phase else null;
}

/// Whether a session runs that a new Flash click must not replace.
pub fn active(self: *const Flash) bool {
    const current = self.phase() orelse return false;
    return !finished(current);
}

pub fn idle(self: *const Flash) bool {
    return self.session == null and self.pending == null and self.retained_view == null;
}

pub fn failed(self: *const Flash) bool {
    const current = self.phase() orelse return self.failure != null;
    return self.failure != null or current == .failed or current == .reconnect_timeout;
}

/// Drops the session and its outcome for a new automatic build.
pub fn discard(self: *Flash) void {
    if (self.session) |*previous| previous.deinit();
    self.session = null;
    self.cancelConfirmation();
    self.failure = null;
    self.panel = false;
}

pub fn buildFailed(self: *Flash, view: *editor.View, err: anyerror) void {
    if (self.pending != null) {
        self.failure = err;
        self.panel = true;
    }
    self.pending = null;
    self.advance = false;
    view.report(err);
}

/// A new firmware build replaces the session. A pending click continues only
/// when the editor is still at the clicked snapshot.
pub fn buildSucceeded(self: *Flash, model: *const desktop.model.Model, generation: u64) !void {
    self.cancelConfirmation();
    if (self.pending) |pending| {
        if (pending.generation == generation and std.mem.eql(u8, &pending.snapshot, &(try model.id()))) {
            self.advance = true;
        } else self.pending = null;
    }
    if (self.session) |*previous| previous.deinit();
    self.session = null;
}

/// The flash status shown in the toolbar.
pub fn toolbarStatus(self: *const Flash, arena: std.mem.Allocator, building: bool, now_ms: u64) ![]const u8 {
    if (building) return "";
    if (self.session) |*session| return session.status(arena, now_ms);
    if (self.pending != null) return "Building for Flash";
    if (self.failure != null) return "Flash failed";
    return "";
}

fn finished(value: Phase) bool {
    return switch (value) {
        .ready, .failed, .cancelled, .reconnect_timeout, .stale => true,
        else => false,
    };
}

pub fn artifactMatchesBundle(artifact: desktop.build_worker.Artifact) bool {
    return artifact.audit_mode == jobs_api.firmware.AuditMode.bundled;
}

fn snapshotOf(session: *const flash_session.Session, rendered: desktop.flash_presenter.View, generation: u64) bootloader.Snapshot {
    const unique = if (session.owner.selected) |selection| selection == .unique_bootsel else false;
    return .{
        .operation = rendered.operation_id,
        .model_generation = generation,
        .board_id = session.request.config.board_id,
        .build_key = session.owner.current.build_key,
        .artifact_hash = rendered.uf2_hash orelse @splat(0),
        .selection_revision = rendered.selection_revision,
        .selected_target = @intFromBool(unique),
    };
}

/// A HID BOOTSEL request requires a coherent running binding on the artifact's
/// board; the selected project's profile and digest may differ from firmware.
fn liveMatches(
    driver: *const LiveKeyboard.Driver,
    running: ?LiveKeyboard.Identity,
    selected: LiveKeyboard.Identity,
    artifact_board: [8]u8,
) bool {
    const expected = running orelse return false;
    return driver.connected and driver.session.token != 0 and driver.session.hasCoherentState() and
        std.meta.eql(driver.session.expected, expected) and
        std.mem.eql(u8, &expected.board_id, &artifact_board) and
        std.mem.eql(u8, &selected.board_id, &artifact_board);
}

fn bootloaderStatus(status: @FieldType(@FieldType(LiveKeyboard.Driver, "session"), "bootloader_status")) bootloader.Session.Status {
    return switch (status) {
        .idle => .idle,
        // The enter-bootloader command has no acknowledgement; a successful
        // write is final and the flash wrapper waits for the BOOTSEL drive.
        .sent => .accepted,
    };
}

/// Ends the `--physical-flash-once` trial once the session settles.
pub fn monitorTrial(app: *App) !App.Flow {
    if (app.mode != .physical_flash) return .proceed;
    const start = app.flash.trial_start orelse return .proceed;
    const elapsed_ms = @divTrunc(app.native.nanoTime() - start, std.time.ns_per_ms);
    if (app.flash.session) |*session| switch (session.owner.phase) {
        .ready => {
            if (!(try session.matchesModel(&app.model, app.build.generation)) or app.flash.failure != null)
                return error.PhysicalFlashIdentityMismatch;
            std.log.info("Physical flash ready in {d} ms", .{elapsed_ms});
            return .stop;
        },
        .failed, .stale, .cancelled, .reconnect_timeout => {
            std.log.err("Physical flash terminated after {d} ms: {t}; error={s}; runtime={s}", .{
                elapsed_ms,
                session.owner.phase,
                if (app.flash.failure) |err| @errorName(err) else "none",
                if (session.runtime.last_error) |err| @errorName(err) else "none",
            });
            if (session.completion) |result| if (result.completion) |completed| {
                std.log.err("Flash wrapper stdout: {s}", .{completed.process.stdout});
                std.log.err("Flash wrapper stderr: {s}", .{completed.process.stderr});
            };
            return error.PhysicalFlashFailed;
        },
        else => {},
    };
    if (app.flash.failure) |err| {
        std.log.err("Physical flash failed after {d} ms: {s}", .{ elapsed_ms, @errorName(err) });
        return err;
    }
    if (elapsed_ms >= 120 * std.time.ms_per_s) {
        std.log.err("Physical flash timed out after {d} ms", .{elapsed_ms});
        return error.PhysicalFlashTimeout;
    }
    return .proceed;
}

/// Clicks Flash once at startup for the `--physical-flash-once` trial.
pub fn startTrial(app: *App, can_build: bool, rendered: *editor.Result) !void {
    if (app.mode != .physical_flash or app.flash.trial_start != null or !can_build) return;
    if (app.jobs.busy() or app.flash.session != null) return error.PhysicalFlashStartupNotIdle;
    app.flash.trial_start = app.native.nanoTime();
    std.log.info("Physical flash click dispatched (prepared inputs; cache-only status determined by build)", .{});
    rendered.* = .{ .effect = try flash_request.dispatch(&app.owner, &app.model) };
}

/// Advances the session by one frame: invalidation, the confirmation gate,
/// the managed transfer and the reconnect to the flashed firmware.
pub fn step(app: *App, now_us: u64) !void {
    const flash = &app.flash;
    const session = if (flash.session) |*value| value else return;
    const generation = app.build.generation;
    if (flash.retained_view != null) {
        flash.gate.observe(snapshotOf(session, session.view(null), generation));
        if (flash.gate.phase == .idle or !(session.matchesModel(&app.model, generation) catch false)) flash.cancelConfirmation();
    }
    _ = session.observe(&app.model, generation) catch |err| flash.fail(&app.view, err);
    if (flash.retained_view) |rendered| stepGate(app, session, rendered, now_us);
    const effect = session.poll(now_us / 1000) catch |err| failed: {
        flash.fail(&app.view, err);
        break :failed .none;
    };
    if (effect == .watch_reconnect and session.owner.phase == .reconnecting and
        !session.owner.reconnect_binding_prepared and (session.matchesModel(&app.model, generation) catch false))
    {
        try bindReconnect(app, session, effect.watch_reconnect);
    }
    if (session.owner.phase == .failed and flash.failure == null) {
        if (session.runtime.last_error) |err| flash.fail(&app.view, err);
    }
    if (session.reconnect) |watch| acceptReconnect(app, session, watch, now_us);
}

fn stepGate(app: *App, session: *flash_session.Session, rendered: desktop.flash_presenter.View, now_us: u64) void {
    const flash = &app.flash;
    const driver = if (app.live.driver) |*value| value else null;
    const current = snapshotOf(session, session.view(null), app.build.generation);
    const driver_now = if (driver) |live| live.transport.now() else @as(u64, @intCast(std.Io.Clock.awake.now(app.io).toMilliseconds()));
    if (driver) |live| {
        if (live.session.bootloader_status == .sent) flash.gate.observeAccepted(current, driver_now);
    }
    // Only the board must match the selected artifact; the live session
    // remains bound to the verified running firmware.
    const selected = project.snapshot.identity(app.gpa, app.model.current.snapshot, app.model.board) catch null;
    const gate_session: bootloader.Session = if (driver) |live| .{
        .available = if (selected) |identity|
            liveMatches(live, app.live.identity, identity, current.board_id) and live.session.bootloaderAvailable()
        else
            false,
        .status = bootloaderStatus(live.session.bootloader_status),
    } else .{};
    switch (flash.gate.step(gate_session, current, driver_now)) {
        .request_once => if (driver) |live| {
            session.discovery_started = now_us / 1000;
            if (!gate_session.available) {
                flash.gate.requestFailed();
            } else live.enterBootloader(driver_now) catch |err| {
                flash.gate.requestFailed();
                std.log.info("HID BOOTSEL request unavailable ({s}); continuing the same operation with manual guidance", .{
                    @errorName(err),
                });
            };
        },
        .start => {
            session.confirm(rendered, &app.model, app.build.generation, now_us / 1000) catch |err| flash.fail(&app.view, err);
            flash.retained_view = null;
        },
        else => {},
    }
    if (flash.gate.phase == .manual and flash.gate.consumeManual(current)) {
        if (session.discovery_started == null) session.guidance_delay_ms = 0;
        session.confirm(rendered, &app.model, app.build.generation, now_us / 1000) catch |err| flash.fail(&app.view, err);
        flash.retained_view = null;
    }
    if (flash.gate.phase == .idle) flash.retained_view = null;
}

/// Binds the live session to the flashed project before the keyboard
/// reconnects, so the reconnected firmware can verify itself.
fn bindReconnect(app: *App, session: *flash_session.Session, watch: Watch) !void {
    const artifact = session.owner.artifact orelse return;
    if (!std.meta.eql(watch.expected, artifact.expected_identity)) return;
    const expected = artifact.expected_identity;
    var replacement = desktop.model.Model.init(app.gpa, session.request.file.board, session.request.file.loaded.snapshot) catch |err|
        return app.view.report(err);
    defer replacement.deinit();
    const identity = project.snapshot.identity(app.gpa, replacement.current.snapshot, replacement.board) catch |err|
        return app.view.report(err);
    if (!std.mem.eql(u8, &replacement.board.id, &expected.board_id) or
        !std.mem.eql(u8, &replacement.document().profile_id, &expected.profile_id) or
        !std.mem.eql(u8, &identity.digest, &expected.digest)) return;
    // Bind only when the editor still shows the flashed project.
    if (!std.meta.eql(identity, try project.snapshot.identity(app.gpa, app.model.current.snapshot, app.model.board))) return;
    var binding = app.prepareBinding(&replacement) catch |err| return app.view.report(err);
    defer binding.deinit();
    var seed: u32 = 0;
    std.Io.randomSecure(app.io, std.mem.asBytes(&seed)) catch |err| return app.view.report(err);
    // The driver's first token is seed + 1; it must differ from the session
    // that is going away, or the reconnect would look like the old firmware.
    const old_token = session.owner.previous_session_token orelse if (app.live.driver) |driver| driver.session.token else 0;
    const first_token = if (seed == std.math.maxInt(u32)) @as(u32, 1) else seed + 1;
    if (old_token != 0 and first_token == old_token) seed +%= 1;
    const driver = LiveKeyboard.Driver.init(.{ .io = app.io }, identity, seed, null) catch |err| return app.view.report(err);
    if (app.live.driver) |old| {
        if (old.session.token != 0 and session.owner.previous_session_token == null)
            session.owner.previous_session_token = old.session.token;
    }
    app.live.rebind(&replacement, &binding, identity, driver, &app.life);
    session.owner.reconnect_binding_prepared = true;
    std.log.info("Flash reconnect binding prepared for operation {d}", .{watch.operation.id});
}

fn acceptReconnect(app: *App, session: *flash_session.Session, watch: Watch, now_us: u64) void {
    const driver = if (app.live.driver) |*value| value else return;
    const identity = driver.session.expected;
    const token = driver.session.token;
    const new_session = if (session.owner.previous_session_token) |previous| token != previous else true;
    if (driver.connected and token != 0 and new_session and driver.session.hasCoherentState() and
        std.mem.eql(u8, &identity.board_id, &watch.expected.board_id) and
        std.mem.eql(u8, &identity.profile_id, &watch.expected.profile_id) and
        std.mem.eql(u8, &identity.digest, &watch.expected.digest))
    {
        _ = session.reconnected(token, true, watch.expected, now_us / 1000) catch |err| app.flash.fail(&app.view, err);
    }
}

pub const Panel = struct {
    intent: ?desktop.flash_controller.Intent = null,
    /// The view the panel displayed this frame.
    rendered: ?desktop.flash_presenter.View = null,
    close: bool = false,
};

pub fn drawPanel(app: *App) Panel {
    const flash = &app.flash;
    var panel: Panel = .{};
    const shows_error = desktop.flash_presenter.showErrorWindow(flash.phase(), flash.failure);
    if (!flash.panel or !shows_error or !app.life.editor_visible or app.practicing) return panel;
    if (flash.session) |*session| {
        const token = app.live.coherentToken();
        panel.rendered = session.view(token);
        const diagnostics = if (session.completion) |result|
            if (result.completion) |completed| desktop.flash_presenter.Diagnostics.fromResult(completed) else null
        else
            null;
        panel.intent = flash_ui.draw(&session.owner, .{
            .session_token = token,
            .failure = flash.failure,
            .close_requested = &panel.close,
            .details_open = &flash.details_open,
            .diagnostics = diagnostics,
            .light = app.view.toolbar.light,
        }) catch |err| failed: {
            app.view.report(err);
            break :failed null;
        };
    } else if (flash.pending != null or flash.failure != null) {
        flash_ui.drawPending(flash.failure, app.jobs.build != null, &panel.close, app.view.toolbar.light);
    }
    return panel;
}

/// Handles a Flash click: builds fresh firmware first when needed, otherwise
/// admits a session for the current build.
pub fn request(app: *App, captured: desktop.editor_dispatch.Request, board: *const boards.OwnedBoard, can_build: bool) !App.Flow {
    const flash = &app.flash;
    try flash_request.accept(&app.model, captured);
    if (flash.failure != null and flash.session == null) {
        flash.failure = null;
        flash.panel = false;
    }
    if (flash.session) |*previous| {
        // A second click authorizes a new operation only after a terminal
        // outcome; an active transfer is never restarted.
        if (!finished(previous.owner.phase)) {
            flash.panel = true;
            return .next_frame;
        }
        previous.deinit();
        flash.session = null;
        flash.cancelConfirmation();
        flash.failure = null;
        flash.details_open = false;
    }
    const fresh = if (app.build.artifact) |artifact|
        std.mem.eql(u8, &artifact.inputs.project_digest, &(try app.model.id())) and artifactMatchesBundle(artifact)
    else
        false;
    // The accepted build manifest alone is not a flash-tools receipt. Without
    // a fresh build, never open a panel that could imply a verified target.
    if (!fresh) {
        if (app.jobs.busy() or !can_build or app.build.plan == null or app.build.tools == null) {
            app.view.report(error.FreshFirmwareBuildRequired);
            return .next_frame;
        }
        const next_job = try std.math.add(u64, app.job_generation, 1);
        app.jobs.build = workers.startBuild(app, app.build.plan.?.config, next_job) catch |err| {
            app.view.report(err);
            return .next_frame;
        };
        app.job_generation = next_job;
        flash.pending = .{ .snapshot = try app.model.id(), .generation = app.owner_generation };
        app.build.scheduler.manual(try app.model.id());
        flash.panel = true;
        return .proceed;
    }
    const plan = app.build.plan orelse return reportConfigurationChanged(app);
    if (!std.mem.eql(u8, &plan.config.board_id, &app.model.board.id) or
        !std.mem.eql(u8, plan.config.build_board, board.entry.selector)) return reportConfigurationChanged(app);
    const tools = app.build.tools orelse {
        app.view.report(error.FlashToolsReceiptRequired);
        return .proceed;
    };
    if (app.build.generation == 0 or app.jobs.busy()) {
        app.view.report(error.FlashAlreadyInProgress);
        return .next_frame;
    }
    const session = openSession(app, tools, plan.config, try app.model.id()) orelse return .next_frame;
    if (flash.session) |*old| old.deinit();
    flash.session = session;
    flash.panel = true;
    flash.failure = null;
    flash.advance = true;
    app.view.diagnostic = @splat(0);
    return .proceed;
}

fn reportConfigurationChanged(app: *App) App.Flow {
    app.view.report(error.FlashBuildConfigurationChanged);
    return .proceed;
}

/// Admits a session for the current build of `snapshot`. Failures are reported.
fn openSession(
    app: *App,
    tools: jobs_api.flash_inputs.Tools,
    config: desktop.build_worker.Config,
    snapshot: [32]u8,
) ?flash_session.Session {
    var captured = desktop.build_worker.Request.capture(&app.model, config, app.environ_map, app.build.generation) catch |err| {
        app.view.report(err);
        return null;
    };
    var cloned = jobs_api.flash_inputs.Tools.clone(app.gpa, tools.record) catch |err| {
        captured.deinit();
        app.view.report(err);
        return null;
    };
    const build = &app.build;
    const artifact = build.artifact.?;
    const session = flash_session.Session.init(app.gpa, app.io, snapshot, build.generation, artifact, captured, build.tree, cloned);
    return session catch |err| {
        captured.deinit();
        cloned.deinit();
        app.view.report(err);
        return null;
    };
}

/// Runs after the frame was displayed: admission, preparation and the frozen
/// UF2 copy never block the frame that showed the click.
pub fn afterFrame(app: *App, panel: Panel, now_us: u64) !void {
    const flash = &app.flash;
    // Dismissal only hides the panel. The session remains available from the
    // toolbar and cannot implicitly transfer or reset a selected UF2.
    if (panel.close) flash.panel = false;
    if (flash.pending) |pending| {
        if (app.owner_generation != pending.generation or !std.mem.eql(u8, &pending.snapshot, &(try app.model.id()))) {
            flash.pending = null;
            flash.advance = false;
        }
    }
    if (flash.advance and flash.session == null) if (flash.pending) |pending| if (app.build.artifact) |artifact| {
        if (!app.jobs.busy() and artifactMatchesBundle(artifact)) admitPending(app, pending);
    };
    if (flash.session) |*session| {
        if (flash.advance and try session.matchesModel(&app.model, app.build.generation)) {
            flash.advance = false;
            prepareSession(app, session, now_us / 1000);
        }
    }
    try applyIntent(app, panel, now_us);
}

fn admitPending(app: *App, pending: Flash.Pending) void {
    const flash = &app.flash;
    flash.advance = false;
    flash.pending = null;
    const tools = app.build.tools orelse return;
    const plan = app.build.plan orelse return;
    flash.session = openSession(app, tools, plan.config, pending.snapshot) orelse return;
    flash.panel = true;
    flash.failure = null;
    flash.advance = true;
}

/// Prepares, freezes and selects the session, then confirms the view the
/// click authorized. No further panel button is required.
fn prepareSession(app: *App, session: *flash_session.Session, now_ms: u64) void {
    const flash = &app.flash;
    const artifact = app.build.artifact.?;
    session.prepare(now_ms) catch |err| flash.fail(&app.view, err);
    if (flash.failure == null) session.built(artifact, now_ms) catch |err| flash.fail(&app.view, err);
    if (flash.failure == null) {
        if (cacheBase(app, artifact)) |base| freeze(app, session, base, now_ms);
    }
    if (flash.failure == null) session.selectUniqueBootsel() catch |err| flash.fail(&app.view, err);
    if (flash.failure != null) return;
    // The internal selection and frozen hash are bound before HID or
    // picotool can run.
    const shown = session.view(app.live.coherentToken());
    const bound = snapshotOf(session, shown, app.build.generation);
    if (!shown.can_confirm or !flash.gate.confirm(bound, bound)) {
        flash.fail(&app.view, error.StaleFlashRequest);
    } else flash.retained_view = shown;
}

fn cacheBase(app: *const App, artifact: desktop.build_worker.Artifact) ?[]const u8 {
    if (app.user_paths) |owned| return owned.paths.cache;
    return std.fs.path.dirname(artifact.uf2_path);
}

/// Copies the UF2 into `<base>/flash`, where the transfer reads it.
fn freeze(app: *App, session: *flash_session.Session, base: []const u8, now_ms: u64) void {
    const flash = &app.flash;
    var cache = std.Io.Dir.cwd().createDirPathOpen(app.io, base, .{}) catch |err| return flash.fail(&app.view, err);
    defer cache.close(app.io);
    var directory = cache.createDirPathOpen(app.io, "flash", .{}) catch |err| return flash.fail(&app.view, err);
    defer directory.close(app.io);
    const path = directory.realPathFileAlloc(app.io, ".", app.gpa) catch |err| return flash.fail(&app.view, err);
    defer app.gpa.free(path);
    session.freeze(app.build.artifact.?, directory, path, now_ms) catch |err| flash.fail(&app.view, err);
}

fn applyIntent(app: *App, panel: Panel, now_us: u64) !void {
    const flash = &app.flash;
    const intent = panel.intent orelse return;
    const session = if (flash.session) |*value| value else return;
    const now_ms = now_us / 1000;
    switch (std.meta.activeTag(intent)) {
        .prepare => session.prepare(now_ms) catch |err| flash.fail(&app.view, err),
        .build => session.built(app.build.artifact.?, now_ms) catch |err| flash.fail(&app.view, err),
        .freeze => freeze(app, session, cacheBase(app, app.build.artifact.?) orelse return error.FlashCacheUnavailable, now_ms),
        .select => session.selectUniqueBootsel() catch |err| flash.fail(&app.view, err),
        .confirm => {
            const shown = panel.rendered orelse return error.FlashViewMissing;
            const current = session.view(shown.previous_session_token);
            const rendered_snapshot = snapshotOf(session, shown, app.build.generation);
            const current_snapshot = snapshotOf(session, current, app.build.generation);
            if (!shown.can_confirm or !current.can_confirm or !try session.matchesModel(&app.model, app.build.generation) or
                !flash.gate.confirm(rendered_snapshot, current_snapshot))
            {
                flash.gate.cancel();
                app.view.report(error.StaleFlashRequest);
                return;
            }
            flash.retained_view = shown;
        },
        .cancel => {
            flash.cancelConfirmation();
            _ = session.cancel() catch |err| flash.fail(&app.view, err);
        },
        .reset => {
            flash.cancelConfirmation();
            session.deinit();
            flash.session = null;
            flash.panel = false;
        },
    }
}
