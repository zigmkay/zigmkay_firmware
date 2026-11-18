//! On-demand timing diagnostics. Raw events remain inspectable beside exclusions.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const results = desktop.practice_results;
const analysis_model = desktop.practice_analysis;
const timing = desktop.practice_timing;
const control = desktop.practice_controller;
const glyph = presentation.glyphName;

pub const View = struct {
    tab: usize = 0,
    choice: usize = 0,
    event_page: usize = 0,
    event: usize = 0,
    message: []const u8 = "",
    retry: bool = false,
};

pub const Action = union(enum) { none, back, drill: control.Config };

const events_per_page = 12;

fn milliseconds(us: u64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000;
}

fn seconds(us: u64) f64 {
    return @as(f64, @floatFromInt(us)) / 1_000_000;
}

/// The median of this character's per-run medians across at least three other
/// untruncated matching runs with five clean samples each.
fn personal(history: *const desktop.practice_history.Query, id: [16]u8, cp: u21) ?u64 {
    var values: [60]u64 = undefined;
    var count: usize = 0;
    if (history.progress) |data| for (data.points[0..data.count]) |point| {
        if (std.mem.eql(u8, &point.id, &id) or point.truncated) continue;
        for (point.characters[0..point.count]) |character| if (character.cp == cp and character.samples >= 5) {
            values[count] = character.median_us;
            count += 1;
        };
    };
    if (count < 3) return null;
    std.mem.sort(u64, values[0..count], {}, std.sort.asc(u64));
    return values[(count - 1) / 2] + (values[count / 2] - values[(count - 1) / 2]) / 2;
}

pub fn draw(
    view: *View,
    selected: ?u21,
    owner: *control.Controller,
    record: *const results.Record,
    history: ?*const desktop.practice_history.Query,
    saving: bool,
    failure: ?anyerror,
    theme: ui.Theme,
    bounds: dvui.Rect,
) !Action {
    const wide = bounds.w >= 1100;
    const content_height: f32 = if (view.tab == 1) 1440 else if (wide) 1000 else 1390;
    const page = presentation.Page.init(bounds, content_height, "practice.diagnostics", theme);
    defer page.deinit();
    const width = page.width;
    const arena = dvui.currentWindow().arena();
    presentation.header("Timing details", "Delivered text intervals · clean timing and raw events stay separate.", width, theme);
    if (presentation.backButton(theme, "Back to rundown", "practice.diagnostics.back", width)) return .back;
    _ = dvui.dropdown(@src(), &.{ "Characters", "Rhythm and events", "Skills and provenance" }, .{ .choice = &view.tab }, .{}, .{
        .rect = .{ .y = 92, .w = 240, .h = 36 },
    });
    const status = if (failure) |err|
        try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)})
    else if (saving)
        "Loading timing…"
    else
        view.message;
    var status_y: f32 = if (view.tab == 1) 1410 else if (!wide and view.tab == 0) 1350 else 940;
    // The status line goes below whatever the selected tab drew, including on early returns.
    defer {
        const status_height = presentation.flowText(status, 0, status_y, width - 110, 14, theme.muted);
        page.ensureHeight(status_y + @max(36, status_height) + 40);
        const retry: dvui.Rect = .{ .x = width - 100, .y = status_y, .w = 100, .h = 36 };
        if (failure != null and ui.button(theme, "Retry", "practice.diagnostics.retry", retry)) view.retry = true;
    }
    if (!record.timing_available) {
        _ = presentation.flowText("This older run has counts only. New exercises record timing.", 0, 184, width, 18, theme.muted);
        return .none;
    }
    const analysis = (if (history) |h| h.analysis else null) orelse {
        const text = if (saving) "Waiting for saved timing…" else "Timing is unavailable. Counts remain in the rundown.";
        _ = presentation.flowText(text, 0, 184, width, 18, theme.muted);
        return .none;
    };
    const payload = history.?.timing.?.payload;
    const summary = try std.fmt.allocPrint(arena, "{d} clean intervals · {d} raw events{s}", .{
        analysis.eligible,
        payload.events.len,
        if (analysis.truncated) " · recording truncated" else "",
    });
    presentation.label(summary, .{ .y = 144, .w = width, .h = 26 }, 14, theme.muted, null);
    switch (view.tab) {
        0 => {
            if (record.stat_count == 0) return .none;
            return drawCharacters(view, selected, owner, record, history.?, analysis, wide, width, &status_y, theme);
        },
        1 => try drawEvents(view, analysis, payload, width, theme),
        else => try drawProvenance(selected, record, analysis, width, &status_y, theme),
    }
    return .none;
}

fn drawCharacters(
    view: *View,
    selected: ?u21,
    owner: *control.Controller,
    record: *const results.Record,
    history: *const desktop.practice_history.Query,
    analysis: anytype,
    wide: bool,
    width: f32,
    status_y: *f32,
    theme: ui.Theme,
) !Action {
    const arena = dvui.currentWindow().arena();
    const stats = record.stats[0..record.stat_count];
    const names = try arena.alloc([]const u8, stats.len);
    for (stats, names) |stat, *name| {
        var bytes: [4]u8 = undefined;
        name.* = try arena.dupe(u8, glyph(stat.cp, &bytes));
    }
    view.choice = @min(view.choice, stats.len - 1);
    if (selected) |cp| if (view.message.len == 0) for (stats, 0..) |stat, index| if (stat.cp == cp) {
        view.choice = index;
        break;
    };
    if (dvui.dropdown(@src(), names, .{ .choice = &view.choice }, .{}, .{
        .rect = .{ .x = 260, .y = 92, .w = 120, .h = 36 },
        .tag = "practice.diagnostics.character",
    })) view.message = "Character selected";
    const stat = stats[view.choice];
    const value = analysis.character(stat.cp) orelse analysis_model.Quantiles{};
    const baseline = personal(history, record.id, stat.cp);
    try drawCharacterMetrics(stat, value, width, theme);

    const chart_w = if (wide) (width - 20) * 0.62 else width;
    presentation.surface(.{ .y = 332, .w = chart_w, .h = 310 }, theme.panel);
    presentation.label("Character interval over time", .{ .x = 20, .y = 346, .w = chart_w - 40, .h = 30 }, 19, theme.text, null);
    if (history.progress) |data| intervalChart(data, stat.cp, value, baseline, chart_w, theme);
    const coaching = if (value.count == 0)
        "No clean timing samples for this character yet."
    else if (baseline) |target|
        try std.fmt.allocPrint(arena, "Personal reference: {d:.0} ms. {s}", .{
            milliseconds(target),
            if (value.count >= 5 and !analysis.truncated and
                @as(f64, @floatFromInt(value.median_us)) > @as(f64, @floatFromInt(target)) * 1.25)
                "Try a careful short drill."
            else
                "Build consistency before increasing speed.",
        })
    else
        "A personal reference needs three other matching runs with five clean samples each.";
    _ = presentation.flowText(coaching, 0, 666, chart_w, 15, theme.muted);
    const drill: dvui.Rect = .{ .y = 750, .w = 230, .h = 40 };
    if (ui.button(presentation.primary(theme), "Practice this character", "practice.diagnostics.drill", drill)) {
        if (!record.scored or !owner.matchesSettings(record.cohort) or owner.config.mode != .english) {
            view.message = "Use a scored English run with matching exercise settings.";
        } else {
            var config = owner.config;
            config.challenge = null;
            config.targets[0] = stat.cp;
            config.target_count = 1;
            var output: [8192]u8 = undefined;
            _ = owner.preview(&output, config) catch {
                view.message = "This target needs a matching preset or corpus.";
                return .none;
            };
            return .{ .drill = config };
        }
    }
    const transitions: dvui.Rect = if (wide)
        .{ .x = chart_w + 20, .y = 332, .w = width - (chart_w + 20), .h = 510 }
    else
        .{ .x = 0, .y = 822, .w = width, .h = 510 };
    try drawTransitions(stat.cp, analysis, transitions, theme);
    if (analysis.transitions_truncated) {
        const note_y: f32 = if (wide) 864 else 1348;
        const note = "Transition list limited to 256 pairs. Raw events remain available.";
        const note_height = presentation.flowText(note, 0, note_y, width, 13, theme.muted);
        status_y.* = @max(status_y.*, note_y + note_height + 20);
    }
    return .none;
}

fn drawCharacterMetrics(stat: results.Stat, value: analysis_model.Quantiles, width: f32, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    const card_w = (width - 32) / 3;
    const median = if (value.count == 0) "—" else try std.fmt.allocPrint(arena, "{d:.0} ms", .{milliseconds(value.median_us)});
    const samples = try std.fmt.allocPrint(arena, "Median · {d} samples{s}", .{ value.count, if (value.count < 5) " · limited" else "" });
    presentation.metric("Clean interval", median, samples, .{ .y = 190, .w = card_w, .h = 116 }, theme);
    const success = try std.fmt.allocPrint(arena, "{d:.1}%", .{100 - stat.rate()});
    const misses = try std.fmt.allocPrint(arena, "{d} missed / {d} opportunities", .{ stat.misses, stat.opportunities });
    presentation.metric("First-pass success", success, misses, .{ .x = card_w + 16, .y = 190, .w = card_w, .h = 116 }, theme);
    const tail = if (value.count == 0) "—" else try std.fmt.allocPrint(arena, "{d:.0} ms", .{milliseconds(value.p95_us)});
    const tail_bounds: dvui.Rect = .{ .x = 2 * (card_w + 16), .y = 190, .w = card_w, .h = 116 };
    presentation.metric("Slow tail", tail, "95th percentile · clean intervals", tail_bounds, theme);
}

/// Per-run median intervals for one character, with the personal reference as a line.
fn intervalChart(
    data: *const desktop.practice_progress.Summary,
    cp: u21,
    value: analysis_model.Quantiles,
    baseline: ?u64,
    chart_w: f32,
    theme: ui.Theme,
) void {
    const points = data.points[0..data.count];
    var ymax: f64 = @max(100, milliseconds(value.p95_us) * 1.1);
    for (points) |point| for (point.characters[0..point.count]) |character| if (character.cp == cp) {
        ymax = @max(ymax, milliseconds(character.median_us) * 1.1);
    };
    var xaxis: dvui.PlotWidget.Axis = .{
        .name = "Matching runs · oldest to newest",
        .min = -0.2,
        .max = @floatFromInt(@max(1, data.count)),
    };
    var yaxis: dvui.PlotWidget.Axis = .{ .name = "Median interval (ms)", .min = 0, .max = ymax };
    const plot = dvui.plot(@src(), .{ .x_axis = &xaxis, .y_axis = &yaxis, .mouse_hover = true }, .{
        .rect = .{ .x = 12, .y = 390, .w = chart_w - 24, .h = 230 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
    });
    defer plot.deinit();
    if (baseline) |target| {
        var line = plot.line();
        line.point(0, milliseconds(target));
        line.point(xaxis.max.?, milliseconds(target));
        line.stroke(1, theme.muted);
        line.deinit();
    }
    for (points, 0..) |point, index| for (point.characters[0..point.count]) |character| {
        if (character.cp != cp or character.samples == 0) continue;
        plot.bar(.{
            .x = @floatFromInt(data.count - index - 1),
            .y = milliseconds(character.median_us),
            .w = 0.15,
            .h = ymax / 100,
            .color = ui.color(0x69BFA3),
        });
    };
}

/// The eight slowest clean transitions into `cp`.
fn drawTransitions(cp: u21, analysis: anytype, panel: dvui.Rect, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    const x = panel.x + 20;
    const w = panel.w - 40;
    presentation.surface(panel, theme.panel);
    presentation.label("Difficult transitions", .{ .x = x, .y = panel.y + 16, .w = w, .h = 30 }, 19, theme.text, null);
    _ = presentation.flowText("Into this character · clean intervals", x, panel.y + 56, w, 13, theme.muted);
    var transitions = analysis.transitions;
    std.mem.sort(analysis_model.Transition, transitions[0..analysis.transition_count], {}, struct {
        fn less(_: void, a: analysis_model.Transition, b: analysis_model.Transition) bool {
            return a.timing.median_us > b.timing.median_us;
        }
    }.less);
    var row: usize = 0;
    for (transitions[0..analysis.transition_count]) |transition| {
        if (transition.to != cp or row == 8) continue;
        var from: [4]u8 = undefined;
        var to: [4]u8 = undefined;
        const row_y = panel.y + 102 + @as(f32, @floatFromInt(row)) * 48;
        const pair = try std.fmt.allocPrint(arena, "{s} -> {s}    {d:.0} ms", .{
            glyph(transition.from, &from),
            glyph(transition.to, &to),
            milliseconds(transition.timing.median_us),
        });
        presentation.label(pair, .{ .x = x, .y = row_y, .w = w, .h = 24 }, 16, theme.text, null);
        const detail = try std.fmt.allocPrint(arena, "p95 {d:.0} ms · {d} samples{s}", .{
            milliseconds(transition.timing.p95_us),
            transition.timing.count,
            if (transition.timing.count < 5) " · limited" else "",
        });
        presentation.label(detail, .{ .x = x, .y = row_y + 24, .w = w, .h = 20 }, 12, theme.muted, null);
        row += 1;
    }
    if (row == 0) _ = presentation.flowText("No clean transition samples yet.", x, panel.y + 102, w, 15, theme.muted);
}

fn drawEvents(view: *View, analysis: anytype, payload: anytype, width: f32, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    rhythmChart(analysis, width, theme);
    presentation.surface(.{ .y = 534, .w = width, .h = 640 }, theme.panel);
    presentation.label("Raw events", .{ .x = 20, .y = 548, .w = width - 40, .h = 30 }, 20, theme.text, null);
    const pages = @max(1, (payload.events.len + events_per_page - 1) / events_per_page);
    view.event_page = @min(view.event_page, pages - 1);
    const previous: dvui.Rect = .{ .x = 20, .y = 594, .w = 120, .h = 34 };
    if (ui.button(theme, "Previous", "practice.events.previous", previous) and view.event_page > 0) view.event_page -= 1;
    const next: dvui.Rect = .{ .x = 152, .y = 594, .w = 120, .h = 34 };
    if (ui.button(theme, "Next", "practice.events.next", next)) view.event_page = (view.event_page + 1) % pages;
    const page_label = try std.fmt.allocPrint(arena, "Page {d}/{d} · excluded attempts retained", .{ view.event_page + 1, pages });
    presentation.label(page_label, .{ .x = 292, .y = 594, .w = width - 312, .h = 34 }, 13, theme.muted, null);
    const start = view.event_page * events_per_page;
    for (payload.events[start..@min(payload.events.len, start + events_per_page)], start..) |event, number| {
        const text = try std.fmt.allocPrint(arena, "#{d}   {d:.3}s   {t}   pos {d}   {t}", .{
            number,
            seconds(event.active_us),
            event.kind,
            event.position,
            event.eligibility,
        });
        const tag = try std.fmt.allocPrint(arena, "practice.event.{d}", .{number});
        const row: dvui.Rect = .{ .x = 20, .y = 648 + @as(f32, @floatFromInt(number - start)) * 38, .w = width - 40, .h = 32 };
        if (presentation.rowButton(theme, text, tag, row, 15)) view.event = number;
    }
    if (payload.events.len > 0) {
        view.event = @min(view.event, payload.events.len - 1);
        try drawEventDetail(view.event, payload, width, theme);
    }
}

/// Mean clean intervals over active time, with error, correction, pause and hint markers.
fn rhythmChart(analysis: anytype, width: f32, theme: ui.Theme) void {
    presentation.surface(.{ .y = 190, .w = width, .h = 320 }, theme.panel);
    presentation.label("Run rhythm", .{ .x = 20, .y = 204, .w = width - 40, .h = 30 }, 20, theme.text, null);
    var ymax: f64 = 100;
    for (analysis.rhythm) |bucket| ymax = @max(ymax, bucket.mean_ms * 1.1);
    var xaxis: dvui.PlotWidget.Axis = .{ .name = "Active time (seconds)", .min = 0, .max = @max(1, seconds(analysis.active_us)) };
    var yaxis: dvui.PlotWidget.Axis = .{ .name = "Mean clean interval (ms)", .min = 0, .max = ymax };
    const plot = dvui.plot(@src(), .{ .x_axis = &xaxis, .y_axis = &yaxis, .mouse_hover = true }, .{
        .rect = .{ .x = 12, .y = 250, .w = width - 24, .h = 210 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
    });
    const marker_colors = [_]u24{ 0xE47777, 0xE4B553, 0xAAAAAA, 0x70BF99 };
    for (analysis.rhythm, 0..) |bucket, index| {
        const x = @as(f64, @floatFromInt(index)) * xaxis.max.? / 64;
        const bar_w = xaxis.max.? / 128;
        if (bucket.count > 0) plot.bar(.{ .x = x, .y = bucket.mean_ms, .w = bar_w, .h = ymax / 100, .color = ui.color(0x548FF5) });
        const markers = [_]usize{ bucket.errors, bucket.corrections, bucket.pauses, bucket.hints };
        for (markers, marker_colors, 0..) |count, marker_color, kind| if (count > 0) plot.bar(.{
            .x = x,
            .y = @as(f64, @floatFromInt(kind + 1)) * ymax / 30,
            .w = bar_w,
            .h = ymax / 100,
            .color = ui.color(marker_color),
        });
    }
    plot.deinit();
    const legend = "Blue: timing · red: errors · amber: corrections · gray: pauses · green: hints";
    _ = presentation.flowText(legend, 20, 478, width - 40, 13, theme.muted);
}

/// The selected event with five characters of reference context on either side.
fn drawEventDetail(selected: usize, payload: anytype, width: f32, theme: ui.Theme) !void {
    const arena = dvui.currentWindow().arena();
    const event = payload.events[selected];
    var context: std.Io.Writer.Allocating = .init(arena);
    const pos: usize = @min(event.position, payload.reference.len);
    for (payload.reference[pos -| 5..@min(payload.reference.len, pos + 6)], pos -| 5..) |cp, index| {
        var bytes: [4]u8 = undefined;
        const current = index == pos;
        try context.writer.print("{s}{s}{s}", .{
            if (current) "[" else "",
            if (cp == ' ' and !current) " " else glyph(cp, &bytes),
            if (current) "]" else "",
        });
    }
    presentation.surface(.{ .y = 1196, .w = width, .h = 200 }, theme.panel);
    var typed: [4]u8 = undefined;
    const heading = try std.fmt.allocPrint(arena, "#{d}: {s} · typed {s}", .{
        selected,
        context.written(),
        if (event.typed) |cp| glyph(cp, &typed) else "—",
    });
    const h = presentation.flowText(heading, 20, 1214, width - 40, 17, theme.text);
    const interval = if (event.interval_us) |us| try std.fmt.allocPrint(arena, "{d:.3} ms", .{milliseconds(us)}) else "excluded";
    const cue = if (!payload.cue_tracking) "unknown" else if (event.cue_visible) "shown" else "not shown";
    const detail = try std.fmt.allocPrint(
        arena,
        "{t} clock {d}µs · {d:.3}s elapsed · {t} input · batch {d} · cue {s} · correct {any} · interval {s}",
        .{ event.clock, event.observed_us, seconds(event.elapsed_us), event.input, event.batch, cue, event.correct, interval },
    );
    _ = presentation.flowText(detail, 20, 1230 + h, width - 40, 13, theme.muted);
}

fn drawProvenance(
    selected: ?u21,
    record: *const results.Record,
    analysis: anytype,
    width: f32,
    status_y: *f32,
    theme: ui.Theme,
) !void {
    const arena = dvui.currentWindow().arena();
    presentation.surface(.{ .y = 190, .w = width, .h = 160 }, theme.panel);
    presentation.label("Physical execution is unavailable", .{ .x = 24, .y = 210, .w = width - 48, .h = 30 }, 20, theme.text, null);
    const caveat = "Text events cannot prove the layer, modifier or finger you used. " ++
        "Frozen routes describe possible ways to produce a character.";
    _ = presentation.flowText(caveat, 24, 260, width - 48, 16, theme.muted);
    presentation.surface(.{ .y = 374, .w = width, .h = 470 }, theme.panel);
    presentation.label("Timing provenance", .{ .x = 24, .y = 392, .w = width - 48, .h = 30 }, 20, theme.text, null);
    const clocks = try std.fmt.allocPrint(arena, "{d} native · {d} frame · {d} injected events", .{
        analysis.clocks[@backingInt(timing.Clock.native_event)],
        analysis.clocks[@backingInt(timing.Clock.frame)],
        analysis.clocks[@backingInt(timing.Clock.injected)],
    });
    _ = presentation.flowText(clocks, 24, 438, width - 48, 14, theme.muted);
    for (analysis.eligibility, 0..) |count, index| {
        const eligibility: timing.Eligibility = @fromBackingInt(@as(u4, @intCast(index)));
        const text = try std.fmt.allocPrint(arena, "{t}: {d} attempts", .{ eligibility, count });
        presentation.label(
            text,
            .{ .x = 24, .y = 478 + @as(f32, @floatFromInt(index)) * 30, .w = width - 48, .h = 26 },
            15,
            theme.text,
            null,
        );
    }
    const cp = selected orelse return;
    for (record.stats[0..record.stat_count]) |stat| if (stat.cp == cp) {
        for (stat.routes[0..stat.route_count], 0..) |route, index| {
            const text = try std.fmt.allocPrint(arena, "Possible route: layer {d} · key {d} · modifiers 0x{x}{s}", .{
                route.layer,
                route.key,
                route.modifiers,
                if (stat.routes_truncated) " · others omitted" else "",
            });
            _ = presentation.flowText(text, 0, 874 + @as(f32, @floatFromInt(index)) * 32, width, 14, theme.muted);
        }
        status_y.* = @max(status_y.*, 894 + @as(f32, @floatFromInt(stat.route_count)) * 32);
    };
}
