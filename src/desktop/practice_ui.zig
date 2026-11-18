//! Retained tutor controls over injected project/live views and explicit effects.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const model = @import("layout-model");
const geometry = @import("physical-ui");
const presentation = @import("practice_presentation.zig");
const control = desktop.practice_controller;
const rundown = @import("practice_rundown.zig");
const progress_ui = @import("practice_progress_ui.zig");
const diagnostics_ui = @import("practice_diagnostics_ui.zig");
const curriculum_ui = @import("practice_curriculum_ui.zig");
const help = desktop.practice_help;
const help_ui = @import("practice_help_ui.zig");

pub const Frame = struct {
    /// Live frames must come from the coherent identity-checked session adapter.
    /// Native text and an editable draft never establish a live frame.
    source: enum { draft, simulated, live },
    labels: *const desktop.label_cache.LabelCache,
    geometry: []const model.physical_layout.Key,
    metadata: ?[]const desktop.practice.KeyMetadata = null,
    profile: []const u8,
    layer: usize = 0,
    active_layers: u16 = 1,
    modifiers: model.Modifiers = .{},
    pressed: []const bool,
    stale: bool = false,
};

pub const Input = struct {
    now_us: u64,
    window_focused: bool = false,
    owns_input: bool = false,
    prepared_snapshot: ?control.Digest = null,
    frame: ?Frame = null,
    resources: geometry.Resources = .{},
    fixture: bool = false,
    diagnostic: []const u8 = "",
    history: ?*const desktop.practice_history.Query = null,
    history_cohort: desktop.practice_results.Cohort = .{},
    history_saving: bool = false,
    history_failure: ?anyerror = null,
    history_path: []const u8 = "",
    history_pending: usize = 0,
    event_times: []const desktop.practice_timing.EventTime = &.{},
};

pub const View = struct {
    scroll: presentation.Scroll = .{},
    show_keyboard: bool = true,
    drawn_len: usize = 0,
    drawn_keyboard: bool = false,
    drawn_panel: bool = false,
    rundown: rundown.View = .{},
    challenge_open: bool = false,
    challenge_enabled: bool = false,
    challenge_seed: u64 = 1,
    was_focused: ?bool = null,
    data_open: bool = false,
    progress_open: bool = false,
    progress: progress_ui.View = .{},
    diagnostics_open: bool = false,
    diagnostics: diagnostics_ui.View = .{},
    curriculum_open: bool = false,
    curriculum: curriculum_ui.View = .{},
    help: help.State = .{},
    help_open: bool = false,
    help_config: control.Config = .{},
    review_open: bool = false,
    review: help_ui.Review = .{},
    data_path: [4096]u8 = @splat(0),
    transfer: enum { none, export_database, import_database } = .none,
};

pub const DrawResult = struct { input_effect: control.Effect = .{}, action: ?control.Action = null };

fn running(owner: *const control.Controller) bool {
    return owner.active and owner.session.state != .complete;
}

fn keyboardPanel(bounds: dvui.Rect, theme: ui.Theme, tag: []const u8) *dvui.BoxWidget {
    return dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .corners = .all(12),
        .padding = .{},
        .tag = tag,
    });
}

/// Free typing observes only the verified live presenter. Ordinary native text
/// remains independent and never becomes synthetic matrix input here.
pub fn drawFreeCompanion(
    frame: desktop.live_keyboard.Frame,
    physical: []const model.physical_layout.Key,
    theme: ui.Theme,
    bounds: dvui.Rect,
    resources: geometry.Resources,
) !void {
    const panel = keyboardPanel(bounds, theme, "free.keyboard");
    defer panel.deinit();
    const title: dvui.Rect = .{ .x = 8, .y = 0, .w = bounds.w - 16, .h = 28 };
    const notice: dvui.Rect = .{ .x = 8, .y = 38, .w = bounds.w - 16, .h = 48 };
    const labels = frame.labels orelse {
        presentation.caption("Companion · no verified keyboard layout", title, 18, theme.text, "free.keyboard.source");
        const waiting = "Waiting for matching keyboard telemetry. Native typing remains available.";
        presentation.caption(waiting, notice, 16, theme.muted, "free.keyboard.unavailable");
        return;
    };
    const source = try std.fmt.allocPrint(dvui.currentWindow().arena(), "Live companion · {s} · {s} · layer {d}", .{
        std.mem.sliceTo(&frame.profile, 0),
        if (frame.stale) "stale / reconnecting" else "verified keyboard",
        frame.layer,
    });
    presentation.caption(source, title, 18, theme.text, "free.keyboard.source");
    if (physical.len == 0) {
        presentation.caption("Keyboard view unavailable", notice, 16, theme.muted, "free.keyboard.unavailable");
        return;
    }
    const output = try dvui.currentWindow().arena().alloc(desktop.physical_view.DrawKey, physical.len);
    const area: desktop.physical_view.Rect = .{ .x = 18, .y = 34, .w = @max(0, bounds.w - 36), .h = @max(0, bounds.h - 44) };
    const plan = try desktop.physical_view.plan(output, physical, labels, frame.layer, frame.modifiers, area, .{
        .pressed = frame.pressed,
        .active_layers = frame.active,
        .stale = frame.stale,
    });
    try geometry.draw(frame.layer, plan, resources);
}

/// Native timestamps for an event, when the platform layer recorded one.
fn nativeEventTime(times: []const desktop.practice_timing.EventTime, number: u16) ?u64 {
    for (times) |time| if (time.number == number) return time.now_us;
    return null;
}

fn insertText(owner: *control.Controller, effect: *control.Effect, text: []const u8, at: u64, paste: bool) !void {
    const inserted = try owner.insertOs(true, text, at, paste);
    effect.reset_text = inserted.reset_text or effect.reset_text;
}

fn consumeInput(owner: *control.Controller, data: *dvui.WidgetData, input: Input) !control.Effect {
    var effect: control.Effect = .{};
    if (!input.owns_input or !input.window_focused) return effect;
    if (!owner.acceptingOsText(true) or owner.session.state == .complete) return effect;
    dvui.wantTextInput(data.borderRectScale().r.toNatural());
    for (dvui.events()) |*event| {
        if (event.handled) continue;
        const native = nativeEventTime(input.event_times, event.num);
        const at = native orelse input.now_us;
        if (owner.session.recorder) |recorder| recorder.clock = if (native != null) .native_event else .frame;
        switch (event.evt) {
            .text => |text| {
                if (text.action == .value and !text.action.value.selected) {
                    try insertText(owner, &effect, text.action.value.txt, at, false);
                }
                event.handle(@src(), data);
            },
            .key => |key| {
                if (key.action != .up) {
                    try handleKey(owner, &effect, key, at);
                    owner.session.input_repeat = key.action == .repeat;
                }
                event.handle(@src(), data);
            },
            else => {},
        }
    }
    return effect;
}

fn handleKey(owner: *control.Controller, effect: *control.Effect, key: dvui.Event.Key, at: u64) !void {
    if (key.matchBind("paste")) return insertText(owner, effect, dvui.clipboardText(), at, true);
    if (key.mod.control() or key.mod.command()) return;
    switch (key.code) {
        .backspace => owner.session.backspaceAt(at),
        .tab => try insertText(owner, effect, "    ", at, false),
        .enter => try insertText(owner, effect, "\n", at, false),
        .escape => effect.reset_text = owner.pause(at).reset_text or effect.reset_text,
        else => {},
    }
}

/// Draws the keyboard guide. Draft guides show the layer and modifiers that
/// produce the next character instead of the reported live state.
fn keyboard(
    owner: *const control.Controller,
    frame: Frame,
    theme: ui.Theme,
    bounds: dvui.Rect,
    focus: usize,
    resources: geometry.Resources,
    guided: bool,
) !void {
    const panel = keyboardPanel(bounds, theme, "practice.keyboard");
    defer panel.deinit();
    if (frame.geometry.len == 0) {
        const source: dvui.Rect = .{ .x = 8, .y = bounds.h - 22, .w = bounds.w - 16, .h = 20 };
        presentation.label("Keyboard view unavailable", source, 11, theme.muted, null);
        return;
    }
    const labels = frame.labels;
    const practice_labels = labels.practiceLabels();
    var layer = @min(frame.layer, labels.layer_count - 1);
    var active = frame.active_layers;
    var mods = frame.modifiers;
    const next = if (guided and running(owner) and focus < owner.session.reference_len) blk: {
        const cp = owner.session.reference[focus];
        break :blk desktop.practice_curriculum.hintFor(practice_labels, owner.config.curriculum, cp) orelse
            try desktop.practice.hint(practice_labels, layer, mods.toByte(), cp, active);
    } else null;
    const arena = dvui.currentWindow().arena();
    const tap = try arena.alloc(bool, labels.key_count);
    const hold = try arena.alloc(bool, labels.key_count);
    try desktop.practice.guidance(practice_labels, frame.metadata, layer, mods.toByte(), next, .{ .tap = tap, .hold = hold });
    const hold_source_layer = layer;
    if (guided and frame.source == .draft) if (next) |hint| {
        layer = hint.layer;
        mods = @bitCast(hint.modifiers);
        active = 1 | (@as(u16, 1) << @intCast(layer));
    };
    try drawKeyboardLegend(owner, frame, theme, bounds, layer, guided);
    const neutral_pressed = try arena.alloc(bool, labels.key_count);
    @memset(neutral_pressed, false);
    const output = try arena.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const area: desktop.physical_view.Rect = .{ .x = 18, .y = 0, .w = @max(0, bounds.w - 36), .h = @max(0, bounds.h - 34) };
    const plan = try desktop.physical_view.plan(output, frame.geometry, labels, layer, mods, area, .{
        .pressed = if (guided) frame.pressed else neutral_pressed,
        .targets = tap,
        .holds = hold,
        .hold_source_layer = hold_source_layer,
        .active_layers = active,
        .stale = frame.stale,
    });
    try geometry.draw(layer, plan, resources);
}

/// The source line and hold/tap swatches along the bottom of the keyboard guide.
fn drawKeyboardLegend(
    owner: *const control.Controller,
    frame: Frame,
    theme: ui.Theme,
    bounds: dvui.Rect,
    layer: usize,
    guided: bool,
) !void {
    const title = switch (frame.source) {
        .live => if (frame.stale) "Live companion · stale / reconnecting" else "Live companion",
        .simulated => "Draft simulation",
        .draft => if (guided) "Draft guide" else "Draft reference",
    };
    const source = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} · {s} · layer {d}{s}", .{
        title,
        frame.profile,
        layer,
        if (owner.cohort.verified) "" else " · unverified",
    });
    dvui.labelNoFmt(@src(), source, .{ .align_x = 0 }, .{
        .rect = .{ .x = 8, .y = bounds.h - 22, .w = @max(0, bounds.w - 200), .h = 20 },
        .font = dvui.Font.theme(.body).withSize(11),
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .tag = "practice.keyboard.source",
    });
    for ([_][]const u8{ "Hold", "Tap" }, [_]u24{ 0x50D2FF, 0xFFC953 }, 0..) |label, hex, index| {
        const x = bounds.w - 182 + @as(f32, @floatFromInt(index)) * 92;
        const swatch = dvui.box(@src(), .{}, .{
            .rect = .{ .x = x, .y = bounds.h - 19, .w = 10, .h = 10 },
            .background = true,
            .color_fill = .{ .color = ui.color(hex) },
            .padding = .{},
            .id_extra = index,
        });
        swatch.deinit();
        dvui.labelNoFmt(@src(), label, .{}, .{
            .rect = .{ .x = x + 16, .y = bounds.h - 24, .w = 65, .h = 22 },
            .font = dvui.Font.theme(.body).withSize(13),
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .id_extra = index,
        });
    }
}

pub fn draw(owner: *control.Controller, view: *View, theme: ui.Theme, bounds: dvui.Rect, input: Input) !DrawResult {
    view.drawn_keyboard = false;
    view.drawn_panel = false;
    const window = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .tag = "practice.inline",
    });
    defer window.deinit();
    const size: dvui.Rect = .{ .w = bounds.w, .h = window.data().rect.h };
    if (size.h < 300 or size.w < 300) {
        if (input.fixture) std.log.err("Practice bounds height={d} width={d} requested={d}", .{ size.h, size.w, bounds.h });
        return .{};
    }
    view.drawn_panel = true;
    if (owner.session.recorder) |recorder| recorder.clock = .frame;
    const focus_effect = trackWindowFocus(owner, view, input);
    if (try drawAuxiliary(owner, view, theme, size, input, focus_effect)) |result| return result;

    // Exercise input precedes controls so Space cannot toggle a focused checkbox.
    var input_effect = try consumeInput(owner, window.data(), input);
    if (focus_effect.runner != .none or focus_effect.reset_text) input_effect = focus_effect;
    var pending: ?control.Intent = null;
    const controls_height: f32 = if (view.challenge_open and owner.config.mode == .english) 126 else 84;
    try drawControls(owner, view, size.w, input, &pending);
    view.show_keyboard = owner.config.assistance != .hidden or (view.help.requested and !view.help.paused);
    if (view.rundown.history_open and view.rundown.reviewed == null and owner.completed == null and !owner.active) {
        if (input.history) |saved| if (saved.page_count > 0 and std.meta.eql(input.history_cohort, owner.configCohort())) {
            view.rundown.reviewed = saved.page[0];
        };
    }
    if (view.rundown.reviewed != null or owner.completed != null) {
        try drawResult(owner, view, theme, size, controls_height, input, &pending);
    } else {
        try drawExercise(owner, view, theme, size, controls_height, input, window.data().id, &pending);
    }
    return .{ .input_effect = input_effect, .action = if (pending) |intent| owner.action(intent) else null };
}

/// Pauses on focus loss and records focus transitions during a run.
fn trackWindowFocus(owner: *control.Controller, view: *View, input: Input) control.Effect {
    var effect: control.Effect = .{};
    if (running(owner)) {
        if (view.was_focused) |previous| if (previous != input.window_focused) {
            if (!input.window_focused) effect = owner.pause(input.now_us);
            if (owner.session.recorder) |recorder| {
                const session = &owner.session;
                const kind: desktop.practice_timing.Kind = if (input.window_focused) .focus_gained else .focus_lost;
                recorder.record(kind, input.now_us, session.duration(input.now_us), session.len, null, .ordinary);
            }
        };
    }
    view.was_focused = input.window_focused;
    return effect;
}

/// Draws an open auxiliary page in place of the exercise. Returns null when no
/// auxiliary page is open and the exercise should be drawn.
fn drawAuxiliary(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    size: dvui.Rect,
    input: Input,
    focus_effect: control.Effect,
) !?DrawResult {
    const auxiliary = view.data_open or view.progress_open or view.diagnostics_open or view.curriculum_open or
        view.help_open or view.review_open;
    const paused = !owner.active or owner.session.state == .paused or owner.session.state == .complete;
    view.help.tick(
        owner.generation,
        desktop.practice_view.focus(&owner.session),
        input.now_us,
        paused or auxiliary or !input.window_focused,
    );
    if (auxiliary and running(owner)) if (owner.session.recorder) |recorder| {
        recorder.setCue(false, owner.session.len, input.now_us, owner.session.duration(input.now_us));
    };
    const done: DrawResult = .{ .input_effect = focus_effect };
    if (view.data_open) {
        try dataPanel(view, theme, size, input);
        return done;
    }
    if (view.progress_open) {
        if (try drawProgress(owner, view, theme, size, input)) return done;
    }
    if (view.rundown.diagnostics) {
        view.diagnostics_open = true;
        view.diagnostics = .{};
        view.rundown.diagnostics = false;
    }
    if (view.diagnostics_open) return try drawDiagnostics(owner, view, theme, size, input, focus_effect);
    if (view.curriculum_open) {
        const action = try curriculum_ui.draw(&view.curriculum, owner, input.history, input.history_cohort, theme, size);
        switch (action) {
            .none => {},
            .back => view.curriculum_open = false,
            .start => |config| {
                view.curriculum_open = false;
                view.rundown.reviewed = null;
                return .{ .input_effect = focus_effect, .action = owner.action(.{ .drill = config }) };
            },
            .free => |config| {
                view.curriculum_open = false;
                return .{ .input_effect = focus_effect, .action = owner.action(.{ .choose = config }) };
            },
        }
        return done;
    }
    if (view.help_open) {
        if (try help_ui.settings(&view.help_config, theme, size)) {
            view.help_open = false;
            return .{ .input_effect = focus_effect, .action = owner.action(.{ .choose = view.help_config }) };
        }
        return done;
    }
    if (view.review_open) return try drawReview(owner, view, theme, size, input, focus_effect);
    return null;
}

/// Hands a requested saved run over to the rundown once history has loaded it.
/// Returns whether the progress page was drawn.
fn drawProgress(owner: *control.Controller, view: *View, theme: ui.Theme, size: dvui.Rect, input: Input) !bool {
    if (view.progress.inspect) |id| if (input.history) |history| if (history.requested_record) |record| {
        if (std.mem.eql(u8, &id, &record.id)) {
            view.rundown.reviewed = record;
            view.rundown.selected = view.progress.selected;
            if (view.progress.selected) |cp| for (record.stats[0..record.stat_count]) |stat| {
                if (stat.cp == cp) rundown.select(&view.rundown, stat);
            };
            if (view.progress.selected != null and view.progress.matrix == 2) {
                view.rundown.diagnostics = true;
                view.rundown.refresh = true;
            }
            view.progress.inspect = null;
            view.progress_open = false;
            return false;
        }
    };
    if (view.progress.inspect) |id| if (input.history) |history| if (history.requested_id) |requested| {
        if (std.mem.eql(u8, &id, &requested) and !history.contains_requested and !input.history_saving) {
            view.progress.inspect = null;
            view.progress.message = "This saved run is no longer available.";
        }
    };
    const cohort = if (view.rundown.reviewed) |record|
        record.cohort
    else if (owner.completed) |record|
        record.cohort
    else
        owner.configCohort();
    const history = if (std.meta.eql(cohort, input.history_cohort)) input.history else null;
    if (try progress_ui.draw(&view.progress, history, cohort, input.history_failure, input.history_saving, theme, size)) {
        view.progress_open = false;
    }
    if (view.progress.retry) {
        view.rundown.retry = true;
        view.progress.retry = false;
    }
    if (view.progress.inspect != null) view.rundown.refresh = true;
    return true;
}

fn drawDiagnostics(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    size: dvui.Rect,
    input: Input,
    focus_effect: control.Effect,
) !DrawResult {
    const record = if (view.rundown.reviewed) |*reviewed| reviewed else if (owner.completed) |*completed| completed else {
        view.diagnostics_open = false;
        return .{};
    };
    const matching = if (input.history) |history|
        (if (history.requested_record) |saved| std.mem.eql(u8, &saved.id, &record.id) else false)
    else
        false;
    const history = if (matching) input.history else null;
    const action = try diagnostics_ui.draw(
        &view.diagnostics,
        view.rundown.selected,
        owner,
        record,
        history,
        input.history_saving,
        input.history_failure,
        theme,
        size,
    );
    if (view.diagnostics.retry) {
        view.rundown.retry = true;
        view.diagnostics.retry = false;
    }
    switch (action) {
        .none => {},
        .back => view.diagnostics_open = false,
        .drill => |config| {
            view.diagnostics_open = false;
            view.rundown.reviewed = null;
            return .{ .input_effect = focus_effect, .action = owner.action(.{ .drill = config }) };
        },
    }
    return .{ .input_effect = focus_effect };
}

fn drawReview(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    size: dvui.Rect,
    input: Input,
    focus_effect: control.Effect,
) !DrawResult {
    const context = owner.configCohort();
    const cohort = input.history_cohort;
    const matches = context.verified == cohort.verified and context.source == cohort.source and
        context.family == cohort.family and std.mem.eql(u8, &context.behavior, &cohort.behavior) and
        std.mem.eql(u8, &context.mapping, &cohort.mapping);
    const history = if (matches) input.history else null;
    const action = try help_ui.reviews(&view.review, owner, history, input.history_failure, input.history_saving or !matches, theme, size);
    if (view.review.retry) {
        view.rundown.retry = true;
        view.review.retry = false;
    }
    switch (action) {
        .none => {},
        .back => view.review_open = false,
        .start => |config| {
            view.review_open = false;
            view.rundown.reviewed = null;
            return .{ .input_effect = focus_effect, .action = owner.action(.{ .drill = config }) };
        },
    }
    return .{ .input_effect = focus_effect };
}

/// Dropdown selections of the exercise controls, as indices into their option lists.
const Choices = struct {
    mode: usize,
    level: usize,
    preset: usize,
    source: usize,
    assistance: usize,

    fn init(config: control.Config) Choices {
        return .{
            .mode = @backingInt(config.mode),
            .level = config.level,
            .preset = @backingInt(config.preset),
            .source = @backingInt(config.source),
            .assistance = help.choice(config),
        };
    }
};

fn drawControls(owner: *control.Controller, view: *View, width: f32, input: Input, pending: *?control.Intent) !void {
    var choices: Choices = .init(owner.config);
    var changed = drawExerciseRow(owner, &choices, width);
    changed = try drawToolsRow(owner, view, &choices, width, input, pending) or changed;
    if (view.challenge_open and choices.mode == 0) {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = 84, .w = width, .h = 38 } });
        defer row.deinit();
        changed = dvui.checkbox(@src(), &view.challenge_enabled, "Challenge v1", .{}) or changed;
        changed = dvui.textEntryNumber(@src(), u64, .{ .value = &view.challenge_seed }, .{
            .min_size_content = .{ .w = 200 },
            .tag = "practice.challenge.seed",
        }).changed or changed;
        dvui.labelNoFmt(@src(), "Match seed, preset, length and versions", .{}, .{});
    }
    if (!changed) return;
    var config = owner.config;
    config.mode = @fromBackingInt(@intCast(choices.mode));
    if (config.curriculum.version != 0 and config.mode == .zig) config.curriculum.stage = .real_text;
    config.level = choices.level;
    config.source = @fromBackingInt(@intCast(choices.source));
    config.preset = @fromBackingInt(@intCast(choices.preset));
    help.apply(&config, choices.assistance);
    const challenge = choices.mode == 0 and view.challenge_enabled and config.curriculum.version == 0;
    config.challenge = if (challenge) view.challenge_seed else null;
    config.target_count = 0;
    pending.* = .{ .choose = config };
}

/// Mode, preset and length selectors. Returns whether any selection changed.
fn drawExerciseRow(owner: *const control.Controller, choices: *Choices, width: f32) bool {
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .w = width, .h = 38 } });
    defer row.deinit();
    const lesson = owner.config.curriculum;
    var changed = dvui.dropdown(@src(), &.{ "English", "Zig" }, .{ .choice = &choices.mode }, .{}, .{ .min_size_content = .{ .w = 110 } });
    if (choices.mode == 0) {
        if (lesson.version != 0 and lesson.stage != .real_text) {
            dvui.labelNoFmt(@src(), desktop.practice_curriculum.names[@backingInt(lesson.stage)], .{}, .{});
        } else {
            const presets: []const []const u8 = &.{ "Words", "Mixed case", "Punctuation" };
            changed = dvui.dropdown(@src(), presets, .{ .choice = &choices.preset }, .{}, .{ .tag = "practice.preset" }) or changed;
        }
    }
    const lengths: []const []const u8 = if (choices.mode != 0)
        &desktop.practice.lesson_names
    else if (lesson.version != 0)
        &.{ "Short", "Normal", "Long" }
    else
        &.{ "Short · 2 units", "Normal · 5 units", "Long · 10 units" };
    changed = dvui.dropdown(@src(), lengths, .{ .choice = &choices.level }, .{}, .{ .tag = "practice.length" }) or changed;
    return changed;
}

const Tool = enum(usize) { none, data, hints, challenge, history };

/// Input source, assistance, the tools menu and page buttons. Returns whether a
/// setting changed; opening a page during a run requests a pause.
fn drawToolsRow(
    owner: *const control.Controller,
    view: *View,
    choices: *Choices,
    width: f32,
    input: Input,
    pending: *?control.Intent,
) !bool {
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = 42, .w = width, .h = 38 } });
    defer row.deinit();
    const sources: []const []const u8 = &.{ "OS keyboard text", "Unflashed draft" };
    var changed = dvui.dropdown(@src(), sources, .{ .choice = &choices.source }, .{}, .{ .tag = "practice.input.source" });
    changed = dvui.dropdown(@src(), &help.choices, .{ .choice = &choices.assistance }, .{}, .{ .tag = "practice.assistance" }) or changed;
    var tool: usize = 0;
    const tools: []const []const u8 = &.{ "More…", "Practice data", "Hint settings", "Challenge seed", "Saved history" };
    _ = dvui.dropdown(@src(), tools, .{ .choice = &tool }, .{}, .{ .tag = "practice.tools", .min_size_content = .{ .w = 90 } });
    try openTool(owner, view, @fromBackingInt(@intCast(tool)), choices.mode, input, pending);
    if (dvui.button(@src(), "Progress", .{}, .{ .tag = "practice.progress.open" })) {
        view.progress_open = true;
        view.rundown.refresh = true;
        if (running(owner)) pending.* = .pause;
    }
    if (dvui.button(@src(), "Lessons", .{}, .{ .tag = "practice.curriculum.open" })) {
        openCurriculum(owner, view);
        if (running(owner)) pending.* = .pause;
    }
    if (dvui.button(@src(), "Review", .{}, .{ .tag = "practice.review.open" })) {
        view.review_open = true;
        view.rundown.refresh = true;
        if (running(owner)) pending.* = .pause;
    }
    return changed;
}

fn openTool(owner: *const control.Controller, view: *View, tool: Tool, mode: usize, input: Input, pending: *?control.Intent) !void {
    switch (tool) {
        .none => {},
        .history => if (!running(owner)) {
            view.rundown.refresh = true;
            view.rundown.history_open = true;
            if (owner.completed == null) if (input.history) |saved| if (saved.page_count > 0) {
                view.rundown.reviewed = saved.page[0];
            };
        },
        .challenge => if (mode == 0 and owner.config.curriculum.version == 0) {
            view.challenge_open = !view.challenge_open;
            if (view.challenge_open and running(owner)) pending.* = .pause;
        },
        .data => {
            view.data_open = true;
            view.rundown.refresh = true;
            if (running(owner)) pending.* = .pause;
            if (view.data_path[0] == 0 and input.history_path.len != 0) {
                const default_path = try std.fs.path.join(
                    dvui.currentWindow().arena(),
                    &.{ input.history_path, "practice-export.sqlite3" },
                );
                if (default_path.len < view.data_path.len) @memcpy(view.data_path[0..default_path.len], default_path);
            }
        },
        .hints => {
            view.help_open = true;
            view.help_config = owner.config;
            if (running(owner)) pending.* = .pause;
        },
    }
}

/// Opens the lesson picker with the current settings as a guided-curriculum draft.
fn openCurriculum(owner: *const control.Controller, view: *View) void {
    view.curriculum_open = true;
    view.curriculum.config = owner.config;
    view.curriculum.config.challenge = null;
    view.curriculum.config.target_count = 0;
    if (view.curriculum.config.curriculum.version == 0) {
        view.curriculum.config.curriculum.version = 1;
        view.curriculum.config.mode = .english;
        view.curriculum.config.preset = .words;
    }
    view.challenge_open = false;
    view.challenge_enabled = false;
    view.rundown.refresh = true;
}

fn drawResult(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    size: dvui.Rect,
    controls_height: f32,
    input: Input,
    pending: *?control.Intent,
) !void {
    const record = if (view.rundown.reviewed) |*reviewed| reviewed else &owner.completed.?;
    const bounds: dvui.Rect = .{ .y = controls_height + 6, .w = size.w, .h = size.h - controls_height - 6 };
    const matches = std.meta.eql(record.cohort, input.history_cohort);
    const action = try rundown.draw(
        owner,
        &view.rundown,
        record,
        input.history,
        matches,
        input.frame,
        theme,
        bounds,
        input.history_saving,
        input.history_failure,
    );
    switch (action) {
        .none => {},
        .new_exercise => {
            view.rundown.reviewed = null;
            pending.* = .new_exercise;
        },
        .drill => |config| {
            view.rundown.reviewed = null;
            pending.* = .{ .drill = config };
        },
    }
}

fn drawExercise(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    size: dvui.Rect,
    controls_height: f32,
    input: Input,
    window_id: dvui.Id,
    pending: *?control.Intent,
) !void {
    const arena = dvui.currentWindow().arena();
    const session = &owner.session;
    const width = size.w;
    const height = size.h;
    const focus_text = try focusDescription(owner);
    if (focus_text.len > 0) presentation.caption(focus_text, .{ .y = height - 24, .w = width, .h = 22 }, 14, theme.muted, "practice.focus");
    const metrics = try std.fmt.allocPrint(arena, "{d:.0} WPM     {d:.1}% accuracy     {d:.1}s     {s}", .{
        session.wpm(input.now_us),
        session.accuracy(),
        @as(f64, @floatFromInt(session.duration(input.now_us))) / 1_000_000,
        if (!owner.active) "Ready" else @tagName(session.state),
    });
    presentation.caption(metrics, .{ .x = 0, .y = controls_height + 2, .w = width, .h = 26 }, 18, theme.muted, "practice.metrics");
    const focus = desktop.practice_view.focus(session);
    const show_hint = updateHint(owner, view, focus, input, window_id);

    const work_y = controls_height + 34;
    const work_height = @max(0, height - 112 - work_y - 24);
    const hero_height = @min(125, work_height * 0.23);
    const context_height = if (view.show_keyboard) work_height * 0.23 else work_height - hero_height - 8;
    const footer_y = work_y + 16 + hero_height + context_height;
    presentation.focusWord(session, owner.active, theme, .{ .x = 0, .y = work_y, .w = width, .h = hero_height }, focus);
    const context: dvui.Rect = .{ .x = 0, .y = work_y + 8 + hero_height, .w = width, .h = context_height };
    presentation.context(session, owner.active, owner.config.mode, &view.scroll, input.fixture, theme, context, focus, input.now_us);
    if (view.show_keyboard) {
        const keyboard_bounds: dvui.Rect = .{ .x = 0, .y = footer_y + 124, .w = width, .h = @max(0, height - footer_y - 124) };
        try drawGuide(owner, view, theme, keyboard_bounds, focus, show_hint, input);
    } else if (running(owner)) if (session.recorder) |recorder| {
        recorder.clock = .frame;
        recorder.setCue(false, focus, input.now_us, session.duration(input.now_us));
    };
    view.drawn_len = session.len;
    drawRunButtons(owner, view, theme, footer_y, focus, input, pending);
    drawProgressBar(session, theme, footer_y, width);
    try drawFooter(owner, theme, footer_y, width, input);
}

fn focusDescription(owner: *const control.Controller) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(dvui.currentWindow().arena());
    const captured = &owner.captured_config;
    if (captured.target_count > 0) {
        try text.writer.writeAll("Drill focus: ");
        for (captured.targets[0..captured.target_count]) |cp| {
            var bytes: [4]u8 = undefined;
            try text.writer.print("«{s}» ", .{desktop.practice_view.glyph(cp, true, &bytes)});
        }
    } else if (owner.config.challenge != null) {
        try text.writer.print("Challenge v1 · seed {d}", .{owner.exercise_seed});
    } else if (owner.config.preset == .mixed_case) {
        try text.writer.writeAll(if (owner.normal_coverage != null)
            "Capital hand coverage follows proven physical routes"
        else
            "Text coverage only · capital hand mapping unavailable");
    }
    return text.written();
}

/// Advances the hint timer and returns whether the keyboard should highlight the
/// next character. Delayed hints schedule a redraw for when they become due.
fn updateHint(owner: *const control.Controller, view: *View, focus: usize, input: Input, window_id: dvui.Id) bool {
    const session = &owner.session;
    const paused = !owner.active or session.state == .paused or session.state == .complete;
    view.help.tick(owner.generation, focus, input.now_us, paused or !input.window_focused);
    const history_matches = input.history != null and std.meta.eql(owner.captured_cohort, input.history_cohort);
    const baseline = if (focus < session.reference_len and history_matches)
        help.baseline(input.history.?.progress, session.reference[focus])
    else
        null;
    const config = owner.config;
    const show_hint = if (config.assistance == .guided)
        view.help.visible(config.hints, baseline)
    else
        view.help.requested and !view.help.paused;
    if (config.assistance == .guided and config.hints.policy == .delayed and !view.help.paused and !show_hint) {
        dvui.timer(window_id, @intCast(config.hints.delay(baseline) -| view.help.waited_us));
    }
    view.show_keyboard = config.assistance != .hidden or (view.help.requested and !view.help.paused);
    return show_hint;
}

/// Draws the keyboard guide and records whether a proven cue was visible.
fn drawGuide(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    bounds: dvui.Rect,
    focus: usize,
    show_hint: bool,
    input: Input,
) !void {
    const session = &owner.session;
    view.drawn_keyboard = input.frame != null;
    if (input.frame) |frame| {
        try keyboard(owner, frame, theme, bounds, focus, input.resources, show_hint);
    } else {
        const source: dvui.Rect = .{ .x = 8, .y = bounds.y + bounds.h - 22, .w = bounds.w - 16, .h = 20 };
        presentation.label("Companion · no verified keyboard layout", source, 11, theme.muted, "practice.keyboard.source");
    }
    if (!running(owner)) return;
    const recorder = session.recorder orelse return;
    recorder.clock = .frame;
    const frame = input.frame;
    const available = frame != null and frame.?.geometry.len > 0 and bounds.h >= 80;
    const proven = available and focus < session.reference_len and try hasRoute(owner, frame.?, session.reference[focus]);
    recorder.setCue(show_hint and proven, focus, input.now_us, session.duration(input.now_us));
    if (available and view.help.requested and owner.config.assistance != .guided) recorder.help_revealed = true;
}

fn hasRoute(owner: *const control.Controller, frame: Frame, cp: u21) !bool {
    const labels = frame.labels.practiceLabels();
    if (desktop.practice_curriculum.hintFor(labels, owner.config.curriculum, cp) != null) return true;
    return try desktop.practice.hint(labels, frame.layer, frame.modifiers.toByte(), cp, frame.active_layers) != null;
}

fn drawRunButtons(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    footer_y: f32,
    focus: usize,
    input: Input,
    pending: *?control.Intent,
) void {
    const session = &owner.session;
    const editable = session.state != .complete;
    const start: dvui.Rect = .{ .x = 0, .y = footer_y, .w = 120, .h = 40 };
    if (ui.buttonEnabled(theme, if (owner.active) "Fresh run" else "Start", "practice.start", start, editable) and pending.* == null) {
        pending.* = .{ .start = true };
    }
    const new: dvui.Rect = .{ .x = 130, .y = footer_y, .w = 150, .h = 40 };
    if (ui.buttonEnabled(theme, "New exercise", "practice.new", new, editable) and pending.* == null) pending.* = .new_exercise;
    const paused = session.state == .paused;
    const pause: dvui.Rect = .{ .x = 290, .y = footer_y, .w = 120, .h = 40 };
    if (ui.button(theme, if (paused) "Resume" else "Pause", "practice.pause", pause) and owner.active and pending.* == null) {
        pending.* = if (paused) .resume_run else .pause;
    }
    if (ui.button(theme, "Stop", "practice.stop", .{ .x = 420, .y = footer_y, .w = 100, .h = 40 }) and pending.* == null) pending.* = .stop;
    const hint: dvui.Rect = .{ .x = 530, .y = footer_y, .w = 130, .h = 40 };
    const hint_enabled = owner.active and !view.help.paused and focus < session.reference_len;
    if (ui.buttonEnabled(theme, "Show hint", "practice.hint.request", hint, hint_enabled)) {
        view.help.requested = true;
        dvui.refresh(null, @src(), null);
        if (session.recorder) |recorder| {
            recorder.clock = .frame;
            recorder.record(.hint_requested, input.now_us, session.duration(input.now_us), focus, null, .ordinary);
        }
    }
}

fn drawProgressBar(session: *const desktop.practice.Session, theme: ui.Theme, footer_y: f32, width: f32) void {
    const fraction = if (session.reference_len == 0)
        @as(f32, 0)
    else
        @as(f32, @floatFromInt(session.matched())) / @as(f32, @floatFromInt(session.reference_len));
    const bar = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 0, .y = footer_y + 52, .w = width, .h = 5 },
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.control },
        .corners = .all(3),
    });
    defer bar.deinit();
    const fill = dvui.box(@src(), .{}, .{
        .rect = .{ .w = width * fraction, .h = 5 },
        .background = true,
        .color_fill = .{ .color = presentation.accent },
    });
    fill.deinit();
}

fn drawFooter(owner: *const control.Controller, theme: ui.Theme, footer_y: f32, width: f32, input: Input) !void {
    const arena = dvui.currentWindow().arena();
    const session = &owner.session;
    const code_speed = if (owner.config.mode == .zig)
        try std.fmt.allocPrint(arena, " · {d:.0} CPM", .{session.wpm(input.now_us) * 5})
    else
        "";
    const history_matches = std.meta.eql(owner.captured_cohort, input.history_cohort) and input.history != null;
    const best: f64 = if (history_matches) input.history.?.all.best_wpm else 0;
    const summary = try std.fmt.allocPrint(arena, "{d}/{d} characters · {d} corrections · best {d:.0} WPM · {s}{s}", .{
        session.matched(),
        session.reference_len,
        session.corrected,
        best,
        if (session.scored) "scored" else "paste preview",
        code_speed,
    });
    presentation.caption(summary, .{ .x = 0, .y = footer_y + 63, .w = width, .h = 22 }, 14, theme.muted, null);
    presentation.caption(runnerStatus(owner, input), .{ .x = 0, .y = footer_y + 87, .w = width, .h = 22 }, 14, theme.muted, null);
}

fn runnerStatus(owner: *const control.Controller, input: Input) []const u8 {
    const diagnostic = if (owner.failure) |failure| switch (failure) {
        error.PracticeContextChanged => "Layout or input source changed · start a fresh exercise",
        error.DraftChangedRestartPractice => "Draft changed · restart the exercise",
        error.DraftPreparationFailed => "Draft preparation failed · retry with Resume",
        error.RunnerArtifactNotPrepared => "Build the current draft before starting practice",
        error.StaleBuild => "Build the current draft before starting practice",
        error.RunnerArtifactChanged => "The prepared draft runner changed · rebuild the draft",
        error.RunnerHostMismatch => "This draft runner was built for another system",
        error.HostMappingUnavailable => "Draft practice has no host key mapping for this board",
        else => input.diagnostic,
    } else input.diagnostic;
    if (owner.config.source != .draft or !owner.active) return diagnostic;
    return switch (owner.runner_state) {
        .preparing => "Preparing the current draft",
        .prepared => "Draft ready · press Resume",
        .stopping => "Stopping draft practice",
        .idle => "Build the current draft, then press Resume",
        .failed => if (diagnostic.len != 0) diagnostic else "Draft practice failed · build or retry",
        .stale => "Draft changed · restart the exercise",
        .running => diagnostic,
    };
}

pub fn apply(owner: *control.Controller, view: *View, rendered: control.Action, input: Input) !control.Effect {
    const effect = try owner.dispatch(rendered, input.prepared_snapshot, input.now_us);
    switch (rendered.intent) {
        .start, .new_exercise, .drill => {
            if (rendered.intent == .drill) view.challenge_enabled = false;
            view.rundown.reviewed = null;
            view.rundown.cleared = false;
            view.rundown.scope = 0;
            view.rundown.before = null;
            view.rundown.selected = null;
            view.rundown.message = "";
            view.scroll.at = null;
            view.drawn_len = 0;
        },
        else => {},
    }
    return effect;
}

fn dataPanel(view: *View, theme: ui.Theme, bounds: dvui.Rect, input: Input) !void {
    const wide = bounds.w >= 1100;
    const content_width = @max(640, bounds.w - 60);
    const left_width = if (wide) (content_width - 20) * 0.43 else content_width;
    const path_height = presentation.wrappedHeight(input.history_path, left_width - 48, 12);
    const left_height = @max(370, 294 + path_height);
    const page = presentation.Page.init(bounds, if (wide) left_height + 240 else left_height + 590, "practice.data.title", theme);
    defer page.deinit();
    const width = page.width;
    presentation.header("Practice data", "Saved locally. Take your practice history to another computer or worktree.", width, theme);
    if (presentation.backButton(theme, "Back to practice", "practice.data.back", width)) view.data_open = false;
    const left_w = if (wide) (width - 20) * 0.43 else width;
    try drawHistorySummary(input, left_w, left_height, theme);
    const right_x = if (wide) left_w + 20 else 0;
    const right_y: f32 = if (wide) 96 else left_height + 120;
    const right_w = if (wide) width - right_x else width;
    drawTransfer(view, input, .{ .x = right_x, .y = right_y, .w = right_w, .h = 370 }, theme);
    const status_y: f32 = if (wide) left_height + 128 else right_y + 398;
    _ = presentation.flowText(transferMessage(input), 0, status_y, width - 235, 14, theme.muted);
    const retry: dvui.Rect = .{ .x = width - 220, .y = status_y, .w = 220, .h = 38 };
    if (input.history_failure != null and ui.button(theme, "Retry pending saves", "practice.data.retry", retry)) view.rundown.retry = true;
}

fn drawHistorySummary(input: Input, left_w: f32, left_height: f32, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    const w = left_w - 48;
    presentation.surface(.{ .y = 96, .w = left_w, .h = left_height }, theme.panel);
    presentation.label("Local practice history", .{ .x = 24, .y = 114, .w = w, .h = 30 }, 20, theme.text, null);
    const runs = try std.fmt.allocPrint(arena, "{d} saved runs", .{if (input.history) |data| data.database_runs else 0});
    presentation.label(runs, .{ .x = 24, .y = 168, .w = w, .h = 40 }, 28, theme.text, "practice.data.counts");
    const events = try std.fmt.allocPrint(arena, "{d} timing events · {d} pending saves", .{
        if (input.history) |data| data.database_events else 0,
        input.history_pending,
    });
    presentation.label(events, .{ .x = 24, .y = 218, .w = w, .h = 24 }, 14, theme.muted, null);
    const note = "Only exercise input is recorded. Older runs keep their counts; timing remains unavailable.";
    _ = presentation.flowText(note, 24, 258, w, 14, theme.muted);
    presentation.label("History folder", .{ .x = 24, .y = 334, .w = w, .h = 22 }, 13, theme.muted, null);
    _ = presentation.flowText(input.history_path, 24, 366, w, 12, theme.text);
}

fn drawTransfer(view: *View, input: Input, panel: dvui.Rect, theme: ui.Theme) void {
    const x = panel.x + 24;
    const y = panel.y;
    const w = panel.w - 48;
    presentation.surface(panel, theme.panel);
    presentation.label("Export or import", .{ .x = x, .y = y + 18, .w = w, .h = 30 }, 20, theme.text, null);
    const note = "Export creates a standalone database. Import merges matching runs and keeps the originals.";
    _ = presentation.flowText(note, x, y + 66, w, 15, theme.muted);
    presentation.label("Database file · absolute path", .{ .x = x, .y = y + 142, .w = w, .h = 24 }, 14, theme.text, null);
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.data_path } }, .{
        .rect = .{ .x = x, .y = y + 178, .w = w, .h = 42 },
        .tag = "practice.data.path",
    });
    entry.deinit();
    const available = !input.history_saving and input.history_pending == 0;
    const export_bounds: dvui.Rect = .{ .x = x, .y = y + 238, .w = 180, .h = 40 };
    if (ui.buttonEnabled(presentation.primary(theme), "Export database", "practice.data.export", export_bounds, available)) {
        view.transfer = .export_database;
    }
    const import_bounds: dvui.Rect = .{ .x = panel.x + 216, .y = y + 238, .w = 180, .h = 40 };
    if (ui.buttonEnabled(theme, "Import database", "practice.data.import", import_bounds, available)) {
        view.transfer = .import_database;
    }
    const hint = "Choose a new filename for export. Repeated imports do not duplicate matching runs.";
    _ = presentation.flowText(hint, x, y + 298, w, 13, theme.muted);
}

fn transferMessage(input: Input) []const u8 {
    if (input.history_failure) |err| return switch (err) {
        error.PathAlreadyExists => "That destination exists. Choose a new export filename.",
        error.PracticeRunCollision => "Conflicting run data. The import was rolled back.",
        error.UnsupportedPracticeDatabase => "This file is not a supported practice database.",
        error.PracticeDatabaseBusy => "Database busy. Wait for other writes and retry.",
        error.PracticeMigrationBackupFailed => "History upgrade paused: could not create or validate a backup. " ++
            "Check free space and permissions in typing-practice/backups, then retry.",
        error.UnsupportedPracticeHistory, error.UnsupportedPracticeTiming => "This history uses a newer data format. " ++
            "Open it with a compatible Zigmkay version; the stored data has been kept.",
        else => "Practice data could not be saved or read. Your in-memory results remain available.",
    };
    if (input.history_saving) return "Working on practice data…";
    const data = input.history orelse return "";
    if (data.exported) return "Database exported.";
    if (data.imported != null) return "Database imported. Matching runs were kept.";
    return "";
}
