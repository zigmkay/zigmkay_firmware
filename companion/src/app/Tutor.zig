//! Typing tutor wiring: layout profile derivation, persistence, frozen Snapshot
//! isolation, Live-HID / Unflashed draft routing, and screen orchestration.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const project = @import("project");
const boards = @import("catalog-project");
const tutor = @import("practice-ui");
const ui = @import("editor-ui");
const App = @import("App.zig");
const Captions = @import("Captions.zig");

const Tutor = @This();

controller: desktop.practice_controller.Controller,
/// The project of the active run, frozen when it starts.
snapshot: ?Snapshot = null,
view: tutor.View = .{},
bound_profile_hash: ?[32]u8 = null,
bound_board_id: [64]u8 = @splat(0),
bound_board_id_len: usize = 0,
bound_host_layout: [64]u8 = @splat(0),
bound_host_layout_len: usize = 0,

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
    if (self.snapshot) |*value| value.deinit();
}

/// Derives a `LayoutProfile` from the active board geometry, resolved `LabelCache`,
/// and `Document.combos` (translating combo outputs through the active translator).
pub fn deriveLayoutProfile(
    app: *App,
    board: *const boards.OwnedBoard,
    labels: *const desktop.label_cache.LabelCache,
    doc: project.Document,
    host_layout: []const u8,
) !desktop.practice_layout_profile.LayoutProfile {
    const lp = desktop.practice_layout_profile;
    var geo_buf: [lp.max_keys]lp.GeometryKey = undefined;
    const key_count = @min(board.entry.geometry.len, lp.max_keys);
    for (board.entry.geometry[0..key_count], 0..) |g, i| {
        geo_buf[i] = .{
            .key_index = g.key_index,
            .x = g.x,
            .y = g.y,
            .width = g.width,
            .height = g.height,
            .rotation = g.rotation,
            .hand = switch (g.hand) {
                .left => .left,
                .right => .right,
                .neutral => .neutral,
            },
            .group = switch (g.group) {
                .finger => .finger,
                .thumb => .thumb,
            },
            .home_row = g.home_row,
        };
    }

    var combo_buf: [lp.max_combos]lp.ComboInput = undefined;
    var combo_len: usize = 0;
    for (doc.combos) |combo| {
        if (combo_len >= combo_buf.len) break;
        const k0 = project.keyIndex(doc, combo.key_ids[0]) catch continue;
        const k1 = project.keyIndex(doc, combo.key_ids[1]) catch continue;
        const layer_idx = project.layerIndex(doc, combo.layer_id) catch continue;
        const lowered = project.lowerAction(doc, combo.action) catch continue;

        var buf: [64]u8 = undefined;
        const content = if (app.source) |*source|
            desktop.label_cache.computeKeyContent(source, lowered, .{}, &buf)
        else
            desktop.label_cache.computeKeyContent(&app.translator, lowered, .{}, &buf);

        var out_cp: ?u21 = null;
        if (!content.unproven and !content.dead and !content.shortcut) {
            if (content.hid_code) |code| {
                if (code == 44) out_cp = ' ';
            }
            if (out_cp == null) {
                if (content.label) |lbl| {
                    if (lbl.len > 0) {
                        const seq = std.unicode.utf8ByteSequenceLength(lbl[0]) catch 0;
                        if (seq == lbl.len) {
                            out_cp = std.unicode.utf8Decode(lbl) catch null;
                        }
                    }
                }
            }
        }
        if (out_cp != null) {
            combo_buf[combo_len] = .{
                .layer = layer_idx,
                .key_indices = .{ k0, k1 },
                .output_cp = out_cp,
                .unproven = content.unproven,
                .dead = content.dead,
                .shortcut = content.shortcut,
            };
            combo_len += 1;
        }
    }

    const fidelity: lp.Fidelity = switch (board.entry.fidelity) {
        .schematic => .schematic,
        .linear => .linear,
    };

    const profile_id = std.mem.sliceTo(&doc.profile_id, 0);
    return lp.derive(geo_buf[0..key_count], labels.practiceLabels(), .{
        .board_id = board.entry.selector,
        .base_layout_fingerprint = profile_id,
        .host_layout = host_layout,
        .fidelity = fidelity,
        .combos = combo_buf[0..combo_len],
    });
}

fn syncProfileAndPersistence(
    app: *App,
    board: *const boards.OwnedBoard,
    labels: *const desktop.label_cache.LabelCache,
    model: *const desktop.model.Model,
    host_layout: []const u8,
) void {
    const self = &app.tutor;
    const derived = deriveLayoutProfile(app, board, labels, model.document(), host_layout) catch return;

    const needs_rebind = !self.controller.profile_bound or
        self.bound_profile_hash == null or
        !std.mem.eql(u8, &self.bound_profile_hash.?, &derived.profile_hash) or
        !std.mem.eql(u8, &self.controller.profile.positions_digest, &derived.positions_digest);

    if (!needs_rebind) return;

    const same_profile = self.bound_profile_hash != null and
        std.mem.eql(u8, &self.bound_profile_hash.?, &derived.profile_hash);

    if (same_profile) {
        // Individual keys edited within the same profile: partial reset only moved keys.
        const prev_positions = self.controller.profile.keyPositionSlice();
        _ = self.controller.learning.applyLayoutDiff(prev_positions, derived.keyPositionSlice());
        self.controller.profile = derived;
        self.controller.needs_persist = true;
        return;
    }

    // Load persisted state for this profile when running outside offline fixtures.
    var loaded: ?desktop.practice_storage.LoadedState = null;
    defer if (loaded) |*l| l.deinit();
    if (app.frame_limit == null) {
        if (app.user_paths) |owned| {
            if (std.Io.Dir.cwd().createDirPathOpen(app.io, owned.paths.data, .{})) |data_dir| {
                var d = data_dir;
                defer d.close(app.io);
                loaded = desktop.practice_storage.loadState(app.gpa, app.io, d, derived.profile_hash) catch null;
            } else |_| {}
        }
    }

    _ = self.controller.bindProfile(derived, if (loaded) |l| (if (l.existed) l.state else null) else null);
    self.bound_profile_hash = derived.profile_hash;
    const bid_len = @min(board.entry.selector.len, self.bound_board_id.len);
    @memcpy(self.bound_board_id[0..bid_len], board.entry.selector[0..bid_len]);
    self.bound_board_id_len = bid_len;
    const hl_len = @min(host_layout.len, self.bound_host_layout.len);
    @memcpy(self.bound_host_layout[0..hl_len], host_layout[0..hl_len]);
    self.bound_host_layout_len = hl_len;
}

fn flushPersistence(app: *App) void {
    const self = &app.tutor;
    if (app.frame_limit != null or !self.controller.needs_persist) return;
    const owned = app.user_paths orelse return;
    var data_dir = std.Io.Dir.cwd().createDirPathOpen(app.io, owned.paths.data, .{}) catch return;
    defer data_dir.close(app.io);
    self.controller.persistPending(
        app.gpa,
        app.io,
        data_dir,
        self.bound_board_id[0..self.bound_board_id_len],
        self.bound_host_layout[0..self.bound_host_layout_len],
    ) catch {};
}

/// Keeps the run's frozen project current and advances the run. Returns the
/// project that controls practice input.
pub fn observe(app: *App, now_us: u64) !*desktop.model.Model {
    const self = &app.tutor;
    const practice = &self.controller;
    const utc_ns = std.Io.Timestamp.now(app.io, .real).nanoseconds;
    if (utc_ns > 0) practice.utc_now_sec = @intCast(@divTrunc(utc_ns, std.time.ns_per_s));

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
    flushPersistence(app);
    return control_model;
}

pub fn prepareFrame(app: *App, board: *const boards.OwnedBoard) !Frame {
    const self = &app.tutor;
    const practice = &self.controller;
    const live = if (self.snapshot) |*value| value.live else practice.config.source == .os and app.live.verified();
    const labels = if (self.snapshot) |*value|
        &value.captions.labels
    else if (live) &app.live.captions.labels else &app.captions.labels;
    const active_board = if (self.snapshot) |*value|
        &value.board
    else if (live) &app.live.board else board;
    const geometry = active_board.entry.geometry;
    const model = if (self.snapshot) |*value| &value.model else if (live) &app.live.model else &app.model;
    const host_layout = if (app.source) |*source| source.id() else "offline";

    syncProfileAndPersistence(app, active_board, labels, model, host_layout);

    // Zero-friction entry: when entering Tutor mode in interactive use, immediately prepare a ready round.
    if (app.practicing and app.frame_limit == null and practice.config.mode == .tutor and !practice.active) {
        const now_us: u64 = @intCast(@max(0, app.native.nanoTime()) / 1000);
        const prepared = if (app.build.runner) |runner| runner.record.inputs.project_digest else null;
        if (practice.ensureReady(prepared, now_us)) |eff| {
            app.applyPractice(eff, model, now_us);
        } else |_| {}
    }

    const arena = app.window.arena();
    const metadata = try arena.alloc(desktop.practice.KeyMetadata, labels.key_count);
    @memset(metadata, .{});
    for (geometry) |key| metadata[key.key_index] = .{
        .hand = @fromBackingInt(@backingInt(key.hand)),
        .thumb = key.group == .thumb,
        .home_row = key.home_row,
    };

    const draft = &app.draft_runtime;
    const pressed = try arena.alloc(bool, labels.key_count);
    @memset(pressed, false);
    if (live and app.live.frame.pressed.len == pressed.len) {
        @memcpy(pressed, app.live.frame.pressed);
    } else if (draft.owner) |runner| if (runner.pressed.len == pressed.len) {
        @memcpy(pressed, runner.pressed);
    };

    const layer = if (live) app.live.frame.layer else if (draft.owner != null) draft.highest_layer else 0;
    const active_layers = if (live) app.live.frame.active else if (draft.owner != null) draft.active_layers else 1;
    const modifiers = if (live) app.live.frame.modifiers else @as(@TypeOf(app.live.frame.modifiers), @bitCast(draft.modifiers));

    // Mirror telemetry into Test keys mode without touching tutor scoring or persistence.
    if (practice.config.mode == .test_keys) {
        practice.test_keys.active_layers = active_layers;
        practice.test_keys.highest_layer = layer;
        practice.test_keys.modifiers = modifiers.toByte();
    }

    return .{ .labels = labels, .live = live, .metadata = metadata, .keyboard = .{
        .source = if (live) .live else if (draft.owner != null) .simulated else .draft,
        .labels = labels,
        .geometry = geometry,
        .metadata = metadata,
        .profile = model.document().name,
        .layer = layer,
        .active_layers = active_layers,
        .modifiers = modifiers,
        .pressed = pressed,
    } };
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
    flushPersistence(app);
}
