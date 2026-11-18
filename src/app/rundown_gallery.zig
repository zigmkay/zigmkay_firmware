//! Scripted tutor scenes of `--offline-rundown-frames` and the native
//! `--native[-layout]-<scene>-frames` screenshot galleries.
//!
//! Every scene lasts `sceneFrames` frames and starts on the first of them.
//! Scenes 1 to 10 cover the rundown itself; later scenes belong to a gallery.
const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const App = @import("App.zig");
const fixtures = @import("fixtures.zig");

const Labels = desktop.label_cache.LabelCache;
const day_ns = desktop.practice_progress.day_ns;

pub fn sceneFrames(app: *const App) usize {
    return if (app.mode.isLayoutGallery()) 6 else 2;
}

/// Sets up the scene that starts on this frame.
pub fn advance(app: *App, labels: *const Labels, now_us: u64) !void {
    if (!app.mode.isRundown()) return;
    const frames = sceneFrames(app);
    if (app.count % frames != 1) return;
    const scene = (app.count + frames - 1) / frames;
    if (scene <= 10) return rundown(app, scene, now_us);
    const gallery = app.mode.gallery() orelse return;
    switch (gallery.scene) {
        .data => try data(app, scene),
        .progress => try progress(app, scene),
        .diagnostics => try diagnostics(app, scene, labels, now_us),
        .curriculum => try curriculum(app, scene, labels, now_us),
        .help => try help(app, scene, gallery.layout, now_us),
        .rundown => if (gallery.layout) try history(app, scene, labels, now_us),
    }
}

fn rundown(app: *App, scene: usize, now_us: u64) !void {
    const practice = &app.tutor.controller;
    const view = &app.tutor.view;
    const history_data = &app.tutor.history;
    switch (scene) {
        1, 2, 5, 8, 9, 10 => view.rundown = .{},
        else => {},
    }
    switch (scene) {
        1 => {
            practice.config = .{ .preset = .mixed_case, .level = 0 };
            _ = try practice.start(true, null, now_us);
            app.view.toolbar.light = true;
        },
        2 => {
            practice.config = .{ .preset = .punctuation, .level = 1 };
            _ = try practice.start(true, null, now_us);
            const session = &practice.session;
            for (session.reference[0..session.reference_len], 0..) |cp, index| {
                const at = now_us + index * 120_000;
                if (index % 17 == 0 or cp == ';' or cp == '"') {
                    try session.insert("x", at, false);
                    session.backspace();
                }
                try insertCodepoint(session, cp, at);
            }
            view.rundown.selected = ';';
        },
        3 => {
            const record = practice.completed.?;
            for (record.stats[0..record.stat_count]) |stat| if (stat.cp == '"' and stat.route_count > 0) {
                view.rundown.layer = stat.routes[0].layer;
                view.rundown.variant = std.mem.indexOfScalar(u8, &desktop.practice.route_modifiers, stat.routes[0].modifiers) orelse 0;
            };
            view.rundown.selected = '"';
        },
        4 => app.view.toolbar.light = false,
        5 => {
            practice.config.targets = .{ 'e', 'a', 't', 0, 0 };
            practice.config.target_count = 3;
            _ = try practice.start(true, null, now_us);
        },
        6 => try typeReference(&practice.session, now_us, 120_000),
        7 => {
            view.rundown.scope = 1;
            history_data.cohort = practice.completed.?.cohort;
            history_data.data.deinit();
            history_data.data = .{};
            history_data.data.requested_id = practice.completed.?.id;
            history_data.data.contains_requested = true;
            for (0..12) |_| try history_data.data.all.add(&practice.completed.?);
            for (0..10) |_| try history_data.data.recent.add(&practice.completed.?);
        },
        8 => {
            practice.config.target_count = 0;
            practice.config.assistance = .layout_only;
            _ = try practice.start(true, null, now_us);
        },
        9 => {
            practice.config.assistance = .hidden;
            _ = try practice.start(true, null, now_us);
            try resize(app, 820, 700);
        },
        10 => {
            practice.config.assistance = .guided;
            _ = try practice.start(true, null, now_us);
            try practice.session.load("a;A", .os);
            try practice.session.insert("a;A", now_us + 1_000_000, false);
        },
        else => {},
    }
}

fn data(app: *App, scene: usize) !void {
    const view = &app.tutor.view;
    switch (scene) {
        11 => {
            view.data_open = true;
            view.rundown.refresh = true;
            try resize(app, 1440, 960);
            const path = try std.fs.path.join(app.window.arena(), &.{ app.tutor.history.path.?, "portable.sqlite3" });
            @memcpy(view.data_path[0..path.len], path);
        },
        12 => try resize(app, 820, 700),
        else => {},
    }
}

fn progress(app: *App, scene: usize) !void {
    const view = &app.tutor.view;
    const history_data = &app.tutor.history;
    switch (scene) {
        11 => {
            view.progress_open = true;
            view.progress.smoothing = true;
            const completed = app.tutor.controller.completed.?;
            history_data.cohort = completed.cohort;
            history_data.data.deinit();
            history_data.data = .{};
            history_data.data.progress_allocator = app.gpa;
            const summary = try app.gpa.create(desktop.practice_progress.Summary);
            history_data.data.progress = summary;
            summary.* = .{};
            const today = @divFloor(@as(i64, @intCast(std.Io.Clock.real.now(app.io).toNanoseconds())), day_ns);
            summary.today = today;
            for (0..40) |index| {
                var record = completed;
                record.id[0] = @intCast(index);
                const day = today - 27 + @as(i64, @intCast(index / 2));
                record.timestamp = day * day_ns + @as(i64, @intCast(index % 2)) * 3_600_000_000_000;
                record.active_us = 3_000_000 + @as(u64, @intCast(index % 7)) * 300_000;
                summary.add(&record);
                try history_data.data.all.add(&record);
            }
            try resize(app, 1440, 1050);
        },
        12, 14 => try resize(app, 820, 700),
        13 => {
            view.progress.tab = 1;
            try resize(app, 1440, 960);
        },
        15 => {
            view.progress.tab = 0;
            history_data.data.progress.?.count = 0;
        },
        16 => {
            history_data.data.progress.?.count = 1;
            try resize(app, 1440, 960);
        },
        else => {},
    }
}

fn diagnostics(app: *App, scene: usize, labels: *const Labels, now_us: u64) !void {
    const view = &app.tutor.view;
    switch (scene) {
        11 => try diagnosedRun(app, labels, now_us),
        12 => try resize(app, 820, 700),
        13 => {
            view.diagnostics.tab = 1;
            try resize(app, 1440, 1050);
        },
        14 => view.diagnostics.tab = 2,
        15 => {
            app.tutor.controller.completed.?.timing_available = false;
            view.diagnostics.tab = 0;
        },
        else => {},
    }
}

/// A run with corrections, a pause and a hint at injected times, with its
/// timing analysis and four older days of progress.
fn diagnosedRun(app: *App, labels: *const Labels, now_us: u64) !void {
    const practice = &app.tutor.controller;
    const timing = &app.tutor.timing;
    const history_data = &app.tutor.history;
    const gpa = app.gpa;
    practice.config = .{ .level = 0 };
    _ = try practice.start(true, null, now_us);
    const session = &practice.session;
    try session.load("the tree there the tree there the tree there", .os);
    timing.clock = .injected;
    var event_at: u64 = 1_000_000;
    for (session.reference[0..session.reference_len], 0..) |cp, index| {
        event_at += if (index % 11 == 0) @as(u64, 600_000) else 120_000;
        if (index % 13 == 0) {
            try session.insert("x", event_at, false);
            session.backspaceAt(event_at + 10_000);
            event_at += 30_000;
        }
        if (index == 20) {
            session.pause(event_at);
            event_at += 2_000_000;
            session.resumeRun(event_at);
        }
        if (index == 10) timing.record(.hint_shown, event_at, session.duration(event_at), session.len, null, .ordinary);
        try insertCodepoint(session, cp, event_at);
    }
    var record = try desktop.practice_results.capture(session, practice.captured_cohort, labels.practiceLabels());
    try std.Io.randomSecure(app.io, &record.id);
    record.timestamp = @intCast(std.Io.Clock.real.now(app.io).toNanoseconds());
    practice.completed = record;
    practice.completed_enqueued = true;
    app.tutor.view.diagnostics_open = true;
    app.tutor.view.rundown.selected = 'e';
    history_data.data.deinit();
    history_data.data = .{ .requested_id = record.id, .requested_record = record, .contains_requested = true, .progress_allocator = gpa };
    history_data.cohort = record.cohort;
    history_data.data.timing = try desktop.practice_timing.Owned.clone(gpa, timing.payload());
    history_data.data.analysis = try desktop.practice_analysis.analyze(gpa, timing.payload());
    const summary = try gpa.create(desktop.practice_progress.Summary);
    history_data.data.progress = summary;
    summary.* = .{};
    for (0..4) |index| {
        var older = record;
        older.id[0] = @intCast(index);
        older.timestamp -= @as(i64, @intCast(index + 1)) * day_ns;
        summary.add(&older);
    }
    for (summary.points[0..4]) |*point| try point.enrich(gpa, timing.payload());
    try resize(app, 1440, 1050);
}

fn curriculum(app: *App, scene: usize, labels: *const Labels, now_us: u64) !void {
    const practice = &app.tutor.controller;
    const view = &app.tutor.view;
    switch (scene) {
        11 => {
            view.curriculum_open = true;
            view.curriculum.config = .{ .curriculum = .{ .version = 1 } };
            const history_data = &app.tutor.history;
            history_data.cohort = practice.cohortFor(view.curriculum.config);
            history_data.data.deinit();
            history_data.data = .{};
            var alphabet: [26]u8 = undefined;
            const learned = desktop.practice_curriculum.letters(labels.practiceLabels(), &alphabet);
            var record: desktop.practice_results.Record = .{
                .cohort = history_data.cohort,
                .active_us = 60_000_000,
                .matched = 120,
                .attempts = 120,
                .correct_attempts = 120,
                .stat_count = 6,
            };
            for (learned[0..6], 0..) |cp, index| record.stats[index] = .{ .cp = cp, .opportunities = 20 };
            for (0..3) |index| {
                record.id[0] = @intCast(index);
                try history_data.data.all.add(&record);
            }
            history_data.data.latest_curriculum = record;
            try resize(app, 1440, 1050);
        },
        12 => try resize(app, 820, 700),
        13...16 => {
            const config = &view.curriculum.config.curriculum;
            config.stage = @fromBackingInt(@as(u3, @intCast(scene - 12)));
            config.family = 0;
            if (scene == 13) config.alphabet = 7;
            if (scene == 16) config.layer = 0;
            try resize(app, 1440, 1050);
        },
        17 => {
            view.curriculum_open = false;
            practice.config = .{ .level = 0, .curriculum = .{ .version = 1 } };
            _ = try practice.start(true, null, now_us);
        },
        18 => try typeReference(&practice.session, now_us, 150_000),
        else => {},
    }
}

fn help(app: *App, scene: usize, layout: bool, now_us: u64) !void {
    const practice = &app.tutor.controller;
    const view = &app.tutor.view;
    switch (scene) {
        11 => {
            practice.config = .{ .level = 0, .preset = .mixed_case, .hints = .{ .policy = .delayed, .adaptive = false } };
            _ = try practice.start(true, null, now_us);
            try practice.session.load("A calm tree appears beside a quiet river.", .os);
            view.help = .{ .generation = practice.generation, .position = 0, .last = now_us, .paused = false };
            try resize(app, 1440, 1050);
        },
        12 => view.help.waited_us = 2_000_000,
        13, 16 => try resize(app, 820, 700),
        14 => {
            view.help_open = true;
            view.help_config = practice.config;
            try resize(app, 1440, 1050);
        },
        15 => {
            view.help_open = false;
            view.review_open = true;
            try installRetention(app);
        },
        17 => {
            view.review_open = false;
            practice.config = .{ .level = 0, .preset = .mixed_case, .assistance = .hidden };
            _ = try practice.start(true, null, now_us);
            try practice.session.load("A quiet river runs beside the tree.", .os);
            view.help = .{ .generation = practice.generation, .position = 0, .last = now_us, .paused = false, .requested = true };
            try resize(app, 1440, 1050);
        },
        18 => try typeReference(&practice.session, now_us, 160_000),
        19 => {
            view.help_open = true;
            view.help_config = practice.config;
            view.help_config.hints.policy = .delayed;
            view.help_config.assistance = .guided;
            try resize(app, 900, 600);
        },
        20 => if (layout) {
            view.help_open = false;
            practice.config.assistance = .guided;
            practice.config.hints.policy = .on_request;
            _ = try practice.start(true, null, now_us);
            try resize(app, 900, 700);
        },
        21 => if (layout) {
            view.review_open = true;
            view.review.details = true;
        },
        else => {},
    }
}

/// Three letters due for review, one of them never recalled without a cue.
fn installRetention(app: *App) !void {
    const practice = &app.tutor.controller;
    const history_data = &app.tutor.history;
    history_data.data.deinit();
    history_data.data = .{ .progress_allocator = app.gpa };
    history_data.cohort = practice.configCohort();
    const summary = try app.gpa.create(desktop.practice_retention.Summary);
    history_data.data.retention = summary;
    const now: i64 = @intCast(std.Io.Clock.real.now(app.io).toNanoseconds());
    const week_ago = now - 8 * desktop.practice_retention.day_ns;
    summary.* = .{ .now = now, .eligible_runs = 12, .unknown_runs = 4, .count = 3 };
    for ([_]u21{ 'e', 'r', 'A' }, 0..) |cp, index| summary.entries[index] = .{
        .cp = cp,
        .opportunities = 80,
        .cued = 40,
        .uncued = 40,
        .last_exposure = week_ago,
        .last_recall = if (index == 2) null else week_ago,
        .recalls = if (index == 2) 0 else 2,
        .context = practice.configCohort(),
    };
}

fn history(app: *App, scene: usize, labels: *const Labels, now_us: u64) !void {
    const view = &app.tutor.view;
    switch (scene) {
        11 => try installHistory(app, labels, now_us),
        12 => {
            view.rundown.history_open = false;
            view.rundown.more_details = true;
            view.rundown.selected = 'e';
            try resize(app, 900, 700);
        },
        13 => view.rundown.confirm_clear = true,
        else => {},
    }
}

/// A finished run and five saved older runs on one history page.
fn installHistory(app: *App, labels: *const Labels, now_us: u64) !void {
    const practice = &app.tutor.controller;
    const history_data = &app.tutor.history;
    app.tutor.view.rundown = .{ .history_open = true };
    practice.config = .{ .preset = .words, .level = 0 };
    _ = try practice.start(true, null, now_us);
    try typeReference(&practice.session, now_us, 150_000);
    var current = try desktop.practice_results.capture(&practice.session, practice.captured_cohort, labels.practiceLabels());
    try std.Io.randomSecure(app.io, &current.id);
    current.timestamp = @intCast(std.Io.Clock.real.now(app.io).toNanoseconds());
    practice.completed = current;
    practice.completed_enqueued = true;
    history_data.cohort = current.cohort;
    history_data.data.deinit();
    history_data.data = .{ .progress_allocator = app.gpa, .page_count = 5 };
    history_data.data.page = try app.gpa.alloc(desktop.practice_results.Record, 10);
    @memset(history_data.data.page, .{});
    for (0..5) |index| {
        var saved = current;
        saved.id[0] ^= @intCast(index + 1);
        saved.timestamp -= @as(i64, @intCast(index + 1)) * day_ns;
        history_data.data.page[index] = saved;
        try history_data.data.all.add(&saved);
        try history_data.data.recent.add(&saved);
        history_data.data.recent_ids[index] = saved.id;
    }
    history_data.data.recent_count = 5;
    try resize(app, 1440, 1050);
}

fn resize(app: *App, width: c_int, height: c_int) !void {
    if (!Backend.c.SDL_SetWindowSize(app.native.window, width, height)) return error.PracticeFixtureResize;
}

fn insertCodepoint(session: *desktop.practice.Session, cp: u21, at: u64) !void {
    var bytes: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &bytes);
    try session.insert(bytes[0..len], at, false);
}

/// Types the whole reference correctly, one codepoint every `step_us`.
fn typeReference(session: *desktop.practice.Session, start_us: u64, step_us: u64) !void {
    for (session.reference[0..session.reference_len], 0..) |cp, index| {
        try insertCodepoint(session, cp, start_us + index * step_us);
    }
}

/// Layout galleries capture each panel at the top, then scroll it with real
/// input to show footer controls and long explanations after resizing.
pub fn scroll(app: *App, available: dvui.Size.Natural) !void {
    if (!app.mode.isLayoutGallery()) return;
    const frames = sceneFrames(app);
    const view = &app.tutor.view;
    if (app.mode.isScene(.help) and app.count == 19 * frames + 4) if (dvui.tagGet("practice.tools")) |menu| {
        _ = try app.window.addEventMouseMotion(.{ .pt = .{ .x = menu.rect.x + menu.rect.w / 2, .y = menu.rect.y + menu.rect.h / 2 } });
        _ = try app.window.addEventMouseButton(.left, .press);
        _ = try app.window.addEventMouseButton(.left, .release);
    };
    const panel_open = view.data_open or view.progress_open or view.diagnostics_open or view.curriculum_open or
        view.help_open or view.review_open or app.tutor.controller.completed != null;
    if (app.count % frames == 4 and panel_open) {
        _ = try app.window.addEventMouseMotion(.{ .pt = .{ .x = available.w * 0.75, .y = available.h * 0.65 } });
        _ = try app.window.addEventMouseWheel(-2000, .vertical, .mouse);
    }
}

/// Verifies the drawn panel and saves the scene screenshot.
pub fn capture(app: *App) !void {
    if (!app.mode.isRundown()) return;
    const view = &app.tutor.view;
    const practice = &app.tutor.controller;
    if (!view.drawn_panel) return error.PracticePanelNotDrawn;
    const expected = if (view.review_open)
        "practice.review"
    else if (view.help_open)
        "practice.help.title"
    else if (view.curriculum_open)
        "practice.curriculum"
    else if (view.diagnostics_open)
        "practice.diagnostics"
    else if (view.progress_open)
        "practice.progress"
    else if (view.data_open)
        "practice.data.title"
    else if (practice.completed != null)
        "practice.rundown"
    else
        "practice.word";
    if (dvui.tagGet(expected) == null) return error.PracticeRundownNotDrawn;
    if (practice.config.assistance == .hidden and !view.help.requested and view.drawn_keyboard) return error.HiddenPracticeKeyboardVisible;
    app.window.endRendering(.{ .manage_backend = false });
    const frames = sceneFrames(app);
    if (!app.mode.isLayoutGallery() or app.count % frames == 0 or app.count % frames == 3) {
        const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/typing-practice-gallery/{d}.bmp", .{app.count}, 0);
        try fixtures.screenshot(app, path, error.PracticeScreenshotRead, error.PracticeScreenshotSave);
    }
}
