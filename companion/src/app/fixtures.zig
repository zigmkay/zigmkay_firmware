//! Frame scripts and checks of the offline fixture modes. Fixtures inject SDL
//! events and verify native window state; none of them opens a device.
const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const boards = @import("catalog-project");
const project = @import("project");
const keyboard_onboarding = @import("onboarding-ui");
const editor = @import("editor-frame-ui");
const App = @import("App.zig");
const Tutor = @import("Tutor.zig");
const source_refresh_fixture = @import("source_refresh_fixture.zig");

const c = Backend.c;
const overlay_flags = c.SDL_WINDOW_BORDERLESS | c.SDL_WINDOW_ALWAYS_ON_TOP | c.SDL_WINDOW_NOT_FOCUSABLE;

pub const State = struct {
    /// The companion fixture's unsaved draft, which must survive hiding.
    retained: ?[32]u8 = null,
    build_checked: bool = false,
    /// The layout notice the tutor gallery shows; fixtures have no keyboard.
    layout_notice: @import("practice-ui").LayoutNotice = .none,
    /// Whether the gallery's pretend keyboard reports tap/hold decisions.
    tap_hold_support: desktop.practice_controller.TapHoldSupport = .unknown,
    /// The content scale a gallery scene renders at instead of the fitted
    /// one, as on a Retina display or with the editor zoomed.
    content_scale: ?f32 = null,
};

/// Scripts that replace the project or the onboarding stage before a frame.
pub fn beforeFrame(app: *App) !void {
    if (app.mode.is(.catalog)) try showCatalogEntry(app);
    if (app.mode.isOnboarding()) try advanceOnboarding(app);
    // The native gallery draws each page twice in the dark, then twice in the light theme.
    if (app.mode.is(.native_onboarding)) app.view.toolbar.light = app.count % 4 >= 2;
    if (app.mode.isDrawers()) try showDrawer(app);
    if (app.mode.isTutorGallery()) try showTutor(app);
}

/// The tutor gallery renders 31 scenes for 4 frames each (2 Dark + 2 Light):
/// 0: Active Stage 2 · All letters (with populated confidences & focus key)
/// 1: Stage 3 · Shift & capitals (opposite-hand Shift hold + tap bridge)
/// 2: Stage 5 · Layers & combos (layer auto-preview / 2-key combo arc)
/// 3: Next lesson right after a finished one (last lesson, notices, heatmap)
/// 4: Stages sheet (6-stage learning path)
/// 5: Progress sheet (KPI cards, WPM trend chart, weakest keys)
/// 6: Test layout: the captured field with several lines and a selection
/// 7: Settings popover
/// 8: Notice that no keyboard is verified for the layout (Stage 2)
/// 9: Notice that the editor holds unflashed changes (Test layout)
/// 10: Stage 1 · Home row
/// 11: Stage 4 · Punctuation & numbers
/// 12: Stage 6 · Free text
/// 13: Paused round with the Resume banner
/// 14: Narrow viewport responsive audit (960x640, Stage 2 active)
/// 15: Test layout with the keyboard's latest tap/hold decisions (a roll made A Shift)
/// 16: Next lesson after one where A became Shift: notice, chip marker, hover card, heatmap
/// 17: Progress sheet scrolled to its Tap/hold keys section
/// 18: Question about practised characters a keyboard switch moved
/// 19: Layout changes sheet comparing a layer character on both keyboards
/// 20: Layout changes sheet with a combo letter marked for reset
/// 21: Reset characters sheet asking for confirmation
/// 22: Test layout after Esc: the field let go of the keys
/// 23: Narrow Test layout (960x660) with the captured field
/// 24: New profile dialog naming a second person (P2)
/// 25: Person menu with two people and their progress (P1)
/// 26: Refresh lesson for a slipped green letter, with the hover card of another (R)
/// 27: Progress sheet resized larger, its body filling it down to the tap/hold keys
/// 28: Scene 27 at content scale 2 (2560x1600), as on a Retina display
/// 29: Test layout's empty captured field with its placeholder at content scale 2
/// 30: Progress sheet scrolled to its Tap/hold keys at content scale 1.25 (1600x1000)
fn showTutor(app: *App) !void {
    app.view.toolbar.light = app.count % 4 >= 2;
    const is_scene_start = (app.count == 1) or (app.count >= 4 and app.count % 4 == 0);
    if (!is_scene_start) return;
    const practice = &app.tutor.controller;
    const now: u64 = @intCast(@max(0, app.native.nanoTime()) / 1000);
    const scene = app.count / 4;

    app.tutor.view.sheet = .none;
    app.tutor.view.settings_open = false;
    app.tutor.view.confirm_reset = false;
    app.fixture.layout_notice = .none;
    app.fixture.tap_hold_support = .unknown;
    app.tutor.view.forced_tooltip = null;
    app.tutor.view.focus_tap_hold = false;
    app.tutor.view.progress_scroll = .{};
    app.tutor.view.test_field = .{};
    app.tutor.view.people.close();
    app.fixture.content_scale = switch (scene) {
        28, 29 => 2,
        30 => 1.25,
        else => null,
    };
    // Notices belong to the scene that finishes a lesson.
    practice.event_len = 0;

    // Seed realistic learning progress & synthetic history once profile is bound (frame 1).
    if (scene == 0) {
        try seedTutorGalleryState(app);
    }

    switch (scene) {
        0, 7, 8, 13, 14 => {
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            try typeSessionPrefix(&practice.session, @min(36, practice.session.reference_len / 2), now, true);
            if (scene == 7) app.tutor.view.settings_open = true;
            if (scene == 8) app.fixture.layout_notice = .unverified;
            if (scene == 13) practice.pause(now);
        },
        10, 11, 12 => {
            const stage: desktop.practice_controller.Stage = switch (scene) {
                10 => .home_row,
                11 => .punctuation_numbers,
                else => .free_text,
            };
            try practice.choose(.{ .mode = .tutor, .stage = stage, .guidance = .guided }, now);
            try practice.start();
            try typeSessionPrefix(&practice.session, @min(18, practice.session.reference_len / 2), now, false);
        },
        1 => {
            try practice.choose(.{ .mode = .tutor, .stage = .shift, .guidance = .guided }, now);
            try practice.start();
            // Advance until the focus character is an uppercase letter so Shift guidance is active.
            const target = findFirstUppercase(&practice.session) orelse @min(10, practice.session.reference_len / 2);
            try typeSessionPrefix(&practice.session, target, now, false);
        },
        2 => {
            try practice.choose(.{
                .mode = .tutor,
                .stage = .layers_combos,
                .stage5_filter = .mixed,
                .guidance = .guided,
            }, now);
            try practice.start();
            const target = findFirstLayerOrCombo(practice) orelse findFirstNonAlpha(&practice.session) orelse @min(12, practice.session.reference_len / 2);
            try typeSessionPrefix(&practice.session, target, now, false);
        },
        3 => {
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            try typeSessionPrefix(&practice.session, practice.session.reference_len, now, false);
            try practice.finish(now);
            // Show the notices of an unlock next to the new lesson.
            if (practice.last_lesson) |*lesson| {
                lesson.wpm = 41.2;
                lesson.prev_wpm = 38.4;
                lesson.wpm_delta = 2.8;
                lesson.accuracy = 97.6;
                lesson.newly_unlocked = 'p';
            }
            practice.event_len = 0;
            practice.events[0] = .{ .new_letter = 'p' };
            practice.events[1] = .{ .green = 'c' };
            practice.event_len = 2;
            practice.events_at_us = now;
        },
        4 => {
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            app.tutor.view.sheet = .stages;
        },
        5 => {
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            practice.persisted.streak_days = 5;
            practice.persisted.daily_active_seconds = 420;
            app.tutor.view.sheet = .progress;
        },
        18, 19, 20, 21 => {
            if (scene == 18) try seedMovedKeys(app);
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            const view = &app.tutor.view;
            var groups: [desktop.practice_model.max_tracked_keys]u21 = undefined;
            var len: usize = 0;
            for (practice.reviewSlice()) |cp| {
                const group = if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
                if (std.mem.indexOfScalar(u21, groups[0..len], group) == null) {
                    groups[len] = group;
                    len += 1;
                }
            }
            if (len == 0) return error.FixtureHasNoMovedKeys;
            switch (scene) {
                19, 20 => {
                    view.sheet = .layout_changes;
                    view.picks = .{};
                    view.picks.selected = groups[if (scene == 20) len - 1 else 0];
                    if (scene == 20) view.picks.set(groups[len - 1], true);
                },
                21 => {
                    view.sheet = .reset_keys;
                    view.picks = .{};
                    for (groups[0..len]) |group| view.picks.set(group, true);
                    view.picks.set(practice.learning.focus_cp orelse 'e', true);
                    view.picks.confirm = true;
                },
                else => {},
            }
        },
        15 => {
            try practice.choose(.{ .mode = .test_keys }, now);
            practice.test_keys.field.setText("Testing my layout an");
            practice.test_keys.setLastText("N");
            app.fixture.tap_hold_support = .reporting;
            const p = &practice.profile;
            const space = p.space_key orelse keyOf(p, ' ') orelse 0;
            const decisions = [_]desktop.practice_tap_hold.Decision{
                .{ .key_index = keyOf(p, 't') orelse 0, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 96, .tapping_term_ms = 200 },
                .{ .key_index = keyOf(p, 's') orelse 0, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 171, .tapping_term_ms = 200 },
                .{ .key_index = space, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 74, .tapping_term_ms = 200 },
                .{ .key_index = keyOf(p, 'a') orelse 0, .outcome = .hold, .reason = .permissive_hold, .elapsed_ms = 143, .other_key = keyOf(p, 'n'), .tapping_term_ms = 200 },
            };
            practice.test_keys.tap_hold_len = 0;
            for (decisions) |decision| _ = practice.observeTestTapHold(decision, now);
        },
        16 => {
            seedTapHoldStats(practice);
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            try typeSessionPrefix(&practice.session, practice.session.reference_len, now, false);
            try practice.finish(now);
            // The next lesson should not start on A, whose guidance would
            // cover its heatmap mark.
            var retries: usize = 0;
            while (practice.session.reference[0] == 'a' and retries < 8) : (retries += 1) try practice.start();
            if (practice.last_lesson) |*lesson| {
                lesson.wpm = 26.0;
                lesson.prev_wpm = 24.6;
                lesson.wpm_delta = 1.4;
                lesson.accuracy = 96.8;
                lesson.tap_hold_keys[0] = .{ .cp = 'a', .accidental_holds = 3, .rolls = 3 };
                lesson.tap_hold_key_len = 1;
                lesson.tap_holds = .{ .decisions = 41, .accidental_holds = 3, .near_holds = 2 };
            }
            practice.event_len = 0;
            practice.events[0] = .{ .tap_hold = .{ .cp = 'a', .count = 3, .hold = true, .reason = .permissive_hold } };
            practice.events[1] = .{ .green = 't' };
            practice.event_len = 2;
            practice.events_at_us = now;
            app.tutor.view.forced_tooltip = 'a';
        },
        17, 30 => {
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            app.tutor.view.sheet = .progress;
            app.tutor.view.focus_tap_hold = true;
            if (app.tutor.loaded_runs) |loaded| {
                const runs: []desktop.practice_storage.RunRecord = @constCast(loaded.runs);
                runs[runs.len - 1].top_accidental_hold = .{ 'a', 2 };
                runs[runs.len - 3].top_accidental_hold = .{ 'a', 1 };
                runs[runs.len - 3].top_accidental_tap = .{ 'o', 1 };
            }
        },
        9 => {
            app.fixture.layout_notice = .editor_changed;
            try practice.choose(.{ .mode = .test_keys }, now);
            practice.test_keys.field.setText("Testing my Keycaprio layout — layers, holds & combos feel crisp!");
            practice.test_keys.setLastText("!");
        },
        6, 22, 23 => {
            try practice.choose(.{ .mode = .test_keys }, now);
            try showTestField(practice, &app.tutor.view, scene == 22);
        },
        29 => {
            try practice.choose(.{ .mode = .test_keys }, now);
            practice.test_keys.tap_hold_len = 0;
            practice.test_keys.field.setText("");
        },
        24 => {
            // Scene 18's moved characters keep their statistics from here on.
            if (practice.reviewSlice().len > 0) try practice.keepMovedKeys(practice.profile.profile_hash);
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            const people = &app.tutor.view.people;
            people.dialog = .create;
            people.dialog_frames = 0;
            people.name = @splat(0);
            @memcpy(people.name[0..4], "Lisa");
            people.colour = 1;
        },
        25 => {
            try seedSecondPerson(app);
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            try practice.start();
            try typeSessionPrefix(&practice.session, @min(12, practice.session.reference_len / 2), now, false);
            app.tutor.view.people.menu_open = true;
        },
        26 => {
            const hover = seedSlippedLetters(practice);
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            practice.lessons_since_refresh = desktop.practice_controller.refresh_every - 1;
            try practice.start();
            if (practice.lesson_refresh == null) return error.FixtureHasNoRefreshLesson;
            app.tutor.view.forced_tooltip = hover;
        },
        27, 28 => {
            try practice.choose(.{ .mode = .tutor, .stage = .all_letters, .guidance = .guided }, now);
            practice.lessons_since_refresh = 0;
            try practice.start();
            app.tutor.view.sheet = .progress;
            // As if the user dragged it out to the whole window; the sheet
            // keeps itself inside the window.
            app.tutor.view.sheet_rect = .{ .x = 8, .y = 8, .w = 10_000, .h = 10_000 };
            app.tutor.view.sheet_rect_of = .progress;
        },
        else => {},
    }
}

/// Test layout's field with a few lines of Zig, "target" selected by ⌥⇧→
/// (Ctrl+Shift+Right off macOS), or let go by Esc.
fn showTestField(practice: *desktop.practice_controller.Controller, view: *@import("practice-ui").View, released: bool) !void {
    const scratchpad = desktop.practice_scratchpad;
    const source =
        \\const std = @import("std");
        \\const layers = .{ .base, .nav, .sym };
        \\
        \\fn moveCursor(line: usize) usize {
        \\    const target = line + 1;
        \\    return target;
        \\}
        \\
        \\test moveCursor {
        \\    try std.testing.expectEqual(2, moveCursor(1));
        \\}
    ;
    practice.test_keys.tap_hold_len = 0;
    const field = &practice.test_keys.field;
    field.setText(source);
    const start = std.mem.indexOf(u8, source, "target").?;
    const platform = scratchpad.Platform.native();
    var buffer: [48]u8 = undefined;
    if (released) {
        field.select(start + "target".len, start + "target".len);
        view.test_field = .{ .captured = false, .capture_on_show = false };
        practice.test_keys.setLastKey(scratchpad.comboText(&buffer, .{ .code = .escape }, "", platform), "");
    } else {
        field.select(start, start + "target".len);
        const key: scratchpad.Key = .{ .code = .right, .mods = if (platform == .mac)
            .{ .alt = true, .shift = true }
        else
            .{ .control = true, .shift = true } };
        const command = scratchpad.commandFor(key, platform) orelse return error.FixtureKeyUnmapped;
        practice.test_keys.setLastKey(scratchpad.comboText(&buffer, key, "", platform), command.label());
    }
}

/// The key that types `cp` on tap in the bound profile.
fn keyOf(profile: *const desktop.practice_layout_profile.LayoutProfile, cp: u21) ?usize {
    for (profile.base_taps[0..profile.key_count], 0..) |tap, index| if (tap == cp) return index;
    return null;
}

/// Tap/hold windows as a Zigmkay keyboard reports them over many lessons:
/// A (home-row Shift) rolls into the next key, S (Alt) is held past the
/// term often enough for a suggestion, O (Shift) sometimes taps when a
/// capital needs it, Space and E are clean.
fn seedTapHoldStats(practice: *desktop.practice_controller.Controller) void {
    const lm = &practice.learning;
    lm.tap_hold_len = 0;
    const tap: desktop.practice_model.TapHoldSample = .{ .class = .wanted_tap, .reason = .released_within_term, .elapsed_ms = 92, .tapping_term_ms = 200 };
    var near = tap;
    near.class = .near_hold;
    near.elapsed_ms = 164;
    const roll: desktop.practice_model.TapHoldSample = .{ .class = .accidental_hold, .reason = .permissive_hold, .elapsed_ms = 138, .tapping_term_ms = 200, .other_cp = 'n' };
    const held: desktop.practice_model.TapHoldSample = .{ .class = .accidental_hold, .reason = .term_elapsed, .elapsed_ms = 214, .tapping_term_ms = 200 };
    const plan = [_]struct { cp: u21, sample: desktop.practice_model.TapHoldSample, count: usize }{
        .{ .cp = 'a', .sample = tap, .count = 58 },
        .{ .cp = 'a', .sample = near, .count = 2 },
        .{ .cp = 'a', .sample = roll, .count = 1 },
        .{ .cp = 'a', .sample = tap, .count = 6 },
        .{ .cp = 'a', .sample = near, .count = 3 },
        .{ .cp = 'a', .sample = roll, .count = 2 },
        .{ .cp = 'a', .sample = tap, .count = 8 },
        .{ .cp = 's', .sample = tap, .count = 52 },
        .{ .cp = 's', .sample = near, .count = 2 },
        .{ .cp = 's', .sample = held, .count = 1 },
        .{ .cp = 's', .sample = tap, .count = 5 },
        .{ .cp = ' ', .sample = tap, .count = 70 },
        .{ .cp = ' ', .sample = near, .count = 1 },
        .{ .cp = 'e', .sample = tap, .count = 44 },
        .{ .cp = 'o', .sample = tap, .count = 6 },
        .{ .cp = 'o', .sample = .{ .class = .wanted_hold, .reason = .permissive_hold, .elapsed_ms = 120, .tapping_term_ms = 200 }, .count = 2 },
        .{ .cp = 'o', .sample = .{ .class = .accidental_tap, .reason = .released_within_term, .elapsed_ms = 88, .tapping_term_ms = 200 }, .count = 2 },
    };
    for (plan) |step| for (0..step.count) |_| lm.recordTapHold(step.cp, step.sample);
}

fn seedTutorGalleryState(app: *App) !void {
    const practice = &app.tutor.controller;
    // The gallery practises as Conny; scene 25 adds Lisa.
    const tutor = &app.tutor;
    tutor.people = .{};
    tutor.people.current = try tutor.people.add("Conny", 0, 0);
    tutor.people_ready = true;
    tutor.fixture_summaries = @splat(null);
    const lm = &practice.learning;
    lm.unlocked_count = @min(14, lm.unlock_len);
    lm.stat_len = lm.unlocked_count;
    for (0..lm.unlocked_count) |i| {
        const ch = lm.unlock_order[i];
        if (i + 1 < lm.unlocked_count) {
            lm.stats[i] = .{
                .cp = ch,
                .samples = 45,
                .ema_ms = if (i < 11) 250.0 + @as(f32, @floatFromInt(i * 6)) else 390.0 + @as(f32, @floatFromInt((i - 11) * 18)),
                .ema_acc = 0.975,
                .acc_initialized = true,
            };
        } else {
            // Focus key actively being trained (~62% confidence)
            lm.stats[i] = .{
                .cp = ch,
                .samples = 24,
                .ema_ms = 510.0,
                .ema_acc = 0.96,
                .acc_initialized = true,
            };
            lm.focus_cp = ch;
        }
    }
    lm.total_rounds = 14;
    lm.bigrams[0] = .{ .prev = 't', .cur = 'h', .ema_ms = 390.0, .samples = 14 };
    lm.bigrams[1] = .{ .prev = 'n', .cur = 'e', .ema_ms = 345.0, .samples = 12 };
    lm.bigram_len = 2;
    // Today's practice, so a finished lesson adds to it.
    if (practice.utc_now_sec > 0) practice.persisted.daily_utc_day = @intCast(practice.utc_now_sec / 86_400);
    practice.persisted.daily_active_seconds = 420;
    practice.persisted.streak_days = 5;
    practice.persisted.total_rounds = 14;
    practice.persisted.unlocked_count = @intCast(lm.unlocked_count);

    // Populate synthetic runs.jsonl history in memory for the Progress sheet WPM chart.
    if (app.tutor.loaded_runs) |*old| old.deinit();
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const runs = try a.alloc(desktop.practice_storage.RunRecord, 14);
    // The app sets the clock every frame; the lessons end just before it.
    const now_sec: u64 = if (practice.utc_now_sec > 0) practice.utc_now_sec else 1_763_704_290;
    const wpms = [_]f32{ 24.5, 26.0, 25.2, 28.4, 30.1, 29.5, 32.0, 34.2, 33.8, 36.1, 37.5, 39.0, 38.4, 41.2 };
    const accs = [_]f32{ 94.2, 95.1, 95.8, 96.0, 96.5, 95.9, 97.0, 97.2, 96.8, 97.4, 97.9, 98.1, 97.5, 98.2 };
    for (runs, 0..) |*r, i| {
        r.* = .{
            .utc_timestamp = now_sec -| (runs.len - i) * 75,
            .stage = if (i < 4) 1 else 2,
            .wpm = wpms[i],
            .accuracy = accs[i],
            .active_seconds = 34.0,
            .unlocked_char = if (i == 6) 'p' else if (i == 11) 'l' else null,
            .weak_spot = if (i == 9 or i == 4) .{ 't', 'h' } else null,
            .newly_green = if (i == 12) &.{ 'd', 'c' } else if (i == 13) &.{'h'} else &.{},
            .top_weak_keys = if (i >= 10) &.{ 'c', 'l', 'm' } else &.{},
        };
    }
    app.tutor.loaded_runs = .{ .arena = arena, .runs = runs, .skipped_lines = 0 };
}

/// Lets the gallery's practised characters come from the Clackychan, where Z
/// is a combo and symbols sit on layers, so the Keycaprio shown now asks
/// about the ones that moved.
fn seedMovedKeys(app: *App) !void {
    const practice = &app.tutor.controller;
    const current = practice.profile;
    const current_id = app.tutor.bound_board_id[0..app.tutor.bound_board_id_len];
    var board = try boards.OwnedBoard.init(app.gpa, "clackychan_colemak");
    defer board.deinit();
    var defaults = try boards.createDefault(app.gpa, board);
    defer defaults.deinit();
    var other = try desktop.model.Model.init(app.gpa, board.board, defaults.snapshot);
    defer other.deinit();
    var labels = try desktop.label_cache.buildProjectCache(app.gpa, &app.translator, other.document());
    defer labels.deinit();
    const before = try Tutor.deriveLayoutProfile(app, &board, &labels, other.document(), "offline");

    // Practised symbols beside the letters the gallery seeds.
    for ("zZ/;?") |ch| {
        const st = practice.learning.getOrAddStat(ch) orelse continue;
        st.* = .{ .cp = ch, .samples = 32, .ema_ms = 330.0, .ema_acc = 0.97, .acc_initialized = true };
    }
    practice.learning.known_len = 0;
    practice.adoptLayout(before, .{ .id = "clackychan_colemak", .labels = labels.practiceLabels() });
    practice.adoptLayout(current, .{ .id = current_id, .labels = app.captions.labels.practiceLabels() });
}

fn typeSessionPrefix(session: *desktop.practice.Session, count: usize, now: u64, with_mistake: bool) !void {
    const start = now -| 3_000_000 -| 180_000 * count;
    for (session.reference[0..count], 0..) |cp, index| {
        const at = start + 180_000 * index;
        if (with_mistake and index + 6 == count) {
            // Trigger one stop-on-error mistake and then recover with the correct char.
            const wrong: []const u8 = if (cp == 'z') "q" else "z";
            try session.insert(wrong, at, false);
        }
        var bytes: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &bytes);
        try session.insert(bytes[0..len], at, false);
    }
}

fn findFirstUppercase(session: *const desktop.practice.Session) ?usize {
    for (session.reference[0..session.reference_len], 0..) |cp, i| {
        if (i >= 6 and cp >= 'A' and cp <= 'Z') return i;
    }
    return null;
}

fn findFirstLayerOrCombo(practice: *const desktop.practice_controller.Controller) ?usize {
    if (!practice.profile_bound) return null;
    for (practice.session.reference[0..practice.session.reference_len], 0..) |cp, i| {
        if (i < 4) continue;
        if (practice.profile.routeFor(cp)) |route| {
            if (route.combo_key_index != null or route.layer > 0) return i;
        }
    }
    return null;
}

fn findFirstNonAlpha(session: *const desktop.practice.Session) ?usize {
    for (session.reference[0..session.reference_len], 0..) |cp, i| {
        if (i >= 4 and cp > ' ' and !((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z'))) return i;
    }
    return null;
}

/// The drawers fixture shows the combo, callback and encoder drawers, each in
/// the dark and then the light theme for four frames. Combos and callbacks use
/// the Keycaprio 0.7 default; encoders use the first board with encoder slots.
/// A replaced project closes popups, so drawers open one frame after it.
fn showDrawer(app: *App) !void {
    const scene = app.count / 4;
    if (scene >= 6 or scene % 2 == 1) {
        if (app.count % 4 == 0) app.view.toolbar.light = scene % 2 == 1;
        return;
    }
    if (app.count % 4 == 0) {
        app.view.toolbar.light = false;
        var selector: []const u8 = "keycaprio_colemak_0_7";
        if (scene == 4) for (desktop.onboarding.catalog.entries) |entry| if (entry.encoder_action_slots > 0) {
            selector = entry.selector;
            break;
        };
        var selected = try boards.OwnedBoard.init(app.gpa, selector);
        defer selected.deinit();
        var template = try boards.createDefault(app.gpa, selected);
        defer template.deinit();
        var replacement = try desktop.model.Model.init(app.gpa, selected.board, template.snapshot);
        std.mem.swap(desktop.model.Model, &app.model, &replacement);
        replacement.deinit();
        app.owner_generation += 1;
        return;
    }
    if (app.count % 4 != 1) return;
    const view = &app.view;
    switch (scene) {
        0 => {
            // Opening selects the first combo, as the Combos segment does.
            view.combo = try desktop.combo_editor.Session.init(&app.model);
            view.modal = .combo;
        },
        2 => view.modal = .callback,
        else => {
            view.encoders = try desktop.encoder_editor.Session.init(&app.model);
            // One staged, unapplied slot edit.
            if (view.encoders.?.count > 1) view.encoders.?.drafts[1] = .{ .media_key = .VolumeUp };
            view.modal = .encoders;
        },
    }
}

/// Shows each catalog board for four frames, the last two in the tutor.
fn showCatalogEntry(app: *App) !void {
    const entries = desktop.onboarding.catalog.entries;
    if (app.count % 4 == 0 and app.count / 4 < entries.len) {
        var selected = try boards.OwnedBoard.init(app.gpa, entries[app.count / 4].selector);
        defer selected.deinit();
        var template = try boards.createDefault(app.gpa, selected);
        defer template.deinit();
        var replacement = try desktop.model.Model.init(app.gpa, selected.board, template.snapshot);
        std.mem.swap(desktop.model.Model, &app.model, &replacement);
        replacement.deinit();
        app.owner_generation += 1;
    }
    app.practicing = app.count % 4 >= 2;
}

/// The onboarding gallery shows each page for four frames: the first launch,
/// My Keyboards with sample layouts, the catalog, New layout, the import source
/// and the import comparison. Sample layouts exist only in memory.
fn advanceOnboarding(app: *App) !void {
    const onboarding = &app.onboarding;
    switch (app.count) {
        4 => {
            onboarding.replaceLibrary(try sampleLibrary(app));
            onboarding.stage = .home;
        },
        8 => {
            onboarding.stage = .catalog;
            onboarding.catalog = .{ .family = 1, .confirmed = true };
        },
        12 => {
            onboarding.openNewLayout(entryOf("lk7"));
            onboarding.new_layout.template = 3;
        },
        16 => {
            onboarding.clearImport();
            onboarding.stage = .source;
        },
        20 => {
            // A Keycaprio 0.7 keymap, as an analysis would return it, compared
            // with a Keycaprio 0.4 that has four keys fewer.
            const defaults = desktop.onboarding.catalog.defaultData("keycaprio_colemak_0_7").?;
            onboarding.analysis = .{ .arena = .init(app.gpa), .captured = @splat(1), .data = .{
                .layers = defaults.layers,
                .combos = defaults.combos,
                .sides = defaults.sides,
                .encoders = defaults.encoder_actions orelse &.{},
                .has_callbacks = defaults.has_callbacks,
            } };
            onboarding.sample_sources = defaults.callback_sources;
            onboarding.selector = entryOf("keycaprio_colemak_0_4");
            try keyboard_onboarding.State.set(&onboarding.location, "https://github.com/example/keycaprio-keymap");
            try keyboard_onboarding.State.set(&onboarding.name, "Colemak Jan (imported)");
        },
        else => {},
    }
}

/// Layouts on three keyboards, one of them outside the collection.
fn sampleLibrary(app: *App) !desktop.library.Library {
    const gpa = app.gpa;
    var eurmac = try project.profiles.create(gpa, .eurmac);
    defer eurmac.deinit();
    var danish = try project.profiles.create(gpa, .danish);
    defer danish.deinit();
    var eurkey = try project.profiles.create(gpa, .eurkey);
    defer eurkey.deinit();
    var molekula_board = try boards.OwnedBoard.init(gpa, "molekula");
    defer molekula_board.deinit();
    var molekula = try boards.createDefault(gpa, molekula_board);
    defer molekula.deinit();
    var keycaprio_board = try boards.OwnedBoard.init(gpa, "keycaprio_colemak_0_4");
    defer keycaprio_board.deinit();
    var keycaprio = try boards.createDefault(gpa, keycaprio_board);
    defer keycaprio.deinit();
    const now = std.Io.Timestamp.now(app.io, .real).nanoseconds;
    const minute = 60 * std.time.ns_per_s;
    var renamed = eurmac.snapshot.document;
    renamed.name = "EurKEY Next Mac";
    var jan = keycaprio.snapshot.document;
    jan.name = "Colemak Jan";
    return desktop.library.fromSamples(gpa, &.{
        .{ .path = "/collection/keyboards/eurmac", .member = "keyboards/eurmac", .document = renamed, .modified = now - 2 * minute },
        .{ .path = "/collection/keyboards/rollercole", .member = "keyboards/rollercole", .document = danish.snapshot.document, .modified = now - 8 * 24 * 60 * minute },
        .{ .path = "/data/projects/eurkey", .document = eurkey.snapshot.document, .modified = now - 21 * 24 * 60 * minute },
        .{ .path = "/collection/keyboards/jan", .member = "keyboards/jan", .document = jan, .modified = now - 26 * 60 * minute },
        .{ .path = "/collection/keyboards/molekula", .member = "keyboards/molekula", .document = molekula.snapshot.document, .modified = now - 3 * 24 * 60 * minute },
    });
}

/// Once the managed startup build finished, verifies it. The frame loop then
/// stops.
pub fn checkBuild(app: *App) !void {
    if (!app.mode.is(.build) or app.fixture.build_checked or app.count < 2 or app.jobs.build != null) return;
    const artifact = app.build.artifact orelse {
        std.log.err("Managed editor build failed: {s}", .{std.mem.sliceTo(&app.view.diagnostic, 0)});
        return error.ManagedEditorBuildFailed;
    };
    if (!std.mem.eql(u8, &artifact.inputs.project_digest, &(try app.model.id()))) return error.ManagedEditorBuildStale;
    app.fixture.build_checked = true;
}

/// Clicks Build on the second frame of the managed startup build fixture.
pub fn requestBuild(app: *App, can_build: bool, rendered: *editor.Result) !void {
    if (!app.mode.is(.build) or app.count != 2) return;
    if (!can_build or app.build.artifact != null or app.jobs.busy()) {
        std.log.err("Managed editor startup: paths={any} resources={any} plan={any} can_build={any} built={any} busy={any}", .{
            app.user_paths != null,
            app.build.resources != null,
            app.build.plan != null,
            can_build,
            app.build.artifact != null,
            app.jobs.busy(),
        });
        return error.ManagedEditorStartupNotIdle;
    }
    const captured = try desktop.editor_dispatch.Request.capture(&app.model, .build);
    rendered.* = .{ .effect = try app.owner.request(&app.model, captured) };
}

/// Per-frame scripts of the window lifecycle and source fixtures.
pub fn script(app: *App) !void {
    if (app.mode.is(.companion)) try companionScript(app);
    if (app.mode.is(.source_refresh)) try source_refresh_fixture.run(app);
    if (app.mode.is(.native_tray)) try nativeTrayScript(app);
}

/// Hides and reopens the editor and the companion independently, then quits
/// once with a dirty draft (cancelled) and once clean (accepted).
fn companionScript(app: *App) !void {
    const life = &app.life;
    const overlay = &app.companion;
    switch (app.count) {
        2 => {
            try app.model.rename("Retained draft");
            app.fixture.retained = try app.model.id();
            life.action(.toggle_companion);
        },
        3 => {
            if (overlay.window == null) return error.CompanionWindowMissing;
            app.events.close = true;
        },
        4 => {
            if (life.editor_visible or app.owner.closed or !life.keepRunning()) return error.ResidentEditorCloseFailed;
            life.action(.open_editor);
            life.action(.toggle_companion);
            _ = c.SDL_ShowWindow(app.native.window);
        },
        5 => {
            if (overlay.window) |id| if (c.SDL_GetWindowFromID(id)) |child| {
                if (c.SDL_GetWindowFlags(child) & c.SDL_WINDOW_HIDDEN == 0) return error.CompanionNativeHideFailed;
            };
            life.action(.toggle_companion);
            overlay.view.overlay = true;
            overlay.view.applied_window = null;
        },
        6 => {
            const id = overlay.window orelse return error.CompanionWindowMissing;
            const child = c.SDL_GetWindowFromID(id) orelse return error.CompanionWindowMissing;
            if (overlay.view.applied_window != id) return error.CompanionModeNotApplied;
            const flags = c.SDL_GetWindowFlags(child);
            if (flags & c.SDL_WINDOW_HIDDEN != 0) return error.CompanionNativeShowFailed;
            const expected: @TypeOf(flags) = if (overlay.view.overlay) overlay_flags else 0;
            if ((flags & overlay_flags) != expected) {
                std.log.err("Companion mode flags: actual={x} expected={x} overlay={any}", .{
                    flags & overlay_flags,
                    expected,
                    overlay.view.overlay,
                });
                return error.CompanionModeFlagsMismatch;
            }
            var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
            event.window.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
            event.window.windowID = id;
            try pushEvent(&event);
        },
        7 => {
            if (life.companion_visible or !life.editor_visible or app.owner.closed) return error.CompanionCloseFailed;
            app.events.quit = true;
        },
        8 => {
            if (app.owner.close_requested == null or app.owner.closed) return error.ResidentDirtyQuitNotGuarded;
            const keep = try desktop.inspector_action.Action.capture(&app.owner.inspector, &app.model, .keep_close);
            _ = try app.owner.inspect(&app.model, keep);
            life.cancelQuit();
        },
        9 => {
            if (app.owner.closed or app.owner.close_requested != null or life.quit_requested or !life.keepRunning() or
                !std.mem.eql(u8, &app.fixture.retained.?, &(try app.model.id()))) return error.ResidentDraftRetentionFailed;
            // Simulate a clean saved document; the accepted Quit then ends the loop.
            app.model.saved_id = try app.model.id();
            var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
            event.type = c.SDL_EVENT_QUIT;
            try pushEvent(&event);
        },
        else => {},
    }
}

/// Shows the companion as an overlay with a real tray and window manager.
fn nativeTrayScript(app: *App) !void {
    const overlay = &app.companion;
    if (app.count == 2) {
        app.life.companion_visible = true;
        overlay.view.overlay = true;
        overlay.view.applied_window = null;
    }
    if (app.count == 3) {
        const id = overlay.window orelse return error.CompanionWindowMissing;
        if (overlay.view.applied_window != id) return error.CompanionModeNotApplied;
        const child = c.SDL_GetWindowFromID(id) orelse return error.CompanionWindowMissing;
        const flags = c.SDL_GetWindowFlags(child);
        const expected: @TypeOf(flags) = if (overlay.view.overlay) overlay_flags else 0;
        if ((flags & overlay_flags) != expected) return error.CompanionModeFlagsMismatch;
        std.log.info("Native companion overlay supported: {any}", .{overlay.view.overlay});
    }
}

/// The status fixture shows each toolbar state for four frames. Scene 6 is the
/// plain editor with nothing open, as in the README screenshot.
pub fn statusScene(app: *const App) usize {
    return if (app.mode.isStatus()) (app.count - 1) / 4 else 0;
}

pub fn resizeStatusWindow(app: *App) void {
    if (app.mode.isDrawers() and app.count == 1) _ = c.SDL_SetWindowSize(app.native.window, 1440, 1000);
    if (app.mode.isTutorGallery()) {
        if (app.count == 1) _ = c.SDL_SetWindowSize(app.native.window, 1440, 940);
        if (app.count == 57) _ = c.SDL_SetWindowSize(app.native.window, 960, 660);
        if (app.count == 61) _ = c.SDL_SetWindowSize(app.native.window, 1440, 940);
        if (app.count == 93) _ = c.SDL_SetWindowSize(app.native.window, 960, 660);
        if (app.count == 97) _ = c.SDL_SetWindowSize(app.native.window, 1440, 940);
        if (app.count == 113) _ = c.SDL_SetWindowSize(app.native.window, 2560, 1600);
        if (app.count == 121) _ = c.SDL_SetWindowSize(app.native.window, 1600, 1000);
    }
    if (!app.mode.isStatus() or (app.count != 1 and app.count != 21 and app.count != 25)) return;
    const narrow = app.count == 21;
    _ = c.SDL_SetWindowSize(app.native.window, if (narrow) 900 else 1440, if (narrow) 600 else 1000);
}

pub fn showStatusDetails(app: *App) void {
    if (!app.mode.isStatus()) return;
    app.view.toolbar.auto_build = true;
    app.view.toolbar.details_open = statusScene(app) == 4;
    // Scene 3 shows the layout menu, opened by a click on the layout crumb.
    if (statusScene(app) != 3) app.view.toolbar.menu_open = false;
    // Scene 2 shows the Export Zig source sheet.
    app.view.modal = if (statusScene(app) == 2) .paths else .none;
    // Scene 3 shows the flash panel of a failed firmware build.
    app.flash.panel = statusScene(app) == 3;
    app.flash.failure = if (statusScene(app) == 3) error.FirmwareBuildFailed else null;
    // Scenes 0 and 1 open the key editor on F: its tap, then its hold, after
    // F gained a Shift hold.
    const scene = statusScene(app);
    if (scene == 6 and app.count % 4 == 1) @memset(app.model.selected, false);
    if (scene <= 1 and app.count % 4 == 1) {
        app.model.select(13, false);
        if (scene == 1) {
            const tap = desktop.inspector_session.tapPart(app.model.action());
            app.model.apply(.{ .tap_hold = .{
                .tap = tap,
                .hold = .{ .hold_modifiers = .{ .left_shift = true } },
                .tapping_term = .{ .ms = 200 },
            } }) catch {};
        }
    }
    app.view.key_editor.open = switch (scene) {
        0 => .tap,
        1 => .hold,
        else => null,
    };
    app.view.key_editor.layer = app.model.layer;
}

pub fn statusToolbar(app: *const App, toolbar: *@FieldType(editor.Frame, "toolbar")) void {
    if (!app.mode.isStatus()) return;
    const scene = statusScene(app);
    toolbar.can_build = true;
    toolbar.can_flash = true;
    toolbar.build_active = scene == 0;
    toolbar.first_build = scene == 0;
    toolbar.flash_active = scene == 1;
    toolbar.flash_succeeded = scene == 2;
    toolbar.flash_failed = scene >= 3 and scene != 6;
    // The fixture has no build plan; the plain editor shows the installed
    // application's idle status instead of the missing-resources notice.
    if (scene == 6) toolbar.build_status = "Ready to build and Flash";
    toolbar.flash_status = switch (scene) {
        0, 6 => "",
        1 => "Transferring firmware to keyboard…",
        2 => "Matching firmware reconnected",
        else => "Flash failed: the selected firmware could not be verified against the current project snapshot. " ++
            "Review the complete diagnostic here before starting a new transfer.",
    };
}

/// Injects the SDL events of the practice and status fixtures before the pump.
pub fn injectEvents(app: *App) !void {
    if (app.mode.is(.practice) and app.count == 3) try pushFocusLost(app);
    if (app.mode.isStatus() and app.count == 14) try clickCanvas(app, 480, 32);
}

/// Types the first reference codepoint as OS text after the pump.
pub fn injectText(app: *App) !void {
    if (!app.mode.is(.practice) or app.count != 2) return;
    var text: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(app.tutor.controller.session.reference[0], &text);
    _ = try app.window.addEventText(.{ .text = text[0..len] });
}

/// Moves the pointer to a point of the design canvas and clicks there.
fn clickCanvas(app: *App, x: f32, y: f32) !void {
    const scale = app.window.content_scale;
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.motion.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.windowID = app.events.root;
    event.motion.x = x * scale;
    event.motion.y = y * scale;
    try pushEvent(&event);
    for ([_]c_uint{ c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP }) |kind| {
        event = std.mem.zeroes(c.SDL_Event);
        event.button.type = kind;
        event.button.windowID = app.events.root;
        event.button.button = c.SDL_BUTTON_LEFT;
        event.button.down = kind == c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.clicks = 1;
        event.button.x = x * scale;
        event.button.y = y * scale;
        try pushEvent(&event);
    }
}

fn pushFocusLost(app: *App) !void {
    var lost: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    lost.window.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
    lost.window.windowID = app.events.root;
    try pushEvent(&lost);
}

fn pushEvent(event: *c.SDL_Event) !void {
    if (!c.SDL_PushEvent(event)) return error.FixtureEventRejected;
}

/// Verifies the drawn frame and saves screenshots of the screenshot fixtures.
pub fn capture(app: *App) !void {
    if (app.mode.isStatus() and app.count % 4 == 0) try captureStatus(app);
    if (app.mode.isDrawers() and app.count % 4 == 0) {
        app.window.endRendering(.{ .manage_backend = false });
        const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/editor-drawers/{d}.bmp", .{(app.count - 1) / 4}, 0);
        try screenshot(app, path, error.DrawerScreenshotRead, error.DrawerScreenshotSave);
    }
    if (app.mode.isTutorGallery() and app.count % 2 == 0) try captureTutor(app);
    if (app.mode.isOnboarding() or app.mode.is(.catalog)) try captureOnboarding(app);
}

fn captureTutor(app: *App) !void {
    if (dvui.tagGet("practice.topbar") == null) return error.TutorNotDrawn;
    const is_test_keys = app.tutor.controller.config.mode == .test_keys;
    if (is_test_keys) {
        if (dvui.tagGet("practice.test_keys.bar") == null or
            dvui.tagGet("practice.test_keys.scratchpad") == null or
            dvui.tagGet("practice.keyboard") == null) return error.TutorNotDrawn;
    } else if (dvui.tagGet("practice.word") == null or dvui.tagGet("practice.metrics") == null) {
        return error.TutorNotDrawn;
    }
    if (app.tutor.view.sheet == .stages and dvui.tagGet("practice.sheet.stages") == null) return error.TutorSheetNotDrawn;
    if (app.tutor.view.sheet == .progress and (dvui.tagGet("practice.sheet.progress") == null or dvui.tagGet("practice.chart.wpm") == null))
        return error.TutorSheetNotDrawn;
    if (app.tutor.view.sheet == .layout_changes and (dvui.tagGet("practice.sheet.layout_changes") == null or dvui.tagGet("practice.layout_changes.now") == null))
        return error.TutorSheetNotDrawn;
    if (app.tutor.view.sheet == .reset_keys and dvui.tagGet("practice.sheet.reset_keys") == null) return error.TutorSheetNotDrawn;
    app.window.endRendering(.{ .manage_backend = false });
    const scene = (app.count - 1) / 4;
    const theme = if (app.view.toolbar.light) "light" else "dark";
    const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/typing-practice-gallery/{d}-{s}.bmp", .{ scene, theme }, 0);
    try screenshot(app, path, error.TutorScreenshotRead, error.TutorScreenshotSave);
}

/// The activity row stays inside the toolbar, which spans the window.
fn captureStatus(app: *App) !void {
    const activity = dvui.tagGet("editor.activity") orelse return error.ActivityRowMissing;
    const toolbar = (dvui.tagGet("toolbar") orelse return error.ToolbarMissing).rect;
    const row = activity.rect;
    if (row.x < toolbar.x or row.x + row.w > toolbar.x + toolbar.w + 1 or row.y + row.h > toolbar.y + toolbar.h + 1)
        return error.ActivityRowOverflow;
    if (toolbar.x + toolbar.w < dvui.windowRectPixels().w - 3) {
        std.log.err("Activity bounds: toolbar={any}, window={any}, natural={any}, scale={d}", .{
            toolbar,
            dvui.windowRectPixels(),
            dvui.windowRect(),
            app.window.content_scale,
        });
        return error.ActivityToolbarGutter;
    }
    const message = dvui.tagGet("editor.activity.message") orelse return error.ActivityMessageMissing;
    const automatic = dvui.tagGet("firmware.auto_build") orelse return error.AutoBuildControlMissing;
    if (message.rect.x + message.rect.w > automatic.rect.x) return error.ActivityControlsOverlap;
    if (dvui.tagGet("system.status") != null) return error.SeparateStatusBarRetained;
    if (statusScene(app) == 3 and dvui.tagGet("layout.menu.popup") == null) return error.LayoutMenuNotDrawn;
    app.window.endRendering(.{ .manage_backend = false });
    const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/editor-status/{d}.bmp", .{statusScene(app)}, 0);
    try screenshot(app, path, error.StatusScreenshotRead, error.StatusScreenshotSave);
}

/// The wizard never exposes a target or creates its destination before commit.
fn captureOnboarding(app: *App) !void {
    const wizard = app.mode.isOnboarding();
    if (wizard) {
        if (dvui.tagGet("firmware.build") != null or dvui.tagGet("firmware.inspect") != null or app.onboarding.selected)
            return error.ImplicitOnboardingTargetExposed;
        if (app.count <= 3 and dvui.tagGet("onboarding.create") == null) return error.OnboardingControlsMissing;
        if (std.Io.Dir.cwd().statFile(app.io, std.mem.sliceTo(&app.onboarding.root, 0), .{})) |_| {
            return error.OnboardingCreatedDestinationBeforeCommit;
        } else |err| if (err != error.FileNotFound) return err;
    }
    app.window.endRendering(.{ .manage_backend = false });
    const path = try std.fmt.allocPrintSentinel(app.window.arena(), ".zig-cache/keyboard-onboarding-gallery/{s}-{d}.bmp", .{
        if (wizard) "wizard" else "catalog",
        app.count,
    }, 0);
    try screenshot(app, path, error.OnboardingScreenshotRead, error.OnboardingScreenshotSave);
}

/// Saves the rendered frame as a BMP file in the cache.
pub fn screenshot(app: *App, path: [:0]const u8, read_error: anyerror, save_error: anyerror) !void {
    try std.Io.Dir.cwd().createDirPath(app.io, std.fs.path.dirname(path).?);
    const surface = c.SDL_RenderReadPixels(app.native.renderer, null) orelse return read_error;
    defer c.SDL_DestroySurface(surface);
    if (!c.SDL_SaveBMP(surface, path)) return save_error;
}

/// Checks the outcome of the fixtures once the frame loop ended.
pub fn finish(app: *App) !void {
    const session = &app.tutor.controller.session;
    const typed_once = session.len == 1 and session.matched() == 1 and session.state == .paused;
    if (app.mode.is(.practice) and !typed_once) return error.PracticeTextRoutingFailed;
    if (app.mode.is(.build) and !app.fixture.build_checked) return error.ManagedEditorBuildIncomplete;
    if (app.mode.is(.companion)) {
        const retained = app.fixture.retained orelse return error.ResidentDraftRetentionFailed;
        if (!std.mem.eql(u8, &retained, &(try app.model.id()))) return error.ResidentDraftRetentionFailed;
        if (!app.owner.closed) return error.ResidentCleanQuitFailed;
    }
    if (app.mode.is(.native_tray) and !app.tray.installed) return error.NativeTrayLifecycleFailed;
}

fn entryOf(selector: []const u8) usize {
    for (desktop.onboarding.catalog.entries, 0..) |entry, index| if (std.mem.eql(u8, entry.selector, selector)) return index;
    unreachable;
}

/// Lisa, who practised this layout type yesterday and has seven letters.
fn seedSecondPerson(app: *App) !void {
    const tutor = &app.tutor;
    if (tutor.people.len > 1) return;
    _ = try tutor.people.add("Lisa", 1, 0);
    const today: u32 = @intCast(tutor.controller.utc_now_sec / 86_400);
    tutor.fixture_summaries[1] = .{
        .started = true,
        .unlocked = 7,
        .letters = tutor.controller.learning.unlock_len,
        .last_day = today -| 1,
        .streak_days = 1,
    };
}

/// Two green letters that slipped since they were mastered: C got slow (12
/// WPM, best 26) and is refreshed; L got slower too (15 WPM, best 27) and
/// missed 5 of its last 30.
/// Returns the letter whose hover card the scene shows.
fn seedSlippedLetters(practice: *desktop.practice_controller.Controller) u21 {
    const lm = &practice.learning;
    const active = lm.activeLetters();
    const refresh: u8 = if (lm.isUnlocked('c')) 'c' else active[@min(10, active.len - 1)];
    const hover: u8 = if (lm.isUnlocked('l')) 'l' else active[@min(12, active.len - 1)];
    const plan = [_]struct { ch: u8, wpm: f32, best: f32, misses: u5 }{
        .{ .ch = refresh, .wpm = 12, .best = 26, .misses = 3 },
        .{ .ch = hover, .wpm = 15, .best = 27, .misses = 5 },
    };
    for (plan) |p| {
        const st = lm.getOrAddStat(p.ch) orelse continue;
        st.* = .{ .cp = p.ch, .ema_ms = 12_000 / p.wpm, .samples = 96, .acc_initialized = true, .mastered = true, .mastered_samples = 40, .best_ms = 12_000 / p.best };
        st.recordOutcomes(0x3fff_ffff, 30);
        st.recordOutcomes(0, p.misses);
    }
    return hover;
}
