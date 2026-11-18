//! Learner-controlled curriculum. Recommendations never lock or demote a stage.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const curriculum = desktop.practice_curriculum;
const control = desktop.practice_controller;

pub const View = struct { config: control.Config = .{}, message: []const u8 = "" };
pub const Action = union(enum) { none, back, start: control.Config, free: control.Config };

const descriptions = [_][]const u8{
    "Find a small useful alphabet and space. Practice readable short words without a speed gate.",
    "Retain familiar letters while introducing one more. Build consistent timing and transitions at your own pace.",
    "Add one capital or shifted punctuation character with a proven compatible Shift provider.",
    "Practice one new output on a layer reached by a proven hold provider. Familiar words remain between targets.",
    "Choose one Option/AltGr or combined modifier family. Only proven reachable output is generated.",
    "Use full sentences, paired punctuation or Zig lessons. Every generated character needs a proven reachable route.",
};

/// Modifier families of the modifiers stage, in teaching order.
const modifier_variants = [_]u8{ 4, 64, 6, 66 };

/// The suggested step after `context`: the next family member, then the next
/// alphabet letter, layer or modifier family, then the next stage.
pub fn next(context: curriculum.Context, labels: desktop.practice.Labels) curriculum.Context {
    var output = context;
    var alphabet: [26]u8 = undefined;
    const available = curriculum.letters(labels, &alphabet);
    var symbols: [256]u21 = undefined;
    const members = curriculum.family(labels, context, &symbols);
    switch (context.stage) {
        .find_keys => output.stage = .fluency,
        .fluency => if (context.alphabet < available.len) {
            output.alphabet += 1;
        } else {
            output.stage = .shift;
            output.family = 0;
        },
        .shift, .layers, .modifiers => {
            if (@as(usize, context.family) + 1 < members.len) {
                output.family += 1;
                return output;
            }
            switch (context.stage) {
                .shift => {
                    output.family = 0;
                    if (!context.shifted_symbols) {
                        output.shifted_symbols = true;
                        if (curriculum.family(labels, output, &symbols).len == 0) {
                            output.stage = .layers;
                            output.layer = 1;
                        }
                    } else {
                        output.stage = .layers;
                        output.layer = 1;
                    }
                },
                .layers => {
                    output.family = 0;
                    if (@as(usize, context.layer) + 1 < labels.layer_count) {
                        output.layer += 1;
                    } else {
                        output.stage = .modifiers;
                        output.layer = 0;
                        output.modifiers = 4;
                    }
                },
                .modifiers => {
                    const index = std.mem.indexOfScalar(u8, &modifier_variants, context.modifiers) orelse 0;
                    if (index < modifier_variants.len - 1) {
                        output.modifiers = modifier_variants[index + 1];
                        output.family = 0;
                    } else {
                        output.stage = .real_text;
                    }
                },
                else => unreachable,
            }
        },
        .real_text => {},
    }
    return output;
}

const Layout = struct {
    x: f32,
    y: f32,
    width: f32,
    inner_x: f32,
    inner_w: f32,

    fn init(page_width: f32, wide: bool) Layout {
        const x: f32 = if (wide) 280 else 0;
        const width = page_width - x;
        return .{ .x = x, .y = if (wide) 96 else 346, .width = width, .inner_x = x + 24, .inner_w = width - 48 };
    }
};

pub fn draw(
    view: *View,
    owner: *control.Controller,
    history: ?*const desktop.practice_history.Query,
    history_cohort: desktop.practice_results.Cohort,
    theme: ui.Theme,
    bounds: dvui.Rect,
) !Action {
    const wide = bounds.w >= 1100;
    const page = presentation.Page.init(bounds, if (wide) 880 else 1230, "practice.curriculum", theme);
    defer page.deinit();
    const width = page.width;
    presentation.header("Learn your layout", "Choose a stage. Difficulty, help and length stay independent.", width, theme);
    if (presentation.backButton(theme, "Back to practice", "practice.curriculum.back", width)) return .back;
    const labels = owner.curriculum_labels orelse {
        _ = presentation.flowText("A known layout is needed to create reachable lessons.", 0, 120, width, 18, theme.muted);
        return .none;
    };
    try drawLearningPath(view, wide, width, theme);
    const layout = Layout.init(width, wide);
    const ready = try drawStage(view, owner, labels, history, history_cohort, layout, theme);
    const options_y = layout.y + 510;
    if (try drawNextExercise(view, owner, labels, ready, layout, options_y, theme)) |action| return action;

    const saved_x: f32 = if (wide) 20 else 0;
    const saved_y: f32 = if (wide) 610 else options_y + 210;
    const restore: dvui.Rect = .{ .x = saved_x, .y = saved_y, .w = 220, .h = 38 };
    if (history) |data| if (data.latest_curriculum) |record| {
        if (ui.button(theme, "Resume saved lesson", "practice.curriculum.restore", restore)) restoreLesson(view, record);
    };
    const free: dvui.Rect = .{ .x = if (wide) 20 else 236, .y = if (wide) saved_y + 52 else saved_y, .w = 200, .h = 38 };
    if (ui.button(theme, "Free exercises", "practice.curriculum.free", free)) {
        var config = owner.config;
        config.curriculum = .{};
        return .{ .free = config };
    }
    _ = presentation.flowText(view.message, 0, if (wide) 820 else 1130, width, 15, theme.text);
    return .none;
}

fn drawLearningPath(view: *View, wide: bool, width: f32, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    const path_w: f32 = if (wide) 260 else width;
    presentation.surface(.{ .y = 96, .w = path_w, .h = if (wide) 680 else 230 }, theme.panel);
    presentation.label("Learning path", .{ .x = 20, .y = 110, .w = path_w - 40, .h = 30 }, 18, theme.text, null);
    for (curriculum.names, 0..) |name, index| {
        var stage_theme = theme;
        if (@backingInt(view.config.curriculum.stage) == index) stage_theme.control = presentation.shade(theme, 0xC5EBDC, 0x245C4D);
        const stage_w: f32 = if (wide) path_w - 40 else (width - 52) / 2;
        const x: f32 = if (wide) 20 else 20 + @as(f32, @floatFromInt(index % 2)) * (stage_w + 12);
        const y: f32 = 158 + @as(f32, @floatFromInt(if (wide) index else index / 2)) * 50;
        var options = ui.options(stage_theme, .{ .x = x, .y = y, .w = stage_w, .h = 40 }, 15);
        options.tag = try std.fmt.allocPrint(arena, "practice.curriculum.stage.{d}", .{index});
        options.id_extra = index;
        if (dvui.button(@src(), try std.fmt.allocPrint(arena, "{d}. {s}", .{ index + 1, name }), .{}, options)) {
            selectStage(&view.config, @fromBackingInt(@as(u3, @intCast(index))));
            view.message = "Lesson selected. Start when ready.";
        }
    }
}

fn selectStage(config: *control.Config, stage: curriculum.Stage) void {
    config.curriculum.stage = stage;
    config.curriculum.family = 0;
    if (stage != .real_text) {
        config.mode = .english;
        config.preset = .words;
    }
    if (stage == .modifiers) config.curriculum.layer = 0;
    if (stage == .layers and config.curriculum.layer == 0) config.curriculum.layer = 1;
}

/// Draws the selected stage's settings and readiness. Returns whether the
/// learner is ready for the suggested next step.
fn drawStage(
    view: *View,
    owner: *control.Controller,
    labels: desktop.practice.Labels,
    history: ?*const desktop.practice_history.Query,
    history_cohort: desktop.practice_results.Cohort,
    layout: Layout,
    theme: ui.Theme,
) !bool {
    const arena = dvui.currentWindow().arena();
    const stage = &view.config.curriculum;
    const x = layout.inner_x;
    const y = layout.y;
    const w = layout.inner_w;
    presentation.surface(.{ .x = layout.x, .y = y, .w = layout.width, .h = 490 }, theme.panel);
    const title = try std.fmt.allocPrint(
        arena,
        "Stage {d}: {s}",
        .{ @backingInt(stage.stage) + 1, curriculum.names[@backingInt(stage.stage)] },
    );
    presentation.label(title, .{ .x = x, .y = y + 16, .w = w, .h = 34 }, 22, theme.text, null);
    _ = presentation.flowText(descriptions[@backingInt(stage.stage)], x, y + 66, w, 16, theme.muted);

    var alphabet: [26]u8 = undefined;
    const available = curriculum.letters(labels, &alphabet);
    const learned = available[0..@min(available.len, stage.alphabet)];
    var alphabet_text: std.Io.Writer.Allocating = .init(arena);
    for (learned, 0..) |cp, index| try alphabet_text.writer.print("{s}{c}", .{ if (index == 0) "" else " ", cp });
    const real_text = stage.stage == .real_text;
    const alphabet_title = if (real_text) "Full text · reachable routes" else "Your current alphabet";
    presentation.label(alphabet_title, .{ .x = x, .y = y + 140, .w = w, .h = 24 }, 14, theme.muted, null);
    const alphabet_value = if (real_text) "Sentences and code" else alphabet_text.written();
    presentation.label(alphabet_value, .{ .x = x, .y = y + 170, .w = w, .h = 42 }, if (learned.len > 16) 20 else 28, theme.text, null);
    const less: dvui.Rect = .{ .x = x, .y = y + 228, .w = 175, .h = 36 };
    if (ui.buttonEnabled(theme, "One fewer letter", "practice.curriculum.less", less, !real_text and stage.alphabet > 6)) {
        stage.alphabet -= 1;
    }
    const more: dvui.Rect = .{ .x = x + 187, .y = y + 228, .w = 170, .h = 36 };
    if (ui.buttonEnabled(theme, "Add one letter", "practice.curriculum.more", more, !real_text and stage.alphabet < available.len)) {
        stage.alphabet += 1;
    }
    try drawStageOptions(view, labels, layout);

    var members_buffer: [256]u21 = undefined;
    const members = curriculum.family(labels, stage.*, &members_buffer);
    if (stage.stage == .shift or stage.stage == .layers or stage.stage == .modifiers) {
        try drawFamilyTarget(view, members, layout, theme);
    }
    var expected: [26]u21 = undefined;
    var expected_count: usize = 0;
    if (stage.stage == .find_keys or stage.stage == .fluency or stage.stage == .real_text) {
        for (if (stage.stage == .real_text) available else learned) |cp| {
            expected[expected_count] = cp;
            expected_count += 1;
        }
    } else if (stage.family < members.len) {
        expected[0] = members[stage.family];
        expected_count = 1;
    }
    const matching = std.meta.eql(owner.cohortFor(view.config), history_cohort);
    const assessment = if (matching and history != null)
        curriculum.assess(stage.*, history.?.all, history.?.progress, expected[0..expected_count])
    else
        curriculum.Assessment{ .missing = expected_count };
    try drawAssessment(stage.stage, assessment, expected_count, layout, theme);
    return assessment.ready;
}

/// Layer, modifier family or real-text corpus selectors for the current stage.
fn drawStageOptions(view: *View, labels: desktop.practice.Labels, layout: Layout) !void {
    const arena = dvui.currentWindow().arena();
    const stage = &view.config.curriculum;
    const x = layout.inner_x;
    const y = layout.y + 278;
    if (stage.stage == .shift) _ = dvui.checkbox(@src(), &stage.shifted_symbols, "Shifted punctuation", .{
        .rect = .{ .x = x, .y = layout.y + 280, .w = layout.inner_w, .h = 34 },
    });
    if (stage.stage == .layers or stage.stage == .modifiers) {
        const layers = try arena.alloc([]const u8, labels.layer_count);
        for (layers, 0..) |*name, index| name.* = try std.fmt.allocPrint(arena, "Layer {d}", .{index});
        var layer: usize = @min(stage.layer, labels.layer_count - 1);
        if (dvui.dropdown(@src(), layers, .{ .choice = &layer }, .{}, .{ .rect = .{ .x = x, .y = y, .w = 140, .h = 36 } })) {
            stage.family = 0;
        }
        stage.layer = @intCast(layer);
        if (stage.stage == .modifiers) {
            var variant = std.mem.indexOfScalar(u8, &modifier_variants, stage.modifiers) orelse 0;
            const names = [_][]const u8{ "Option / left Alt", "AltGr / right Alt", "Shift + Option", "Shift + AltGr" };
            if (dvui.dropdown(@src(), &names, .{ .choice = &variant }, .{}, .{ .rect = .{ .x = x + 152, .y = y, .w = 205, .h = 36 } })) {
                stage.modifiers = modifier_variants[variant];
                stage.family = 0;
            }
        }
    }
    if (stage.stage == .real_text) {
        var mode: usize = @backingInt(view.config.mode);
        if (dvui.dropdown(@src(), &.{ "English sentences", "Zig lessons" }, .{ .choice = &mode }, .{}, .{
            .rect = .{ .x = x, .y = y, .w = 200, .h = 36 },
        })) view.config.mode = @fromBackingInt(@as(u1, @intCast(mode)));
        if (view.config.mode == .english) {
            var preset: usize = @backingInt(view.config.preset);
            if (dvui.dropdown(@src(), &.{ "Words", "Mixed case", "Punctuation" }, .{ .choice = &preset }, .{}, .{
                .rect = .{ .x = x + 212, .y = y, .w = 160, .h = 36 },
            })) view.config.preset = @fromBackingInt(@as(u2, @intCast(preset)));
        }
    }
}

fn drawFamilyTarget(view: *View, members: []const u21, layout: Layout, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    const x = layout.inner_x;
    const y = layout.y + 324;
    if (members.len == 0) {
        const text = "No compatible output here. Choose another family or stage.";
        _ = presentation.flowText(text, x, layout.y + 322, layout.inner_w, 14, theme.muted);
        return;
    }
    const names = try arena.alloc([]const u8, members.len);
    for (members, names) |cp, *name| {
        var bytes: [4]u8 = undefined;
        name.* = try arena.dupe(u8, desktop.practice_view.glyph(cp, true, &bytes));
    }
    var choice: usize = @min(view.config.curriculum.family, members.len - 1);
    _ = dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{
        .rect = .{ .x = x, .y = y, .w = 100, .h = 34 },
        .tag = "practice.curriculum.target",
    });
    view.config.curriculum.family = @intCast(choice);
    presentation.label("One new output at a time", .{ .x = x + 112, .y = y, .w = layout.inner_w - 112, .h = 34 }, 14, theme.muted, null);
}

fn drawAssessment(
    stage: curriculum.Stage,
    assessment: curriculum.Assessment,
    expected_count: usize,
    layout: Layout,
    theme: ui.Theme,
) !void {
    const x = layout.inner_x;
    const y = layout.y;
    const w = layout.inner_w;
    const title = if (assessment.ready)
        "Ready for a suggested next step"
    else
        try std.fmt.allocPrint(
            dvui.currentWindow().arena(),
            "{d}/3 runs · {d} targets need more practice",
            .{ @min(3, assessment.runs), assessment.missing },
        );
    presentation.label(title, .{ .x = x, .y = y + 376, .w = w, .h = 28 }, 17, theme.text, null);
    const advice = if (assessment.ready)
        "Advance when you feel ready. Your selected lesson never changes automatically."
    else if (stage == .find_keys)
        "Aim for 20 opportunities per target at 97% first-pass success across three runs. No speed gate."
    else
        "Build three accurate runs and clean timing evidence before advancing.";
    _ = presentation.flowText(advice, x, y + 412, w, 14, theme.muted);
    const run_fraction = @as(f32, @floatFromInt(@min(3, assessment.runs))) / 3;
    const target_fraction = if (expected_count == 0)
        @as(f32, 0)
    else
        @as(f32, @floatFromInt(expected_count - assessment.missing)) / @as(f32, @floatFromInt(expected_count));
    const timing_fraction = if (stage == .find_keys) @as(f32, 1) else @as(f32, @floatFromInt(assessment.timing_runs)) / 3;
    presentation.surface(.{ .x = x, .y = y + 464, .w = w, .h = 6 }, theme.control);
    const filled = w * (run_fraction + target_fraction + timing_fraction) / 3;
    presentation.surface(.{ .x = x, .y = y + 464, .w = filled, .h = 6 }, ui.color(0x69BFA3));
}

/// Draws the help, length and start controls. Returns an action when the lesson starts.
fn drawNextExercise(
    view: *View,
    owner: *control.Controller,
    labels: desktop.practice.Labels,
    ready: bool,
    layout: Layout,
    options_y: f32,
    theme: ui.Theme,
) !?Action {
    const x = layout.inner_x;
    presentation.surface(.{ .x = layout.x, .y = options_y, .w = layout.width, .h = 180 }, theme.panel);
    presentation.label("Next exercise", .{ .x = x, .y = options_y + 14, .w = layout.inner_w, .h = 30 }, 20, theme.text, null);
    var assistance: usize = desktop.practice_help.choice(view.config);
    if (dvui.dropdown(@src(), &desktop.practice_help.choices, .{ .choice = &assistance }, .{}, .{
        .rect = .{ .x = x, .y = options_y + 62, .w = 210, .h = 38 },
    })) desktop.practice_help.apply(&view.config, assistance);
    const lengths: []const []const u8 = if (view.config.mode == .english)
        &.{ "Short", "Normal", "Long" }
    else
        &desktop.practice.lesson_names;
    _ = dvui.dropdown(@src(), lengths, .{ .choice = &view.config.level }, .{}, .{
        .rect = .{ .x = x + 222, .y = options_y + 62, .w = 170, .h = 38 },
    });
    const start: dvui.Rect = .{ .x = x, .y = options_y + 120, .w = 165, .h = 40 };
    if (ui.button(presentation.primary(theme), "Start lesson", "practice.curriculum.start", start)) {
        return startLesson(view, owner, labels);
    }
    const next_label = if (view.config.curriculum.stage == .real_text) "Repeat real text" else "Suggested next step";
    const next_bounds: dvui.Rect = .{ .x = x + 177, .y = options_y + 120, .w = 205, .h = 40 };
    if (ui.buttonEnabled(theme, next_label, "practice.curriculum.next", next_bounds, ready)) {
        view.config.curriculum = next(view.config.curriculum, labels);
        view.message = "Next lesson selected. Start when ready.";
    }
    return null;
}

fn startLesson(view: *View, owner: *control.Controller, labels: desktop.practice.Labels) Action {
    view.config.challenge = null;
    view.config.target_count = 0;
    var buffer: [8192]u8 = undefined;
    const text = owner.preview(&buffer, view.config) catch |err| {
        view.message = switch (err) {
            error.CurriculumAlphabetUnavailable => "Choose fewer base letters for this layout.",
            error.CurriculumFamilyUnavailable => "Choose another layer, modifier or stage; no supported output here.",
            error.CurriculumCorpusUnavailable => "Add a letter to provide more readable words.",
            error.CurriculumSpaceUnavailable => "Space needs a base-layer route before starting.",
            error.CurriculumRouteUnavailable => "Try a simpler preset; a character has no reachable route.",
            error.CurriculumLayoutUnavailable => "Select a known layout before starting.",
            else => @errorName(err),
        };
        return .none;
    };
    curriculum.validateText(labels, text) catch |err| {
        view.message = @errorName(err);
        return .none;
    };
    return .{ .start = view.config };
}

fn restoreLesson(view: *View, record: anytype) void {
    view.config.curriculum = record.cohort.curriculum;
    view.config.mode = @fromBackingInt(@backingInt(record.cohort.family));
    view.config.level = if (record.cohort.family == .zig) record.cohort.lesson else record.cohort.length;
    view.config.preset = record.cohort.preset;
    view.config.assistance = record.cohort.assistance;
    view.config.hints = record.cohort.hints;
    view.config.hints.revealed = false;
    view.message = "Saved lesson restored for this layout and input source.";
}
