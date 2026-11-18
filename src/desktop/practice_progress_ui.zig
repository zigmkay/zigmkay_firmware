//! Native progress view; aggregate counts and chronological points share a cohort.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const rundown = @import("practice_rundown.zig");
const progress = desktop.practice_progress;
const results = desktop.practice_results;

pub const View = struct {
    smoothing: bool = false,
    goal: usize = 1,
    tab: usize = 0,
    range: usize = 0,
    matrix: usize = 0,
    selected: ?u21 = null,
    inspect: ?[16]u8 = null,
    message: []const u8 = "",
    retry: bool = false,
};

const hour_ns = 3_600_000_000_000;
const minute_us = 60_000_000;

fn compactButton(theme: ui.Theme, text: []const u8, tag: []const u8, rect: dvui.Rect) bool {
    var options = ui.options(theme, rect, 13);
    options.padding = .all(2);
    options.tag = tag;
    options.id_extra = @truncate(std.hash.Wyhash.hash(0, tag));
    return dvui.button(@src(), text, .{}, options);
}

fn hoursBetween(from: i64, to: i64) f64 {
    return (@as(f64, @floatFromInt(to)) - @as(f64, @floatFromInt(from))) / hour_ns;
}

/// Plots raw points as short bars, optionally joined by an exponentially smoothed
/// line that breaks across gaps of more than a day.
fn chart(data: *const progress.Summary, theme: ui.Theme, rect: dvui.Rect, accuracy: bool, smoothing: bool) void {
    if (data.count == 0) return;
    const points = data.points[0..data.count];
    const first = points[points.len - 1].timestamp;
    const span = @max(1, hoursBetween(first, points[0].timestamp));
    var ymax: f64 = if (accuracy) 101 else 10;
    if (!accuracy) for (points) |point| {
        ymax = @max(ymax, point.wpm * 1.1);
    };
    var ymin: f64 = 0;
    if (accuracy) {
        ymin = 95;
        for (points) |point| if (point.active_us > 0) {
            ymin = @min(ymin, @max(0, @floor(point.accuracy - 5)));
        };
    }
    var xaxis: dvui.PlotWidget.Axis = .{ .name = "Hours from first displayed run (UTC)", .min = -span * 0.01, .max = span * 1.01 };
    var yaxis: dvui.PlotWidget.Axis = .{ .name = if (accuracy) "Attempt accuracy (%)" else "Speed (WPM)", .min = ymin, .max = ymax };
    const plot = dvui.plot(@src(), .{ .x_axis = &xaxis, .y_axis = &yaxis, .mouse_hover = true }, .{
        .rect = rect,
        .id_extra = @intFromBool(accuracy),
        .background = true,
        .color_fill = .{ .color = theme.panel },
    });
    defer plot.deinit();
    var previous: ?struct { x: f64, y: f64, timestamp: i64 } = null;
    var index = points.len;
    while (index > 0) {
        index -= 1;
        const point = points[index];
        if (point.active_us == 0) {
            previous = null;
            continue;
        }
        const x = hoursBetween(first, point.timestamp);
        const y = if (accuracy) point.accuracy else point.wpm;
        const marker_height = (ymax - ymin) / 100;
        plot.bar(.{
            .x = x - span / 400,
            .y = @max(ymin, y - marker_height / 2),
            .w = span / 200,
            .h = marker_height,
            .color = ui.color(0x548FF5),
        });
        if (previous) |prior| {
            const gap = @as(f64, @floatFromInt(point.timestamp)) - @as(f64, @floatFromInt(prior.timestamp));
            if (gap > @as(f64, @floatFromInt(progress.day_ns))) previous = null;
        }
        // Optional exponential smoothing never replaces the raw points.
        const smooth = if (previous) |prior| 0.35 * y + 0.65 * prior.y else y;
        if (smoothing) if (previous) |prior| {
            var line = plot.line();
            line.point(prior.x, prior.y);
            line.point(x, smooth);
            line.stroke(1.5, ui.color(if (accuracy) 0x548FF5 else 0x69BFA3));
            line.deinit();
        };
        previous = .{ .x = x, .y = smooth, .timestamp = point.timestamp };
    }
}

/// Draws the progress page. Returns true when the user navigates back.
pub fn draw(
    view: *View,
    history: ?*const desktop.practice_history.Query,
    cohort: results.Cohort,
    failure: ?anyerror,
    saving: bool,
    theme: ui.Theme,
    bounds: dvui.Rect,
) !bool {
    const wide = bounds.w >= 1100;
    const page = presentation.Page.init(bounds, 860, "practice.progress", theme);
    defer page.deinit();
    const width = page.width;
    const arena = dvui.currentWindow().arena();
    presentation.header("Your progress", try cohortSummary(cohort), width, theme);
    if (presentation.backButton(theme, "Back to practice", "practice.progress.back", width)) return true;
    _ = dvui.dropdown(@src(), &.{ "Trends", "Activity" }, .{ .choice = &view.tab }, .{}, .{
        .rect = .{ .y = 92, .w = 145, .h = 36 },
    });
    _ = dvui.dropdown(@src(), &.{ "Newest 60", "Today (UTC)", "Last 7 days" }, .{ .choice = &view.range }, .{}, .{
        .rect = .{ .x = 157, .y = 92, .w = 170, .h = 36 },
    });
    const status_y: f32 = if (wide or view.tab != 0) 800 else 1310;
    page.ensureHeight(status_y + 110);
    const status = if (failure) |err|
        try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)})
    else if (saving)
        "Loading history…"
    else if (history != null and history.?.rejected > 0)
        "Some history could not be read; evidence is incomplete."
    else
        view.message;
    _ = presentation.flowText(status, 0, status_y, width - 110, 14, theme.muted);
    const retry: dvui.Rect = .{ .x = width - 100, .y = status_y, .w = 100, .h = 34 };
    if (failure != null and ui.button(theme, "Retry", "practice.progress.retry", retry)) view.retry = true;
    const query = history orelse {
        presentation.surface(.{ .y = 160, .w = width, .h = 180 }, theme.panel);
        _ = presentation.flowText("Loading matching practice history…", 24, 188, width - 48, 18, theme.muted);
        return false;
    };

    const empty = try arena.create(progress.Summary);
    empty.* = .{};
    const source = query.progress orelse empty;
    const data = try filterRange(source, view.range);
    try drawMetrics(source, data, width, theme);
    if (view.tab == 0) {
        try drawTrends(view, query, data, wide, width, theme);
    } else {
        try drawActivity(view, data, width, theme);
    }
    return false;
}

fn cohortSummary(cohort: results.Cohort) ![]const u8 {
    const arena = dvui.currentWindow().arena();
    const assistance = if (cohort.hints.revealed)
        "Help revealed"
    else if (cohort.assistance == .guided)
        desktop.practice_help.choices[@backingInt(cohort.hints.policy)]
    else
        ([_][]const u8{ "Guided", "Layout only", "Hidden" })[@backingInt(cohort.assistance)];
    if (cohort.curriculum.version != 0) {
        const stage = desktop.practice_curriculum.names[@backingInt(cohort.curriculum.stage)];
        return std.fmt.allocPrint(
            arena,
            "{s} · {d} letters · {s} · matching runs only",
            .{ stage, cohort.curriculum.alphabet, assistance },
        );
    }
    return std.fmt.allocPrint(arena, "{t} · {s} · {t} · matching runs only", .{ cohort.preset, assistance, cohort.mode });
}

/// Copies the points in the selected range: newest 60, today, or the last seven UTC days.
fn filterRange(source: *const progress.Summary, range: usize) !*const progress.Summary {
    const filtered = try dvui.currentWindow().arena().create(progress.Summary);
    filtered.* = source.*;
    filtered.count = 0;
    for (source.points[0..source.count]) |point| {
        const day = @divFloor(point.timestamp, progress.day_ns);
        if (range == 1 and day != source.today) continue;
        if (range == 2 and (day < source.today - 6 or day > source.today)) continue;
        filtered.points[filtered.count] = point;
        filtered.count += 1;
    }
    return filtered;
}

fn drawMetrics(source: *const progress.Summary, data: *const progress.Summary, width: f32, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    const metric_w = (width - 32) / 3;
    var total_speed: f64 = 0;
    var speed_count: usize = 0;
    for (data.points[0..data.count]) |point| if (point.active_us > 0) {
        total_speed += point.wpm;
        speed_count += 1;
    };
    const today = try std.fmt.allocPrint(arena, "{d:.1} min", .{@as(f64, @floatFromInt(source.days[0])) / minute_us});
    presentation.metric("Today", today, "Active practice · UTC", .{ .y = 148, .w = metric_w, .h = 116 }, theme);
    const average = if (speed_count > 0)
        try std.fmt.allocPrint(arena, "{d:.0} WPM", .{total_speed / @as(f64, @floatFromInt(speed_count))})
    else
        "—";
    const displayed = try std.fmt.allocPrint(arena, "{d} displayed runs", .{data.count});
    presentation.metric("Recent average", average, displayed, .{ .x = metric_w + 16, .y = 148, .w = metric_w, .h = 116 }, theme);
    const streak = try std.fmt.allocPrint(arena, "{d} runs", .{source.accuracyStreak()});
    const streak_bounds: dvui.Rect = .{ .x = 2 * (metric_w + 16), .y = 148, .w = metric_w, .h = 116 };
    presentation.metric("Accuracy streak", streak, "≥95% · newest 60 matching runs", streak_bounds, theme);
}

fn drawTrends(
    view: *View,
    history: *const desktop.practice_history.Query,
    data: *const progress.Summary,
    wide: bool,
    width: f32,
    theme: ui.Theme,
) !void {
    const charts_w = if (wide) (width - 20) * 0.58 else width;
    _ = dvui.checkbox(@src(), &view.smoothing, "Smooth trend", .{
        .rect = .{ .x = 340, .y = 92, .w = 170, .h = 36 },
        .tag = "practice.progress.smoothing",
    });
    for (0..2) |index| {
        const y: f32 = 292 + @as(f32, @floatFromInt(index)) * 236;
        presentation.surface(.{ .y = y, .w = charts_w, .h = 220 }, theme.panel);
        const title = if (index == 0) "Speed over time" else "Accuracy over time";
        presentation.label(title, .{ .x = 20, .y = y + 12, .w = charts_w - 40, .h = 30 }, 19, theme.text, null);
        if (data.count == 0) {
            _ = presentation.flowText("Finish a scored exercise to start this chart.", 24, y + 86, charts_w - 48, 16, theme.muted);
        } else {
            chart(data, theme, .{ .x = 12, .y = y + 52, .w = charts_w - 24, .h = 155 }, index == 1, view.smoothing);
        }
    }
    const matrix: dvui.Rect = if (wide)
        .{ .x = charts_w + 20, .y = 292, .w = width - (charts_w + 20), .h = 456 }
    else
        .{ .x = 0, .y = 774, .w = width, .h = 456 };
    try drawCharacterMatrix(view, history, data, matrix, theme);
    const note = "Blue: raw measurements. Smoothing keeps gaps over 24 hours open. Timing uses clean intervals only.";
    _ = presentation.flowText(note, 0, if (wide) 764 else 1248, width, 13, theme.muted);
}

/// A grid of the six weakest characters against the newest displayed runs.
fn drawCharacterMatrix(
    view: *View,
    history: *const desktop.practice_history.Query,
    data: *const progress.Summary,
    panel: dvui.Rect,
    theme: ui.Theme,
) !void {
    const arena = dvui.currentWindow().arena();
    const x = panel.x;
    const y = panel.y;
    const w = panel.w;
    presentation.surface(panel, theme.panel);
    presentation.label("Character progress", .{ .x = x + 20, .y = y + 12, .w = w - 40, .h = 30 }, 19, theme.text, null);
    _ = dvui.dropdown(@src(), &.{ "First-pass success", "Exposure", "Median (ms)" }, .{ .choice = &view.matrix }, .{}, .{
        .rect = .{ .x = x + 20, .y = y + 54, .w = @min(210, w - 40), .h = 34 },
    });
    const columns = @min(data.count, @min(12, @as(usize, @intFromFloat(@max(1, @floor((w - 80) / 50))))));
    const cell_w = (w - 80) / @as(f32, @floatFromInt(@max(1, columns)));
    for (0..columns) |column| {
        const point = data.points[columns - column - 1];
        var date: [32]u8 = undefined;
        const date_text = try results.dateLabel(point.timestamp, &date);
        const tag = try std.fmt.allocPrint(arena, "practice.progress.run.{d}", .{column});
        const cell: dvui.Rect = .{ .x = x + 60 + @as(f32, @floatFromInt(column)) * cell_w, .y = y + 106, .w = cell_w - 4, .h = 27 };
        if (compactButton(theme, if (point.timestamp >= 0) date_text[8..10] else "?", tag, cell)) {
            view.inspect = point.id;
            view.selected = null;
        }
    }
    var stats = history.all.stats;
    std.mem.sort(results.Stat, stats[0..history.all.stat_count], {}, struct {
        fn less(_: void, a: results.Stat, b: results.Stat) bool {
            return if (a.rank() == b.rank()) a.cp < b.cp else a.rank() > b.rank();
        }
    }.less);
    for (stats[0..@min(6, history.all.stat_count)], 0..) |stat, row| {
        const row_y = y + 142 + @as(f32, @floatFromInt(row)) * 34;
        var bytes: [4]u8 = undefined;
        const name = switch (stat.cp) {
            ' ' => "SPC",
            '\n' => "RET",
            '\t' => "TAB",
            else => desktop.practice_view.glyph(stat.cp, true, &bytes),
        };
        presentation.label(name, .{ .x = x + 22, .y = row_y, .w = 32, .h = 30 }, 14, theme.text, null);
        for (0..columns) |column| {
            const point = data.points[columns - column - 1];
            var found: ?progress.Character = null;
            for (point.characters[0..point.count]) |character| if (character.cp == stat.cp) {
                found = character;
                break;
            };
            var cell_theme = theme;
            cell_theme.control = matrixCellColor(view.matrix, found, theme);
            const tag = try std.fmt.allocPrint(arena, "practice.progress.cell.{d}.{d}", .{ row, column });
            const cell: dvui.Rect = .{ .x = x + 60 + @as(f32, @floatFromInt(column)) * cell_w, .y = row_y, .w = cell_w - 4, .h = 30 };
            if (compactButton(cell_theme, try matrixCellText(view.matrix, found, point.truncated), tag, cell)) {
                view.selected = stat.cp;
                view.inspect = point.id;
            }
        }
    }
    var first_date: [32]u8 = undefined;
    var last_date: [32]u8 = undefined;
    const dates = if (columns == 0)
        "No runs in this range"
    else
        try std.fmt.allocPrint(arena, "{s} to {s} · UTC", .{
            try dayLabel(data.points[columns - 1].timestamp, &first_date),
            try dayLabel(data.points[0].timestamp, &last_date),
        });
    _ = presentation.flowText(dates, x + 20, y + 360, w - 40, 13, theme.muted);
    _ = presentation.flowText("— no sample · * limited timing evidence", x + 20, y + 404, w - 40, 13, theme.muted);
}

fn dayLabel(timestamp: i64, buffer: *[32]u8) ![]const u8 {
    if (timestamp < 0) return "unknown time";
    return (try results.dateLabel(timestamp, buffer))[0..10];
}

fn matrixCellText(mode: usize, found: ?progress.Character, truncated: bool) ![]const u8 {
    const arena = dvui.currentWindow().arena();
    const character = found orelse return "—";
    switch (mode) {
        0 => {
            const success = if (character.opportunities == 0)
                @as(f64, 100)
            else
                100 - 100 * @as(f64, @floatFromInt(character.misses)) / @as(f64, @floatFromInt(character.opportunities));
            return std.fmt.allocPrint(arena, "{d:.0}%", .{success});
        },
        1 => return std.fmt.allocPrint(arena, "{d}", .{character.opportunities}),
        else => {
            if (character.samples == 0) return "—";
            const ms = @as(f64, @floatFromInt(character.median_us)) / 1000;
            const number = if (ms < 10_000)
                try std.fmt.allocPrint(arena, "{d:.0}", .{ms})
            else
                try std.fmt.allocPrint(arena, "{e:.0}", .{ms});
            return std.fmt.allocPrint(arena, "{s}{s}", .{ number, if (character.samples < 5 or truncated) "*" else "" });
        },
    }
}

fn matrixCellColor(mode: usize, found: ?progress.Character, theme: ui.Theme) dvui.Color {
    const character = found orelse return theme.control;
    if (mode == 0) {
        const stat: results.Stat = .{ .opportunities = character.opportunities, .misses = character.misses };
        return rundown.color(stat, presentation.isLight(theme));
    }
    if (mode == 1 or character.samples > 0) return presentation.shade(theme, 0xD4E6FF, 0x264F80);
    return theme.control;
}

/// A 28-day calendar of active practice minutes against the selected goal.
fn drawActivity(view: *View, data: *const progress.Summary, width: f32, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    presentation.surface(.{ .y = 292, .w = width, .h = if (width >= 1000) 370 else 430 }, theme.panel);
    presentation.label("Daily practice", .{ .x = 20, .y = 306, .w = width - 40, .h = 30 }, 20, theme.text, null);
    presentation.label("Last 28 UTC days · oldest to today", .{ .x = 20, .y = 342, .w = width - 40, .h = 24 }, 14, theme.muted, null);
    _ = dvui.dropdown(@src(), &.{ "1 minute goal", "3 minute goal", "5 minute goal" }, .{ .choice = &view.goal }, .{}, .{
        .rect = .{ .x = 20, .y = 384, .w = 180, .h = 34 },
    });
    const goal = ([_]u64{ 60, 180, 300 })[view.goal] * 1_000_000;
    const columns: usize = if (width >= 1000) 14 else 7;
    const cell_w = (width - 40) / @as(f32, @floatFromInt(columns));
    for (0..28) |index| {
        const ago = 27 - index;
        var cell_theme = theme;
        cell_theme.control = if (data.days[ago] >= goal)
            presentation.shade(theme, 0xC5EBDC, 0x245C4D)
        else if (data.day_runs[ago] > 0)
            presentation.shade(theme, 0xD4E6FF, 0x264F80)
        else
            theme.control;
        var date: [32]u8 = undefined;
        const day_label = try results.dateLabel((data.today - @as(i64, @intCast(ago))) * progress.day_ns, &date);
        const text = try std.fmt.allocPrint(arena, "{s}\n{d:.1}m", .{
            if (data.today > 28) day_label[5..10] else "—",
            @as(f64, @floatFromInt(data.days[ago])) / minute_us,
        });
        const tag = try std.fmt.allocPrint(arena, "practice.progress.day.{d}", .{ago});
        const cell: dvui.Rect = .{
            .x = 20 + @as(f32, @floatFromInt(index % columns)) * cell_w,
            .y = 434 + @as(f32, @floatFromInt(index / columns)) * 50,
            .w = cell_w - 6,
            .h = 44,
        };
        _ = compactButton(cell_theme, text, tag, cell);
    }
    const note = "Blue: practiced · green: goal reached. Minutes count active practice from matching scored completed runs.";
    _ = presentation.flowText(note, 20, if (columns == 14) 556 else 644, width - 40, 13, theme.muted);
}
