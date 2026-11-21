//! Retained tutor controls over injected project/live views and explicit effects.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const model = @import("layout-model");
const geometry = @import("physical-ui");
const presentation = @import("practice_presentation.zig");
const control = desktop.practice_controller;
const generator = desktop.practice_generator;

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
    event_times: []const desktop.practice.EventTime = &.{},
};

pub const View = struct {
    scroll: presentation.Scroll = .{},
    drawn_len: usize = 0,
    drawn_keyboard: bool = false,
    drawn_panel: bool = false,
    was_focused: ?bool = null,
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
fn nativeEventTime(times: []const desktop.practice.EventTime, number: u16) ?u64 {
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
        const at = nativeEventTime(input.event_times, event.num) orelse input.now_us;
        switch (event.evt) {
            .text => |text| {
                if (text.action == .value and !text.action.value.selected) {
                    try insertText(owner, &effect, text.action.value.txt, at, false);
                }
                event.handle(@src(), data);
            },
            .key => |key| {
                if (key.action != .up) try handleKey(owner, &effect, key, at);
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
        .backspace => owner.session.backspace(),
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
    const next = if (guided and running(owner) and focus < owner.session.reference_len)
        try desktop.practice.hint(practice_labels, layer, mods.toByte(), owner.session.reference[focus], active)
    else
        null;
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
    try drawKeyboardLegend(frame, theme, bounds, layer, guided);
    const neutral_pressed = try arena.alloc(bool, labels.key_count);
    @memset(neutral_pressed, false);
    const output = try arena.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const area: desktop.physical_view.Rect = .{ .x = 18, .y = 0, .w = @max(0, bounds.w - 36), .h = @max(0, bounds.h - 34) };
    const plan = try desktop.physical_view.plan(output, frame.geometry, labels, layer, mods, area, .{
        // Presses stay visible while trying the keyboard, and during a run
        // only with guided assistance.
        .pressed = if (guided or !running(owner)) frame.pressed else neutral_pressed,
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
    const source = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} · {s} · layer {d}", .{
        title,
        frame.profile,
        layer,
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
    const focus_effect = trackWindowFocus(owner, view, input);

    // Exercise input precedes controls so Space cannot toggle a focused dropdown.
    var input_effect = try consumeInput(owner, window.data(), input);
    if (focus_effect.runner != .none or focus_effect.reset_text) input_effect = focus_effect;
    var pending: ?control.Intent = null;
    const controls_height = drawControls(owner, size.w, &pending);
    try drawExercise(owner, view, theme, size, controls_height, input, &pending);
    return .{ .input_effect = input_effect, .action = if (pending) |intent| owner.action(intent) else null };
}

/// Pauses a run when the window loses focus.
fn trackWindowFocus(owner: *control.Controller, view: *View, input: Input) control.Effect {
    var effect: control.Effect = .{};
    if (running(owner)) if (view.was_focused) |previous| {
        if (previous and !input.window_focused) effect = owner.pause(input.now_us);
    };
    view.was_focused = input.window_focused;
    return effect;
}

const english_lengths = [_][]const u8{ "1 sentence", "3 sentences", "5 sentences", "10 sentences" };
const sources = [_][]const u8{ "OS keyboard text", "Unflashed draft" };
const assistance = [_][]const u8{ "Highlight next key", "Keyboard only", "No keyboard" };

comptime {
    std.debug.assert(english_lengths.len == generator.sentence_counts.len);
}

/// The exercise settings, in one row or, in narrow windows, two. Returns the
/// height they take.
fn drawControls(owner: *const control.Controller, width: f32, pending: *?control.Intent) f32 {
    const config = owner.config;
    var mode: usize = @backingInt(config.mode);
    var level = config.level;
    var source: usize = @backingInt(config.source);
    var help: usize = @backingInt(config.assistance);
    const narrow = width < 760;
    var changed = false;
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .w = width, .h = 38 } });
        defer row.deinit();
        changed = dvui.dropdown(@src(), &.{ "English", "Zig" }, .{ .choice = &mode }, .{}, .{
            .min_size_content = .{ .w = 110 },
            .tag = "practice.mode",
        });
        const lengths: []const []const u8 = if (config.mode == .zig) &desktop.practice.lesson_names else &english_lengths;
        changed = dvui.dropdown(@src(), lengths, .{ .choice = &level }, .{}, .{ .tag = "practice.length" }) or changed;
        if (!narrow) changed = drawInputChoices(&source, &help) or changed;
    }
    if (narrow) {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = 42, .w = width, .h = 38 } });
        defer row.deinit();
        changed = drawInputChoices(&source, &help) or changed;
    }
    if (changed) {
        var next = config;
        next.mode = @fromBackingInt(@intCast(mode));
        // Each mode starts at its default length instead of reusing an index.
        next.level = if (next.mode == config.mode) level else if (next.mode == .english) 1 else 0;
        next.source = @fromBackingInt(@intCast(source));
        next.assistance = @fromBackingInt(@intCast(help));
        pending.* = .{ .choose = next };
    }
    return if (narrow) 84 else 42;
}

fn drawInputChoices(source: *usize, help: *usize) bool {
    var changed = dvui.dropdown(@src(), &sources, .{ .choice = source }, .{}, .{ .tag = "practice.input.source" });
    changed = dvui.dropdown(@src(), &assistance, .{ .choice = help }, .{}, .{ .tag = "practice.assistance" }) or changed;
    return changed;
}

fn drawExercise(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    size: dvui.Rect,
    controls_height: f32,
    input: Input,
    pending: *?control.Intent,
) !void {
    const arena = dvui.currentWindow().arena();
    const session = &owner.session;
    const width = size.w;
    const height = size.h;
    const metrics = try std.fmt.allocPrint(arena, "{d:.0} WPM     {d:.1}% accuracy     {d:.1}s     {s}", .{
        session.wpm(input.now_us),
        session.accuracy(),
        @as(f64, @floatFromInt(session.duration(input.now_us))) / 1_000_000,
        if (!owner.active) "Ready" else @tagName(session.state),
    });
    presentation.caption(metrics, .{ .x = 0, .y = controls_height + 2, .w = width, .h = 26 }, 18, theme.muted, "practice.metrics");
    const focus = desktop.practice_view.focus(session);
    const show_keyboard = owner.config.assistance != .hidden;

    const work_y = controls_height + 34;
    const work_height = @max(0, height - 112 - work_y);
    const hero_height = @min(125, work_height * 0.23);
    const context_height = if (show_keyboard) work_height * 0.23 else work_height - hero_height - 8;
    const footer_y = work_y + 16 + hero_height + context_height;
    presentation.focusWord(session, owner.active, theme, .{ .x = 0, .y = work_y, .w = width, .h = hero_height }, focus);
    const context: dvui.Rect = .{ .x = 0, .y = work_y + 8 + hero_height, .w = width, .h = context_height };
    presentation.context(session, owner.active, owner.config.mode, &view.scroll, input.fixture, theme, context, focus, input.now_us);
    if (show_keyboard) {
        const keyboard_bounds: dvui.Rect = .{ .x = 0, .y = footer_y + 124, .w = width, .h = @max(0, height - footer_y - 124) };
        try drawGuide(owner, view, theme, keyboard_bounds, focus, input);
    }
    view.drawn_len = session.len;
    drawRunButtons(owner, theme, footer_y, pending);
    drawProgressBar(session, theme, footer_y, width);
    try drawFooter(owner, theme, footer_y, width, input);
}

/// Draws the keyboard guide, highlighting the next key with guided assistance.
fn drawGuide(owner: *control.Controller, view: *View, theme: ui.Theme, bounds: dvui.Rect, focus: usize, input: Input) !void {
    view.drawn_keyboard = input.frame != null;
    if (input.frame) |frame| {
        try keyboard(owner, frame, theme, bounds, focus, input.resources, owner.config.assistance == .guided);
    } else {
        const source: dvui.Rect = .{ .x = 8, .y = bounds.y + bounds.h - 22, .w = bounds.w - 16, .h = 20 };
        presentation.label("Companion · no verified keyboard layout", source, 11, theme.muted, "practice.keyboard.source");
    }
}

fn drawRunButtons(owner: *control.Controller, theme: ui.Theme, footer_y: f32, pending: *?control.Intent) void {
    const session = &owner.session;
    const start: dvui.Rect = .{ .x = 0, .y = footer_y, .w = 120, .h = 40 };
    if (ui.button(theme, if (owner.active) "Restart" else "Start", "practice.start", start) and pending.* == null) {
        pending.* = .{ .start = true };
    }
    const new: dvui.Rect = .{ .x = 130, .y = footer_y, .w = 150, .h = 40 };
    if (ui.button(theme, "New exercise", "practice.new", new) and pending.* == null) pending.* = .new_exercise;
    const paused = session.state == .paused;
    const pause: dvui.Rect = .{ .x = 290, .y = footer_y, .w = 120, .h = 40 };
    if (ui.button(theme, if (paused) "Resume" else "Pause", "practice.pause", pause) and owner.active and pending.* == null) {
        pending.* = if (paused) .resume_run else .pause;
    }
    if (ui.button(theme, "Stop", "practice.stop", .{ .x = 420, .y = footer_y, .w = 100, .h = 40 }) and pending.* == null) pending.* = .stop;
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
    const summary = try std.fmt.allocPrint(arena, "{d}/{d} characters · {d} correction{s} · {s}{s}", .{
        session.matched(),
        session.reference_len,
        session.corrected,
        if (session.corrected == 1) "" else "s",
        if (session.scored) "scored" else "paste preview",
        code_speed,
    });
    presentation.caption(summary, .{ .x = 0, .y = footer_y + 63, .w = width, .h = 22 }, 14, theme.muted, null);
    presentation.caption(runnerStatus(owner, input), .{ .x = 0, .y = footer_y + 87, .w = width, .h = 22 }, 14, theme.muted, null);
}

fn runnerStatus(owner: *const control.Controller, input: Input) []const u8 {
    const diagnostic = if (owner.failure) |failure| switch (failure) {
        error.PracticeContextChanged => "Input source changed · start a fresh exercise",
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
        .start, .new_exercise => {
            view.scroll.at = null;
            view.drawn_len = 0;
        },
        else => {},
    }
    return effect;
}
