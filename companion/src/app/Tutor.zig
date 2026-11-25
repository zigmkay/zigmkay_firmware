//! Typing tutor wiring: layout profile derivation, persistence, frozen Snapshot
//! isolation, Live-HID routing, and screen orchestration.
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
loaded_runs: ?desktop.practice_storage.LoadedRuns = null,
bound_profile_hash: ?[32]u8 = null,
bound_board_id: [64]u8 = @splat(0),
bound_board_id_len: usize = 0,
bound_host_layout: [64]u8 = @splat(0),
bound_host_layout_len: usize = 0,
/// Set when the bound profile's saved state could not be read; nothing is
/// saved over it until the next rebind.
persistence_blocked: bool = false,
/// Earliest monotonic time a failed save is retried.
persist_retry_us: u64 = 0,
/// Whether the last save failed; the failure is reported once per streak.
persist_failing: bool = false,

/// Time between retries of a failed progress save.
const persist_retry_interval_us: u64 = 5 * std.time.us_per_s;

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
};

pub fn deinit(self: *Tutor) void {
    if (self.loaded_runs) |*runs| runs.deinit();
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
    const source: desktop.practice_profile_source.Board = .{
        .geometry = board.entry.geometry,
        .fidelity = switch (board.entry.fidelity) {
            .schematic => .schematic,
            .linear => .linear,
        },
    };
    if (app.source) |*host| return desktop.practice_profile_source.derive(source, labels, doc, host, host_layout);
    return desktop.practice_profile_source.derive(source, labels, doc, &app.translator, host_layout);
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

    const board_id = board.entry.selector[0..@min(board.entry.selector.len, self.bound_board_id.len)];
    const board_input: desktop.practice_controller.Controller.BoardInput = .{
        .id = board_id,
        .labels = labels.practiceLabels(),
    };
    const needs_rebind = !self.controller.profile_bound or
        self.bound_profile_hash == null or
        !std.mem.eql(u8, &self.bound_profile_hash.?, &derived.profile_hash) or
        !std.mem.eql(u8, &self.controller.profile.positions_digest, &derived.positions_digest) or
        !std.mem.eql(u8, self.bound_board_id[0..self.bound_board_id_len], board_id);

    if (!needs_rebind) return;

    const same_profile = self.bound_profile_hash != null and
        std.mem.eql(u8, &self.bound_profile_hash.?, &derived.profile_hash);

    if (same_profile) {
        // Another keyboard or edited keys of the same layout type: statistics
        // stay, and moved practised characters wait for the user's answer.
        self.controller.adoptLayout(derived, board_input);
        self.rememberBoard(board_id);
        return;
    }

    // Pending work (a round record, a confirmed reset) belongs to the profile it
    // was made in. Write it there while that profile is still bound, then drop
    // it so it can never be applied to the next profile.
    if (self.bound_profile_hash != null and self.controller.needs_persist and
        !self.persistence_blocked and app.frame_limit == null)
    {
        if (app.user_paths) |owned| persistTo(app, owned.paths.data) catch |err| app.view.report(err);
    }
    self.controller.discardPending();
    // Choices made for the previous profile do not apply to this one.
    self.view.picks = .{};
    if (self.view.sheet == .layout_changes or self.view.sheet == .reset_keys) self.view.sheet = .none;

    // Load persisted state for this profile when running outside offline fixtures.
    // A read failure is not "no saved state": bind fresh for this session but
    // block saving, so the real progress on disk is never overwritten.
    var loaded: ?desktop.practice_storage.LoadedState = null;
    defer if (loaded) |*l| l.deinit();
    var blocked = false;
    if (app.frame_limit == null) {
        if (app.user_paths) |owned| {
            if (std.Io.Dir.cwd().createDirPathOpen(app.io, owned.paths.data, .{})) |data_dir| {
                var d = data_dir;
                defer d.close(app.io);
                loaded = desktop.practice_storage.loadState(app.gpa, app.io, d, derived.profile_hash) catch |err| failed: {
                    blocked = true;
                    app.view.report(err);
                    break :failed null;
                };
            } else |err| {
                blocked = true;
                app.view.report(err);
            }
        }
    }
    self.persistence_blocked = blocked;
    self.persist_failing = false;
    self.persist_retry_us = 0;

    _ = self.controller.bindProfile(derived, if (loaded) |l| (if (l.existed) l.state else null) else null);
    self.controller.adoptBoard(board_input);
    self.bound_profile_hash = derived.profile_hash;
    self.rememberBoard(board_id);
    const hl_len = @min(host_layout.len, self.bound_host_layout.len);
    @memcpy(self.bound_host_layout[0..hl_len], host_layout[0..hl_len]);
    self.bound_host_layout_len = hl_len;
}

fn rememberBoard(self: *Tutor, board_id: []const u8) void {
    @memcpy(self.bound_board_id[0..board_id.len], board_id);
    self.bound_board_id_len = board_id.len;
}

fn flushPersistence(app: *App, now_us: u64) void {
    const self = &app.tutor;
    if (app.frame_limit != null or !self.controller.needs_persist or self.persistence_blocked) return;
    if (now_us < self.persist_retry_us) return;
    const owned = app.user_paths orelse return;
    persistTo(app, owned.paths.data) catch |err| {
        // Retry with a backoff instead of every frame, and report once.
        self.persist_retry_us = now_us +| persist_retry_interval_us;
        if (!self.persist_failing) app.view.report(err);
        self.persist_failing = true;
        return;
    };
    self.persist_failing = false;
    self.persist_retry_us = 0;
}

fn persistTo(app: *App, data_path: []const u8) !void {
    const self = &app.tutor;
    var data_dir = try std.Io.Dir.cwd().createDirPathOpen(app.io, data_path, .{});
    defer data_dir.close(app.io);
    try self.controller.persistPending(
        app.gpa,
        app.io,
        data_dir,
        self.bound_board_id[0..self.bound_board_id_len],
        self.bound_host_layout[0..self.bound_host_layout_len],
    );
}

/// Keeps the run's frozen project current and advances the run. Returns the
/// project that controls practice input.
pub fn observe(app: *App, now_us: u64) !void {
    const self = &app.tutor;
    const practice = &self.controller;
    const utc_ns = std.Io.Timestamp.now(app.io, .real).nanoseconds;
    if (utc_ns > 0) practice.utc_now_sec = @intCast(@divTrunc(utc_ns, std.time.ns_per_s));

    if (!practice.active or (self.snapshot != null and !std.mem.eql(u8, &self.snapshot.?.control, &practice.current))) {
        if (self.snapshot) |*value| value.deinit();
        self.snapshot = null;
    }
    if (practice.active and self.snapshot == null and app.frame_limit == null) {
        const live = app.live.verified();
        const selected = if (live) &app.live.model else &app.model;
        self.snapshot = try Snapshot.init(app, selected, live);
    }
    practice.observe(if (self.snapshot) |*value| value.control else try app.model.id());
    routeTapHolds(app);
    flushPersistence(app, now_us);
}

/// Hands the keyboard's tap/hold decisions to a lesson typed on that very
/// keyboard and layout; the controller ignores them outside a lesson. Others
/// are dropped, so none of them is counted against a later lesson.
fn routeTapHolds(app: *App) void {
    const self = &app.tutor;
    defer app.live.tap_holds.clear();
    const snapshot = if (self.snapshot) |*value| value else return;
    if (!snapshot.live or !app.live.verified() or !sameLayout(&snapshot.model, &app.live.model)) return;
    for (app.live.tap_holds.slice()) |decision| _ = self.controller.observeTapHold(decision);
}

pub fn prepareFrame(app: *App, board: *const boards.OwnedBoard) !Frame {
    const self = &app.tutor;
    const practice = &self.controller;
    const live = if (self.snapshot) |*value| value.live else app.live.verified();
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
        practice.ensureReady() catch {};
    }

    const arena = app.window.arena();
    const metadata = try arena.alloc(desktop.practice.KeyMetadata, labels.key_count);
    @memset(metadata, .{});
    for (geometry) |key| metadata[key.key_index] = .{
        .hand = @fromBackingInt(@backingInt(key.hand)),
        .thumb = key.group == .thumb,
        .home_row = key.home_row,
    };

    const pressed = try arena.alloc(bool, labels.key_count);
    @memset(pressed, false);
    if (live and app.live.frame.pressed.len == pressed.len) {
        @memcpy(pressed, app.live.frame.pressed);
    }

    const layer = if (live) app.live.frame.layer else 0;
    const active_layers = if (live) app.live.frame.active else 1;
    const modifiers: @TypeOf(app.live.frame.modifiers) = if (live) app.live.frame.modifiers else .{};

    // Mirror telemetry into Test keys mode without touching tutor scoring or persistence.
    if (practice.config.mode == .test_keys) {
        practice.test_keys.active_layers = active_layers;
        practice.test_keys.highest_layer = layer;
        practice.test_keys.modifiers = modifiers.toByte();
        var count_down: usize = 0;
        for (pressed) |is_down| {
            if (is_down) count_down += 1;
        }
        practice.test_keys.pressed_count = count_down;
        var matched_combo: ?u21 = null;
        if (practice.profile_bound and count_down >= 2) {
            for (practice.profile.comboSlice()) |c| {
                if (c.combo_key_index) |k1| {
                    if (c.layer == layer and
                        c.key_index < pressed.len and k1 < pressed.len and
                        pressed[c.key_index] and pressed[k1])
                    {
                        matched_combo = c.cp;
                        break;
                    }
                }
            }
        }
        practice.test_keys.active_combo_cp = matched_combo;
    }

    const doc = model.document();
    const layer_name = if (layer < doc.layers.len) doc.layers[layer].name else "";
    // Practice types on the connected keyboard. Say so when that keyboard is
    // not known to run the layout the editor holds.
    const layout_notice: tutor.LayoutNotice = if (app.frame_limit != null)
        app.fixture.layout_notice
    else if (!live)
        .unverified
    else if (sameLayout(&app.live.model, &app.model)) .none else .editor_changed;
    return .{ .labels = labels, .live = live, .metadata = metadata, .keyboard = .{
        .source = if (live) .live else .guide,
        .labels = labels,
        .geometry = geometry,
        .metadata = metadata,
        .board_name = active_board.entry.display.name,
        .profile = doc.name,
        .layer_name = layer_name,
        .layer = layer,
        .active_layers = active_layers,
        .modifiers = modifiers,
        .pressed = pressed,
        .layout_notice = layout_notice,
    } };
}

/// A catalog keyboard by selector, for the before/now comparison of moved keys.
fn boardLookup(board_id: []const u8) ?tutor.BoardInfo {
    const entry = boards.findEntry(board_id) orelse return null;
    return .{ .name = entry.display.name, .geometry = entry.geometry };
}

fn sameLayout(a: *const desktop.model.Model, b: *const desktop.model.Model) bool {
    const left = a.id() catch return false;
    const right = b.id() catch return false;
    return std.mem.eql(u8, &left, &right);
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
    // A run on the OS source waits for the live keyboard to verify itself.
    const waiting_for_live = app.live_enabled and !frame.live;
    // Load runs.jsonl on demand only while the Progress sheet is open; free when closed.
    if (self.view.sheet == .progress) {
        if (self.loaded_runs == null and app.frame_limit == null and practice.profile_bound) {
            if (app.user_paths) |owned| {
                if (std.Io.Dir.cwd().openDir(app.io, owned.paths.data, .{})) |data_dir| {
                    var d = data_dir;
                    defer d.close(app.io);
                    self.loaded_runs = desktop.practice_storage.loadRuns(app.gpa, app.io, d, practice.profile.profile_hash) catch null;
                } else |_| {}
            }
        }
    } else if (app.frame_limit == null and self.loaded_runs != null) {
        self.loaded_runs.?.deinit();
        self.loaded_runs = null;
    }

    const input: tutor.Input = .{
        .now_us = now_us,
        .window_focused = app.focused(),
        .owns_input = true,
        .fixture = app.frame_limit != null,
        .diagnostic = std.mem.sliceTo(&app.view.diagnostic, 0),
        .frame = if (waiting_for_live) null else frame.keyboard,
        .event_times = app.events.times[0..app.events.time_count],
        .runs = if (self.loaded_runs) |r| r.runs else &.{},
        .board_lookup = boardLookup,
    };
    const rect = app.window.data().rect;
    const bounds: dvui.Rect = .{ .x = 0, .y = 0, .w = @max(300, rect.w), .h = @max(300, rect.h) };
    const drawn = tutor.draw(practice, &self.view, theme, bounds, input) catch |err| failed: {
        app.view.report(err);
        break :failed tutor.DrawResult{};
    };
    outcome.leave = drawn.leave;
    outcome.action = drawn.action;
    return outcome;
}

/// Applies the input and the action of the displayed frame.
pub fn finishFrame(app: *App, outcome: Outcome, now_us: u64) void {
    const self = &app.tutor;
    const practice = &self.controller;
    if (outcome.leave) {
        practice.pause(now_us);
        app.practicing = false;
    } else if (outcome.action) |action| {
        if (action.intent == .reset_progress) {
            if (self.loaded_runs) |*runs| runs.deinit();
            self.loaded_runs = null;
        }
        tutor.apply(practice, &self.view, action, .{ .now_us = now_us }) catch |err| app.view.report(err);
    }
    flushPersistence(app, now_us);
}
