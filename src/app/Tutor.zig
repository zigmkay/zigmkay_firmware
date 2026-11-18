//! Typing tutor wiring: which project and labels a run practices on, its
//! measurement context, result history, and the tutor screen.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const project = @import("project");
const boards = @import("catalog-project");
const tutor = @import("practice-ui");
const ui = @import("editor-ui");
const App = @import("App.zig");
const Captions = @import("Captions.zig");
const practice_persistence = @import("practice_persistence.zig");

const Tutor = @This();

controller: desktop.practice_controller.Controller,
/// The project of the active run, frozen when it starts.
snapshot: ?Snapshot = null,
timing: desktop.practice_timing.Recorder,
view: tutor.View = .{},
history: desktop.practice_history_runtime.Runtime,
history_loaded: bool = false,

/// The project a run practices on, frozen independently of later edits.
pub const Snapshot = struct {
    model: desktop.model.Model,
    captions: Captions,
    board: boards.OwnedBoard,
    generation: u64,
    control: [32]u8,
    live: bool,

    /// Freezes `selected` for the run that the controller just started.
    pub fn init(app: *App, selected: *const desktop.model.Model, live: bool) !Snapshot {
        var frozen = try desktop.model.Model.init(app.gpa, selected.board, selected.current.snapshot);
        errdefer frozen.deinit();
        var captions = try app.captionsFor(&frozen, "Offline fixture");
        errdefer captions.deinit();
        const practice = &app.tutor.controller;
        return .{
            .model = frozen,
            .captions = captions,
            .board = try boards.OwnedBoard.fromDocument(app.gpa, frozen.document()),
            .generation = practice.generation,
            .control = practice.current,
            .live = live,
        };
    }

    pub fn deinit(self: *Snapshot) void {
        self.board.deinit();
        self.captions.deinit();
        self.model.deinit();
    }
};

/// The labels and input state the tutor shows this frame.
pub const Frame = struct {
    labels: *const desktop.label_cache.LabelCache,
    /// Whether the run practices on the verified live keyboard.
    live: bool,
    metadata: []desktop.practice.KeyMetadata,
    keyboard: tutor.Frame,
};

/// What the tutor screen asked for this frame.
pub const Outcome = struct {
    leave: bool = false,
    action: ?desktop.practice_controller.Action = null,
    input_effect: desktop.practice_controller.Effect = .{},
};

pub fn deinit(self: *Tutor) void {
    self.history.deinit();
    self.timing.deinit();
    if (self.snapshot) |*value| value.deinit();
}

/// Keeps the run's frozen project current and advances the run. Returns the
/// project that controls practice input.
pub fn observe(app: *App, now_us: u64) !*desktop.model.Model {
    const self = &app.tutor;
    const practice = &self.controller;
    if (!practice.active or (self.snapshot != null and !std.mem.eql(u8, &self.snapshot.?.control, &practice.current))) {
        if (self.snapshot) |*value| value.deinit();
        self.snapshot = null;
    }
    if (practice.active and self.snapshot == null and app.frame_limit == null) {
        const live = practice.captured_config.source == .os and app.live.verified();
        const selected = if (live) &app.live.model else &app.model;
        self.snapshot = try Snapshot.init(app, selected, live);
    }
    const control_model = if (self.snapshot) |*value| &value.model else &app.model;
    const control_id = if (self.snapshot) |*value| value.control else try app.model.id();
    app.applyPractice(practice.observe(control_id, now_us), control_model, now_us);
    app.draft_runtime.poll(practice, control_model, now_us) catch |err| {
        app.draft_runtime.fail(practice, err, now_us);
        app.view.report(err);
    };
    if (app.checkingDraft()) {
        if (practice.failure) |failure| return failure;
        if (practice.session.len > 1) return error.DraftRepeatRoutingFailed;
    }
    return control_model;
}

pub fn prepareFrame(app: *App, board: *const boards.OwnedBoard, now_us: u64) !Frame {
    const self = &app.tutor;
    const practice = &self.controller;
    const live = if (self.snapshot) |*value| value.live else practice.config.source == .os and app.live.verified();
    const labels = if (self.snapshot) |*value|
        &value.captions.labels
    else if (live) &app.live.captions.labels else &app.captions.labels;
    practice.curriculum_labels = labels.practiceLabels();
    const geometry = if (self.snapshot) |*value|
        value.board.entry.geometry
    else if (live) app.live.board.entry.geometry else board.entry.geometry;
    const model = if (self.snapshot) |*value| &value.model else if (live) &app.live.model else &app.model;
    try updateCohort(app, model, labels, live, now_us);

    const arena = app.window.arena();
    const metadata = try arena.alloc(desktop.practice.KeyMetadata, labels.key_count);
    @memset(metadata, .{});
    for (geometry) |key| metadata[key.key_index] = .{
        .hand = @fromBackingInt(@backingInt(key.hand)),
        .thumb = key.group == .thumb,
        .home_row = key.home_row,
    };
    try updateHandCoverage(app, labels, metadata);

    const draft = &app.draft_runtime;
    const pressed = try arena.alloc(bool, labels.key_count);
    @memset(pressed, false);
    if (live and app.live.frame.pressed.len == pressed.len) {
        @memcpy(pressed, app.live.frame.pressed);
    } else if (draft.owner) |runner| if (runner.pressed.len == pressed.len) {
        @memcpy(pressed, runner.pressed);
    };
    return .{ .labels = labels, .live = live, .metadata = metadata, .keyboard = .{
        .source = if (live) .live else if (draft.owner != null) .simulated else .draft,
        .labels = labels,
        .geometry = geometry,
        .metadata = metadata,
        .profile = model.document().name,
        .layer = if (live) app.live.frame.layer else if (draft.owner != null) draft.highest_layer else 0,
        .active_layers = if (live) app.live.frame.active else if (draft.owner != null) draft.active_layers else 1,
        .modifiers = if (live) app.live.frame.modifiers else @bitCast(draft.modifiers),
        .pressed = pressed,
    } };
}

/// Describes the measurement context of the run. Results are scored only
/// while the context stays the one the run started with.
fn updateCohort(
    app: *App,
    model: *const desktop.model.Model,
    labels: *const desktop.label_cache.LabelCache,
    live: bool,
    now_us: u64,
) !void {
    const practice = &app.tutor.controller;
    const identity = try project.snapshot.identity(app.gpa, model.current.snapshot, model.board);
    var behavior = std.crypto.hash.sha2.Sha256.init(.{});
    behavior.update(&identity.board_id);
    behavior.update(&identity.digest);
    const source_name = if (app.source) |*source| source.id() else "Offline fixture";
    desktop.practice_results.displayName(model.document().name, &practice.context_profile);
    desktop.practice_results.displayName(source_name, &practice.context_source);
    const mapping_name = if (app.source) |*source|
        try std.fmt.allocPrint(app.window.arena(), "{s}/{s}", .{ source.id(), source.layoutId() })
    else
        "Offline fixture";
    practice.cohort.behavior = behavior.finalResult();
    practice.cohort.mapping = desktop.practice_context.mapping(labels, mapping_name);
    practice.cohort.verified = (live or practice.config.source == .draft) and
        if (app.source) |*source| source.hasActiveLayout() else false;
    if (app.frame_limit != null and app.count == 1 and practice.active) {
        practice.captured_cohort.behavior = practice.cohort.behavior;
        practice.captured_cohort.mapping = practice.cohort.mapping;
        practice.captured_cohort.verified = practice.cohort.verified;
    }
    const changed = !std.mem.eql(u8, &practice.cohort.behavior, &practice.captured_cohort.behavior) or
        !std.mem.eql(u8, &practice.cohort.mapping, &practice.captured_cohort.mapping) or
        practice.cohort.verified != practice.captured_cohort.verified;
    if (practice.active and practice.session.state != .complete and changed and practice.generation != 0) {
        practice.session.scored = false;
        app.applyPractice(practice.pause(now_us), &app.model, now_us);
        practice.failure = error.PracticeContextChanged;
    }
}

/// Exercises may balance both hands only when every capital letter's hand is
/// known through a known host layout.
fn updateHandCoverage(
    app: *App,
    labels: *const desktop.label_cache.LabelCache,
    metadata: []const desktop.practice.KeyMetadata,
) !void {
    var coverage: desktop.practice_generator.HandCoverage = .{};
    for ('A'..'Z' + 1) |capital| {
        const route = try desktop.practice.hint(labels.practiceLabels(), 0, 0, @intCast(capital), 1) orelse continue;
        switch (metadata[route.key].hand) {
            .left => coverage.left[capital - 'A'] = true,
            .right => coverage.right[capital - 'A'] = true,
            .neutral => {},
        }
    }
    const known = if (app.source) |*source| source.hasActiveLayout() else app.frame_limit != null;
    const both_hands = std.mem.indexOfScalar(bool, &coverage.left, true) != null and
        std.mem.indexOfScalar(bool, &coverage.right, true) != null;
    app.tutor.controller.normal_coverage = if (known and both_hands) coverage else null;
}

/// Captures finished results and schedules history reads and writes.
pub fn persist(app: *App, frame: Frame, now_us: u64) !void {
    try practice_persistence.update(&app.tutor, app.io, frame.labels, .{
        .now_us = now_us,
        .practicing = app.practicing,
        .rundown_fixture = app.mode.isRundown(),
        .data_preview = app.mode.isScene(.data),
    });
}

/// Runs a requested history import or export.
pub fn transferHistory(self: *Tutor) void {
    self.history.poll();
    if (self.view.transfer == .none) return;
    const path = std.mem.sliceTo(&self.view.data_path, 0);
    self.history.transfer(self.controller.configCohort(), path, self.view.transfer == .import_database) catch |err| {
        self.history.error_value = err;
    };
    self.view.transfer = .none;
}

pub fn draw(app: *App, frame: Frame, now_us: u64) Outcome {
    const self = &app.tutor;
    const practice = &self.controller;
    const theme = ui.Theme.get(app.view.toolbar.light);
    const canvas = dvui.box(@src(), .{}, .{
        .expand = .both,
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
    });
    defer canvas.deinit();
    var outcome: Outcome = .{};
    outcome.leave = ui.button(theme, "Back to editor", "practice.back", .{ .x = 24, .y = 12, .w = 160, .h = 36 });
    // A run on the OS source waits for the live keyboard to verify itself.
    const waiting_for_live = practice.config.source == .os and app.live_enabled and !frame.live;
    const input: tutor.Input = .{
        .now_us = now_us,
        .window_focused = app.focused(),
        .owns_input = true,
        .fixture = app.frame_limit != null,
        .diagnostic = std.mem.sliceTo(&app.view.diagnostic, 0),
        .frame = if (waiting_for_live) null else frame.keyboard,
        .history = &self.history.data,
        .history_cohort = self.history.cohort,
        .history_saving = self.history.worker != null,
        .history_failure = self.history.error_value,
        .history_path = self.history.path orelse "",
        .history_pending = self.history.queued,
        .event_times = app.events.times[0..app.events.time_count],
    };
    const rect = app.window.data().rect;
    const bounds: dvui.Rect = .{ .x = 24, .y = 64, .w = @max(300, rect.w - 48), .h = @max(300, rect.h - 88) };
    const drawn = tutor.draw(practice, &self.view, theme, bounds, input) catch |err| failed: {
        app.view.report(err);
        break :failed tutor.DrawResult{};
    };
    outcome.action = drawn.action;
    outcome.input_effect = drawn.input_effect;
    return outcome;
}

/// Applies the input and the action of the displayed frame.
pub fn finishFrame(app: *App, outcome: Outcome, control_model: *desktop.model.Model, now_us: u64) void {
    const self = &app.tutor;
    const practice = &self.controller;
    app.applyPractice(outcome.input_effect, control_model, now_us);
    if (outcome.leave) {
        app.applyPractice(practice.pause(now_us), &app.model, now_us);
        app.practicing = false;
    } else if (outcome.action) |action| {
        const prepared = if (app.build.runner) |runner| runner.record.inputs.project_digest else null;
        const effect = tutor.apply(practice, &self.view, action, .{ .now_us = now_us, .prepared_snapshot = prepared }) catch |err| failed: {
            app.view.report(err);
            break :failed desktop.practice_controller.Effect{};
        };
        app.applyPractice(effect, control_model, now_us);
    }
}
