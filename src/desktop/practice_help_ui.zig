//! Optional hint settings and recall navigation, separate from exercise input.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const control = desktop.practice_controller;
const retention = desktop.practice_retention;

pub const Review = struct {
    page: usize = 0,
    due_only: bool = true,
    message: []const u8 = "",
    retry: bool = false,
    details: bool = false,
};

pub const Action = union(enum) { none, back, start: control.Config };

const rows_per_page = 8;
const row_pitch: f32 = 90;

pub fn reviews(
    view: *Review,
    owner: *control.Controller,
    history: ?*const desktop.practice_history.Query,
    failure: ?anyerror,
    saving: bool,
    theme: ui.Theme,
    bounds: dvui.Rect,
) !Action {
    const data = if (history) |h| h.retention else null;
    const page = presentation.Page.init(bounds, 120, "practice.review", theme);
    defer page.deinit();
    const width = page.width;
    const arena = dvui.currentWindow().arena();
    presentation.header("Recall review", "Optional practice. A due review is an invitation, not a deadline.", width, theme);
    if (presentation.backButton(theme, "Back to practice", "practice.review.back", width)) return .back;
    _ = dvui.checkbox(@src(), &view.due_only, "Due reviews only", .{ .rect = .{ .y = 94, .w = 200, .h = 34 } });
    _ = dvui.checkbox(@src(), &view.details, "Review rules", .{ .rect = .{ .x = 220, .y = 94, .w = 190, .h = 34 } });
    var visible: [256]retention.Entry = undefined;
    const count = if (data) |summary| visibleEntries(summary, view.due_only, &visible) else 0;
    const rows_y: f32 = if (view.details) 362 else 218;
    const row_count = @min(rows_per_page, count);
    const footer_y = rows_y + @as(f32, @floatFromInt(@max(1, row_count))) * row_pitch + 28;
    page.ensureHeight(footer_y + 160);
    drawRules(view.details, width, theme);
    const pages = @max(1, (count + rows_per_page - 1) / rows_per_page);
    view.page = @min(view.page, pages - 1);
    const first = view.page * rows_per_page;
    if (count == 0) {
        presentation.surface(.{ .y = rows_y, .w = width, .h = 100 }, theme.panel);
        const text = if (data == null)
            "Finish newly recorded scored exercises to build review evidence. Older counts stay available."
        else
            "No reviews due. Keep practicing, or show all tracked characters for an early check.";
        _ = presentation.flowText(text, 24, rows_y + 26, width - 48, 17, theme.text);
    }
    for (visible[first..@min(count, first + rows_per_page)], 0..) |entry, index| {
        const y = rows_y + @as(f32, @floatFromInt(index)) * row_pitch;
        if (try drawEntry(entry, y, width, theme)) {
            const config = recallConfig(owner.config, entry);
            var buffer: [8192]u8 = undefined;
            _ = owner.preview(&buffer, config) catch {
                view.message = "This target needs a matching corpus or guided lesson.";
                return .none;
            };
            return .{ .start = config };
        }
    }
    if (pages > 1 and ui.button(theme, "Next page", "practice.review.next", .{ .y = footer_y, .w = 140, .h = 36 })) {
        view.page = (view.page + 1) % pages;
    }
    if (data) |summary| {
        const text = try std.fmt.allocPrint(arena, "{d} characters · {d} recorded runs · {d} runs lack complete cue evidence{s}", .{
            summary.count,
            summary.eligible_runs,
            summary.unknown_runs,
            if (summary.truncated) " · list limited to 256" else "",
        });
        const x: f32 = if (pages > 1) 160 else 0;
        _ = presentation.flowText(text, x, footer_y, width - x, 13, theme.muted);
    }
    const status = if (failure) |err|
        try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)})
    else if (saving)
        "Loading review evidence…"
    else
        view.message;
    _ = presentation.flowText(status, 0, footer_y + 58, width - 110, 14, theme.muted);
    const retry: dvui.Rect = .{ .x = width - 100, .y = footer_y + 58, .w = 100, .h = 34 };
    if (failure != null and ui.button(theme, "Retry", "practice.review.retry", retry)) view.retry = true;
    return .none;
}

/// Entries with enough evidence, soonest due first, optionally limited to due ones.
fn visibleEntries(summary: anytype, due_only: bool, output: *[256]retention.Entry) usize {
    var sorted = summary.entries;
    std.mem.sort(retention.Entry, sorted[0..summary.count], {}, struct {
        fn less(_: void, a: retention.Entry, b: retention.Entry) bool {
            return if (a.dueAt() == b.dueAt()) a.cp < b.cp else a.dueAt() < b.dueAt();
        }
    }.less);
    var count: usize = 0;
    for (sorted[0..summary.count]) |entry| {
        if ((due_only and !entry.due(summary.now)) or entry.opportunities < 5) continue;
        output[count] = entry;
        count += 1;
    }
    return count;
}

fn drawRules(details: bool, width: f32, theme: ui.Theme) void {
    presentation.surface(.{ .y = 148, .w = width, .h = if (details) 190 else 50 }, theme.panel);
    const summary = "Hidden recall keeps familiar words around the target. Show hint is always available.";
    _ = presentation.flowText(summary, 20, 162, width - 40, 14, theme.muted);
    if (!details) return;
    const rules = "A qualifying check needs hidden help, no revealed cue, positive duration, five clean uncued " ++
        "occurrences and ≥97% uncued first-pass success. Visible layout practice is assistance. Suggested " ++
        "intervals are 1, 3, 7 and 14 days. Older and truncated runs cannot establish unaided recall.";
    _ = presentation.flowText(rules, 20, 218, width - 40, 14, theme.muted);
}

/// Draws one review card. Returns whether its "Practice recall" button was pressed.
fn drawEntry(entry: retention.Entry, y: f32, width: f32, theme: ui.Theme) !bool {
    const arena = dvui.currentWindow().arena();
    presentation.surface(.{ .y = y, .w = width, .h = 78 }, theme.panel);
    var bytes: [4]u8 = undefined;
    var date: [32]u8 = undefined;
    const character = desktop.practice_view.glyph(entry.cp, true, &bytes);
    presentation.label(character, .{ .x = 24, .y = y + 16, .w = 52, .h = 42 }, 28, theme.text, null);
    const counts = try std.fmt.allocPrint(
        arena,
        "{d} samples · {d} cued · {d} uncued",
        .{ entry.opportunities, entry.cued, entry.uncued },
    );
    presentation.label(counts, .{ .x = 92, .y = y + 12, .w = width - 292, .h = 24 }, 14, theme.text, null);
    const due_label = if (entry.last_recall == null)
        "First unaided check"
    else
        try std.fmt.allocPrint(
            arena,
            "Suggested review: {s} (UTC)",
            .{(try desktop.practice_results.dateLabel(entry.dueAt(), &date))[0..10]},
        );
    presentation.label(due_label, .{ .x = 92, .y = y + 43, .w = width - 292, .h = 22 }, 13, theme.muted, null);
    const tag = try std.fmt.allocPrint(arena, "practice.review.start.{d}", .{entry.cp});
    return ui.button(theme, "Practice recall", tag, .{ .x = width - 180, .y = y + 20, .w = 160, .h = 38 });
}

/// A hidden-help single-target exercise in the context where the entry was learned.
fn recallConfig(base: control.Config, entry: retention.Entry) control.Config {
    var config = base;
    config.challenge = null;
    config.assistance = .hidden;
    config.hints = .{};
    config.targets[0] = entry.cp;
    config.target_count = 1;
    config.curriculum = entry.context.curriculum;
    config.preset = entry.context.preset;
    if (entry.context.family == .zig) {
        config.mode = .zig;
        config.level = entry.context.lesson;
        config.target_count = 0;
    } else {
        config.mode = .english;
    }
    if (config.curriculum.version == 0 and config.mode == .english) {
        config.preset = if (entry.cp >= 'a' and entry.cp <= 'z')
            .words
        else if (entry.cp >= 'A' and entry.cp <= 'Z')
            .mixed_case
        else
            .punctuation;
    }
    return config;
}

/// Draws the hint settings page. Returns true when the user applies the settings.
pub fn settings(config: *control.Config, theme: ui.Theme, viewport: dvui.Rect) !bool {
    const wide = viewport.w >= 1100;
    const page = presentation.Page.init(viewport, if (wide) 640 else 850, "practice.help.title", theme);
    defer page.deinit();
    const width = page.width;
    presentation.header("Hint settings", "Choose the amount of help. Show hint remains available during every exercise.", width, theme);
    const left_w = if (wide) (width - 20) * 0.62 else width;
    drawPolicy(config, left_w, theme);
    const note_x = if (wide) left_w + 20 else 0;
    const note_y: f32 = if (wide) 96 else 516;
    const note_w = if (wide) width - note_x else width;
    presentation.surface(.{ .x = note_x, .y = note_y, .w = note_w, .h = 200 }, theme.panel);
    const title: dvui.Rect = .{ .x = note_x + 24, .y = note_y + 18, .w = note_w - 48, .h = 28 };
    presentation.label("Help stays under your control", title, 18, theme.text, null);
    const note = "Start a fresh run to apply a different policy. Revealing help during hidden recall keeps that run " ++
        "separate from fully hidden evidence.";
    _ = presentation.flowText(note, note_x + 24, note_y + 68, note_w - 48, 15, theme.muted);
    const apply: dvui.Rect = .{ .y = if (wide) 520 else 740, .w = 200, .h = 42 };
    return ui.button(presentation.primary(theme), "Apply and return", "practice.help.apply", apply);
}

fn drawPolicy(config: *control.Config, left_w: f32, theme: ui.Theme) void {
    presentation.surface(.{ .y = 96, .w = left_w, .h = 400 }, theme.panel);
    presentation.label("How much help?", .{ .x = 24, .y = 114, .w = left_w - 48, .h = 30 }, 20, theme.text, null);
    presentation.label("Hint policy", .{ .x = 24, .y = 166, .w = left_w - 48, .h = 24 }, 14, theme.muted, null);
    var choice = desktop.practice_help.choice(config.*);
    if (dvui.dropdown(@src(), &desktop.practice_help.choices, .{ .choice = &choice }, .{}, .{
        .rect = .{ .x = 24, .y = 200, .w = 250, .h = 40 },
    })) desktop.practice_help.apply(config, choice);
    if (config.assistance == .guided and config.hints.policy == .delayed) {
        const delays = [_]u16{ 250, 500, 1000, 1500, 2000, 3000, 5000, 10000 };
        const delay_names = [_][]const u8{
            "250 ms",
            "500 ms",
            "1 second",
            "1.5 seconds",
            "2 seconds",
            "3 seconds",
            "5 seconds",
            "10 seconds",
        };
        var delay = std.mem.indexOfScalar(u16, &delays, config.hints.delay_ms) orelse 3;
        presentation.label("Wait before showing a hint", .{ .x = 24, .y = 268, .w = left_w - 48, .h = 24 }, 14, theme.muted, null);
        if (dvui.dropdown(@src(), &delay_names, .{ .choice = &delay }, .{}, .{
            .rect = .{ .x = 24, .y = 302, .w = 175, .h = 38 },
        })) config.hints.delay_ms = delays[delay];
        _ = dvui.checkbox(@src(), &config.hints.adaptive, "Adapt to my pace", .{
            .rect = .{ .x = 215, .y = 302, .w = left_w - 239, .h = 38 },
        });
        const note = "The delay counts hesitation, not paused time. Adaptation uses your recorded character timing.";
        _ = presentation.flowText(note, 24, 374, left_w - 48, 15, theme.muted);
        return;
    }
    const description = switch (config.assistance) {
        .hidden => "The keyboard stays hidden until you request help.",
        .layout_only => "See the layout without predictive highlights. Request a hint whenever you need one.",
        .guided => if (config.hints.policy == .on_request)
            "Highlights appear when you choose Show hint."
        else
            "Highlights stay available as you type.",
    };
    _ = presentation.flowText(description, 24, 280, left_w - 48, 17, theme.muted);
}
