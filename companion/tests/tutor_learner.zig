//! Simulated learner: a scripted typist plays whole Tutor rounds through every
//! stage on every bundled default keymap. It guards what unit tests of single
//! parts cannot: every round can be finished on a real layout, progress only
//! moves forward and what is saved is what is loaded.
//!
//! Run with `zig build test-tutor-learner`. It is not part of `zig build test`.
const std = @import("std");
const catalog = @import("catalog");
const catalog_project = @import("catalog-project");
const desktop = @import("desktop-core");
const OfflineTranslator = @import("offline-translator");

const control = desktop.practice_controller;
const lp = desktop.practice_layout_profile;
const storage = desktop.practice_storage;

/// How one simulated person types.
const Typist = struct {
    name: []const u8,
    /// Time between two key presses.
    interval_us: u64,
    /// Wrong keys per thousand characters.
    errors_per_mille: u32,
    /// Whether this typist is good enough that every letter must unlock.
    must_unlock_all: bool,
};

const typists = [_]Typist{
    .{ .name = "fluent", .interval_us = 150_000, .errors_per_mille = 5, .must_unlock_all = true },
    .{ .name = "beginner", .interval_us = 900_000, .errors_per_mille = 200, .must_unlock_all = false },
};

/// The largest share of the letters of Stages 1 and 2 one hand may type.
const max_hand_share_percent = 60;

/// Rounds per stage. Stage 2 is where letters unlock, so it gets the most.
const rounds_per_stage = [_]struct { control.Stage, usize }{
    .{ .home_row, 6 },
    .{ .all_letters, 90 },
    .{ .shift, 4 },
    .{ .punctuation_numbers, 12 },
    .{ .layers_combos, 6 },
    .{ .free_text, 3 },
};

test "a simulated learner finishes every round on every bundled keymap" {
    const t = std.testing;
    var layouts: usize = 0;
    for (catalog.entries) |entry| {
        if (catalog.defaultData(entry.selector) == null) continue;
        layouts += 1;
        for (typists) |typist| {
            learn(entry, typist) catch |err| {
                std.debug.print("tutor learner failed: {s} with the {s} typist: {t}\n", .{ entry.selector, typist.name, err });
                return err;
            };
        }
    }
    try t.expect(layouts > 0);
}

test "the same layout on two keyboards is one Tutor profile and keeps its key positions" {
    const t = std.testing;
    const Seen = struct { selector: []const u8, profile: lp.LayoutProfile };
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(t.allocator);
    for (catalog.entries) |entry| {
        if (catalog.defaultData(entry.selector) == null) continue;
        try seen.append(t.allocator, .{ .selector = entry.selector, .profile = try deriveDefault(entry) });
    }
    var shared: usize = 0;
    for (seen.items, 0..) |a, i| for (seen.items[i + 1 ..]) |b| {
        const same = std.mem.eql(u8, &a.profile.profile_hash, &b.profile.profile_hash);
        // Home-row letters decide the profile, whatever the board.
        try t.expectEqual(std.mem.eql(u8, a.profile.zone1Letters(), b.profile.zone1Letters()), same);
        if (!same) continue;
        shared += 1;
        // Switching keyboards must not look like every letter moved.
        var moved: usize = 0;
        for ("abcdefghijklmnopqrstuvwxyz") |letter| {
            const left = positionOf(&a.profile, letter) orelse continue;
            const right = positionOf(&b.profile, letter) orelse continue;
            if (!left.eql(right)) moved += 1;
        }
        std.debug.print("tutor learner: {s} and {s} share a profile ({s}), {d} letters sit elsewhere\n", .{
            a.selector, b.selector, a.profile.zone1Letters(), moved,
        });
    };
    try t.expect(shared > 0);
}

fn positionOf(profile: *const lp.LayoutProfile, letter: u8) ?lp.KeyPosition {
    for (profile.keyPositionSlice()) |position| if (position.cp == letter) return position;
    return null;
}

fn deriveDefault(entry: catalog.Entry) !lp.LayoutProfile {
    const t = std.testing;
    var board = try catalog_project.OwnedBoard.init(t.allocator, entry.selector);
    defer board.deinit();
    var defaults = try catalog_project.createDefault(t.allocator, board);
    defer defaults.deinit();
    var model = try desktop.model.Model.init(t.allocator, board.board, defaults.snapshot);
    defer model.deinit();
    var translator: OfflineTranslator = .{};
    var labels = try desktop.label_cache.buildProjectCache(t.allocator, &translator, model.document());
    defer labels.deinit();
    return desktop.practice_profile_source.derive(.{
        .geometry = entry.geometry,
        .fidelity = switch (entry.fidelity) {
            .schematic => .schematic,
            .linear => .linear,
        },
    }, &labels, model.document(), &translator, "en-US");
}

fn learn(entry: catalog.Entry, typist: Typist) !void {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const profile = try deriveDefault(entry);

    const owner = try t.allocator.create(control.Controller);
    defer t.allocator.destroy(owner);
    owner.* = control.Controller.init(@splat(1));
    _ = owner.bindProfile(profile, null);
    owner.utc_now_sec = 20_000 * 86_400;

    var random: std.Random.DefaultPrng = .init(0x7a69_6d6b ^ @as(u64, typist.errors_per_mille));
    var now: u64 = 1_000_000;
    var rounds: u32 = 0;
    var full_unlock_round: ?u32 = null;
    // Letters each hand typed in the lessons of Stages 1 and 2.
    const hands = desktop.practice_letter_order.handsOf(&profile);
    var left_letters: usize = 0;
    var right_letters: usize = 0;

    for (rounds_per_stage) |plan| {
        const stage, const count = plan;
        _ = try owner.dispatch(owner.action(.{ .set_stage = stage }), now);
        for (0..count) |_| {
            const unlocked_before = owner.learning.unlocked_count;
            _ = try owner.start();
            const session = &owner.session;
            const reference = session.reference[0..session.reference_len];
            try t.expect(reference.len > 0);
            if (stage != .free_text) for (reference) |cp| {
                if (cp == ' ' or profile.routeFor(cp) != null or profile.comboFor(cp) != null) continue;
                std.debug.print("stage {t} asks for U+{x:0>4}, which {s} cannot produce\n", .{ stage, cp, entry.selector });
                return error.UntypeableCharacter;
            };
            if (stage == .all_letters) {
                const mask = owner.learning.unlockedMask();
                for (reference) |cp| if (cp >= 'a' and cp <= 'z') {
                    if (mask & (@as(u32, 1) << @intCast(cp - 'a')) == 0) return error.LockedLetterInDrill;
                };
            }
            if (stage == .home_row or stage == .all_letters) {
                for (reference) |cp| if (cp >= 'a' and cp <= 'z') switch (hands[cp - 'a']) {
                    .left => left_letters += 1,
                    .right => right_letters += 1,
                    .neutral => {},
                };
                // The focus the strip names is the letter the lesson practises.
                if (owner.lesson_bigram == null) if (owner.lessonFocus()) |focus| {
                    var words: usize = 0;
                    var with_focus: usize = 0;
                    var it = std.mem.splitScalar(u21, reference, ' ');
                    while (it.next()) |word| {
                        if (word.len == 0) continue;
                        words += 1;
                        if (std.mem.indexOfScalar(u21, word, focus) != null) with_focus += 1;
                    }
                    if (with_focus * 2 < words) {
                        std.debug.print("stage {t} on {s}: only {d} of {d} words contain the focus {u}\n", .{ stage, entry.selector, with_focus, words, focus });
                        return error.LessonIgnoresFocus;
                    }
                };
            }

            // A finished lesson loads the next one at once.
            const generation = owner.generation;
            var presses: usize = 0;
            while (owner.generation == generation) : (presses += 1) {
                if (presses > reference.len * 8) return error.RoundCannotBeFinished;
                const wanted = reference[desktop.practice_view.focus(session)];
                const slip = random.random().uintLessThan(u32, 1000) < typist.errors_per_mille;
                const typed: u21 = if (!slip) wanted else if (wanted == 'q') 'w' else 'q';
                var bytes: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(typed, &bytes);
                now += typist.interval_us;
                _ = try owner.insertOs(true, bytes[0..len], now, false);
            }
            rounds += 1;
            try t.expect(owner.last_lesson != null);
            try t.expectEqual(desktop.practice.State.ready, session.state);
            try t.expect(owner.learning.unlocked_count >= unlocked_before);
            if (full_unlock_round == null and owner.learning.unlocked_count == owner.learning.unlock_len)
                full_unlock_round = rounds;

            try owner.persistPending(t.allocator, t.io, tmp.dir, entry.selector, "en-US");
            try t.expect(!owner.needs_persist);
            owner.utc_now_sec += 3 * 3600;
            now += 2_000_000;
        }
    }

    // What was saved is what a fresh start loads.
    var loaded = try storage.loadState(t.allocator, t.io, tmp.dir, profile.profile_hash);
    defer loaded.deinit();
    try t.expect(loaded.existed);
    try t.expectEqual(rounds, loaded.state.total_rounds);
    try t.expectEqual(owner.learning.unlocked_count, @as(usize, loaded.state.unlocked_count));
    var runs = try storage.loadRuns(t.allocator, t.io, tmp.dir, profile.profile_hash);
    defer runs.deinit();
    try t.expectEqual(@as(usize, rounds), runs.runs.len);

    const resumed = try t.allocator.create(control.Controller);
    defer t.allocator.destroy(resumed);
    resumed.* = control.Controller.init(@splat(1));
    try t.expectEqual(@as(usize, 0), resumed.bindProfile(profile, loaded.state));
    try t.expectEqual(owner.learning.unlockedMask(), resumed.learning.unlockedMask());

    const lm = &owner.learning;
    const typed = left_letters + right_letters;
    std.debug.print("tutor learner: {s: <28} {s: <8} {d} letters ({s} first, then {s}), all unlocked after {?d} of {d} rounds, left hand {d}%\n", .{
        entry.selector,
        typist.name,
        lm.unlock_len,
        lm.firstLetters(),
        lm.unlock_order[lm.firstLetters().len..lm.unlock_len],
        full_unlock_round,
        rounds,
        if (typed > 0) left_letters * 100 / typed else 0,
    });
    if (typist.must_unlock_all and full_unlock_round == null) return error.FluentTypistNeverUnlockedAllLetters;
    // Neither hand types much more than the other.
    if (typed > 0 and @max(left_letters, right_letters) * 100 > typed * max_hand_share_percent) {
        std.debug.print("{s}: left hand {d}, right hand {d} letters\n", .{ entry.selector, left_letters, right_letters });
        return error.OneHandTypesMost;
    }
}

/// One bundled keyboard with its default layout, as the Tutor sees it.
const Keyboard = struct {
    selector: []const u8,
    profile: lp.LayoutProfile,
    labels: desktop.label_cache.LabelCache,

    fn init(entry: catalog.Entry) !Keyboard {
        const t = std.testing;
        var board = try catalog_project.OwnedBoard.init(t.allocator, entry.selector);
        defer board.deinit();
        var defaults = try catalog_project.createDefault(t.allocator, board);
        defer defaults.deinit();
        var model = try desktop.model.Model.init(t.allocator, board.board, defaults.snapshot);
        defer model.deinit();
        var translator: OfflineTranslator = .{};
        var labels = try desktop.label_cache.buildProjectCache(t.allocator, &translator, model.document());
        errdefer labels.deinit();
        const profile = try desktop.practice_profile_source.derive(.{
            .geometry = entry.geometry,
            .fidelity = switch (entry.fidelity) {
                .schematic => .schematic,
                .linear => .linear,
            },
        }, &labels, model.document(), &translator, "en-US");
        return .{ .selector = entry.selector, .profile = profile, .labels = labels };
    }

    fn deinit(self: *Keyboard) void {
        self.labels.deinit();
    }

    fn input(self: *const Keyboard) control.Controller.BoardInput {
        return .{ .id = self.selector, .labels = self.labels.practiceLabels() };
    }
};

/// Types `count` rounds of `stage` as the fluent typist.
fn playRounds(owner: *control.Controller, stage: control.Stage, count: usize, now: *u64) !void {
    _ = try owner.dispatch(owner.action(.{ .set_stage = stage }), now.*);
    for (0..count) |_| {
        try owner.start();
        const session = &owner.session;
        // A finished lesson loads the next one at once.
        const generation = owner.generation;
        var presses: usize = 0;
        while (owner.generation == generation) : (presses += 1) {
            if (presses > session.reference_len * 2) return error.RoundCannotBeFinished;
            const wanted = session.reference[desktop.practice_view.focus(session)];
            var bytes: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(wanted, &bytes);
            now.* += typists[0].interval_us;
            try owner.insertOs(true, bytes[0..len], now.*, false);
        }
        now.* += 2_000_000;
    }
}

fn expectSameStats(expected: []const desktop.practice_model.KeyStat, owner: *const control.Controller) !void {
    for (expected) |st| {
        const now = owner.learning.getStat(st.cp) orelse return error.StatisticLost;
        try std.testing.expectEqual(st, now);
    }
}

test "alternating between two keyboards of one profile loses nothing" {
    const t = std.testing;
    var entries: std.ArrayList(catalog.Entry) = .empty;
    defer entries.deinit(t.allocator);
    for (catalog.entries) |entry| {
        if (catalog.defaultData(entry.selector) != null) try entries.append(t.allocator, entry);
    }
    var pairs: usize = 0;
    for (entries.items, 0..) |entry_a, i| for (entries.items[i + 1 ..]) |entry_b| {
        var a = try Keyboard.init(entry_a);
        defer a.deinit();
        var b = try Keyboard.init(entry_b);
        defer b.deinit();
        if (!std.mem.eql(u8, &a.profile.profile_hash, &b.profile.profile_hash)) continue;
        pairs += 1;
        for ([_]bool{ false, true }) |reset| alternate(&a, &b, reset) catch |err| {
            std.debug.print("tutor learner: alternating {s} and {s} failed: {t}\n", .{ a.selector, b.selector, err });
            return err;
        };
    };
    try t.expect(pairs > 0);
}

fn alternate(a: *const Keyboard, b: *const Keyboard, reset: bool) !void {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try t.allocator.create(control.Controller);
    defer t.allocator.destroy(owner);
    owner.* = control.Controller.init(@splat(1));
    try t.expectEqual(@as(usize, 0), owner.bindProfile(a.profile, null));
    owner.adoptBoard(a.input());
    var now: u64 = 1_000_000;
    try playRounds(owner, .all_letters, 8, &now);
    try playRounds(owner, .punctuation_numbers, 4, &now);
    try owner.persistPending(t.allocator, t.io, tmp.dir, a.selector, "en-US");
    const practised = owner.learning.stats;
    const stat_len = owner.learning.stat_len;
    const unlocked = owner.learning.unlocked_count;

    // Switching keyboards resets nothing; it asks about exactly the practised
    // characters that sit elsewhere, and remembers where they were.
    owner.adoptLayout(b.profile, b.input());
    try expectSameStats(practised[0..stat_len], owner);
    var expected: usize = 0;
    for (b.profile.keyPositionSlice()) |pos| {
        if (!owner.learning.hasData(pos.cp)) continue;
        const old = positionOf(&a.profile, @intCast(pos.cp)) orelse continue;
        if (!old.eql(pos)) expected += 1;
    }
    try t.expectEqual(expected, owner.reviewSlice().len);
    for (owner.reviewSlice()) |cp| {
        const seen = owner.learning.lastKnownPosition(cp).?.seen orelse return error.MissingSeenKeys;
        try t.expectEqual(desktop.practice_model.boardHash(a.selector), seen.board);
        try t.expect(owner.boards.find(seen.board) != null);
    }
    const moved = owner.reviewSlice().len;

    if (reset) {
        var request: control.KeyReset = .{ .profile_hash = owner.profile.profile_hash };
        for (owner.reviewSlice()) |cp| request.add(cp);
        try owner.dispatch(owner.action(.{ .resolve_layout_changes = request }), now);
        for (practised[0..stat_len]) |st| {
            const was_moved = std.mem.indexOfScalar(u21, request.slice(), st.cp) != null;
            if (was_moved) {
                try t.expect(!owner.learning.hasData(st.cp));
            } else if (std.ascii.isAlphabetic(@intCast(@min(st.cp, 127))) and request.len > 0) {
                // The other case of a reset letter starts over as well.
                const other = if (st.cp < 'a') st.cp + 32 else st.cp - 32;
                if (std.mem.indexOfScalar(u21, request.slice(), other) == null)
                    try t.expectEqual(st, owner.learning.getStat(st.cp).?);
            } else {
                try t.expectEqual(st, owner.learning.getStat(st.cp).?);
            }
        }
        try t.expectEqual(unlocked, owner.learning.unlocked_count);
        return;
    }

    try owner.dispatch(owner.action(.{ .keep_moved_keys = owner.profile.profile_hash }), now);
    try t.expectEqual(@as(usize, 0), owner.reviewSlice().len);
    try owner.persistPending(t.allocator, t.io, tmp.dir, b.selector, "en-US");

    // Back and forth, live and after a restart: nothing is asked again.
    for (0..3) |round| {
        const next = if (round % 2 == 0) a else b;
        owner.adoptLayout(next.profile, next.input());
        try t.expectEqual(@as(usize, 0), owner.reviewSlice().len);
        try expectSameStats(practised[0..stat_len], owner);
        try owner.persistPending(t.allocator, t.io, tmp.dir, next.selector, "en-US");

        var loaded = try storage.loadState(t.allocator, t.io, tmp.dir, next.profile.profile_hash);
        defer loaded.deinit();
        const resumed = try t.allocator.create(control.Controller);
        defer t.allocator.destroy(resumed);
        resumed.* = control.Controller.init(@splat(1));
        try t.expectEqual(@as(usize, 0), resumed.bindProfile(next.profile, loaded.state));
        resumed.adoptBoard(next.input());
        try t.expectEqual(@as(usize, 0), resumed.reviewSlice().len);
        try expectSameStats(practised[0..stat_len], resumed);
    }
    std.debug.print("tutor learner: {s} and {s} alternate without losing progress, {d} practised characters sit elsewhere\n", .{
        a.selector, b.selector, moved,
    });
}

test "tap/hold decisions of a home-row Shift keyboard survive saving and loading" {
    const t = std.testing;
    var exercised: usize = 0;
    for (catalog.entries) |entry| {
        if (catalog.defaultData(entry.selector) == null) continue;
        const profile = try deriveDefault(entry);
        const home_row_shift = for (profile.shiftSlice()) |provider| {
            if (provider.kind == .home_row_hold) break true;
        } else false;
        if (!home_row_shift) continue;
        exercised += 1;
        tapHolds(entry, &profile) catch |err| {
            std.debug.print("tutor learner tap/hold failed on {s}: {t}\n", .{ entry.selector, err });
            return err;
        };
    }
    try t.expect(exercised > 0);
}

/// A Stage 3 lesson typed without mistakes, with the keyboard reporting a
/// Shift hold for each capital, now and then a missed Shift, and now and
/// then a home-row letter rolled into its hold.
fn tapHolds(entry: catalog.Entry, profile: *const lp.LayoutProfile) !void {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try t.allocator.create(control.Controller);
    defer t.allocator.destroy(owner);
    owner.* = control.Controller.init(@splat(1));
    _ = owner.bindProfile(profile.*, null);
    var now: u64 = 1_000_000;
    _ = try owner.dispatch(owner.action(.{ .set_stage = .shift }), now);
    try owner.start();
    const session = &owner.session;
    const reference = session.reference[0..session.reference_len];
    const generation = owner.generation;
    var step: usize = 0;
    var accidental: usize = 0;
    while (owner.generation == generation) : (step += 1) {
        if (step > reference.len) return error.RoundCannotBeFinished;
        const at = desktop.practice_view.focus(session);
        const wanted = reference[at];
        if (profile.routeFor(wanted)) |route| {
            const provider = for (profile.shiftSlice()) |p| {
                if (p.key_index == route.key_index and p.kind == .home_row_hold) break p;
            } else null;
            if (route.modifiers & 0x22 != 0 and route.kind == .shifted) {
                if (profile.preferredShiftFor(route.key_index)) |shift| if (shift.kind == .home_row_hold) {
                    const missed = step % 5 == 0;
                    const class = owner.observeTapHold(.{
                        .key_index = shift.key_index,
                        .outcome = if (missed) .tap else .hold,
                        .reason = if (missed) .released_within_term else .permissive_hold,
                        .elapsed_ms = if (missed) 70 else 120,
                        .other_key = if (missed) null else route.key_index,
                        .tapping_term_ms = 200,
                    });
                    try t.expectEqual(@as(?desktop.practice_model.TapHoldClass, if (missed) .accidental_tap else .wanted_hold), class);
                    if (missed) accidental += 1;
                };
            } else if (provider != null and route.kind == .base) {
                if (step % 3 == 0) {
                    // Rolled into the hold: Shift fired instead of the letter.
                    try t.expectEqual(@as(?desktop.practice_model.TapHoldClass, .accidental_hold), owner.observeTapHold(.{
                        .key_index = route.key_index,
                        .outcome = .hold,
                        .reason = .permissive_hold,
                        .elapsed_ms = 95,
                        .tapping_term_ms = 200,
                    }));
                    accidental += 1;
                }
                // The letter itself, typed again after a roll.
                try t.expectEqual(@as(?desktop.practice_model.TapHoldClass, .wanted_tap), owner.observeTapHold(.{
                    .key_index = route.key_index,
                    .outcome = .tap,
                    .reason = .released_within_term,
                    .elapsed_ms = 80,
                    .tapping_term_ms = 200,
                }));
            }
        }
        var bytes: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(wanted, &bytes);
        now += 200_000;
        _ = try owner.insertOs(true, bytes[0..len], now, false);
    }
    try t.expect(owner.learning.tap_hold_len > 0);
    const lesson = owner.last_lesson.?.tap_holds;
    try t.expectEqual(accidental, @as(usize, lesson.accidental_holds) + lesson.accidental_taps);
    // Typing without mistakes stays a perfect lesson.
    try t.expectApproxEqAbs(@as(f32, 100), owner.last_lesson.?.accuracy, 0.01);

    try owner.persistPending(t.allocator, t.io, tmp.dir, entry.selector, "en-US");
    var loaded = try storage.loadState(t.allocator, t.io, tmp.dir, profile.profile_hash);
    defer loaded.deinit();
    const resumed = try t.allocator.create(control.Controller);
    defer t.allocator.destroy(resumed);
    resumed.* = control.Controller.init(@splat(1));
    _ = resumed.bindProfile(profile.*, loaded.state);
    try t.expectEqual(owner.learning.tap_hold_len, resumed.learning.tap_hold_len);
    for (owner.learning.tapHoldSlice(), resumed.learning.tapHoldSlice()) |before, after| try t.expectEqualDeep(before, after);
    var runs = try storage.loadRuns(t.allocator, t.io, tmp.dir, profile.profile_hash);
    defer runs.deinit();
    try t.expectEqual(lesson.decisions, runs.runs[0].tap_hold_decisions);
}

test "a letter that slows down after it turned green comes back as refresh lessons and unlocking goes on" {
    const t = std.testing;
    var layouts: usize = 0;
    for (catalog.entries) |entry| {
        if (catalog.defaultData(entry.selector) == null) continue;
        layouts += 1;
        refreshSlipped(entry) catch |err| {
            std.debug.print("tutor learner refresh failed on {s}: {t}\n", .{ entry.selector, err });
            return err;
        };
    }
    try t.expect(layouts > 0);
}

/// The fluent typist types one first letter slowly once it is green.
fn refreshSlipped(entry: catalog.Entry) !void {
    const t = std.testing;
    const profile = try deriveDefault(entry);
    const owner = try t.allocator.create(control.Controller);
    defer t.allocator.destroy(owner);
    owner.* = control.Controller.init(@splat(1));
    _ = owner.bindProfile(profile, null);
    owner.utc_now_sec = 20_000 * 86_400;
    const slow = owner.learning.firstLetters()[1];
    _ = try owner.dispatch(owner.action(.{ .set_stage = .all_letters }), 0);

    var now: u64 = 1_000_000;
    var refreshes: usize = 0;
    var last_refresh: ?usize = null;
    var full_unlock: ?usize = null;
    for (0..100) |round| {
        try owner.start();
        if (owner.lesson_refresh) |ch| {
            if (ch != slow) return error.RefreshedAnotherLetter;
            if (last_refresh) |last| if (round - last < control.refresh_every) return error.RefreshTooOften;
            last_refresh = round;
            refreshes += 1;
            const reference = owner.session.reference[0..owner.session.reference_len];
            var it = std.mem.splitScalar(u21, reference, ' ');
            while (it.next()) |word| if (std.mem.indexOfScalar(u21, word, slow) == null) return error.RefreshWordWithoutLetter;
        }
        const slowed = owner.learning.isGreen(slow);
        const session = &owner.session;
        const generation = owner.generation;
        var presses: usize = 0;
        while (owner.generation == generation) : (presses += 1) {
            if (presses > session.reference_len * 2) return error.RoundCannotBeFinished;
            const wanted = session.reference[desktop.practice_view.focus(session)];
            var bytes: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(wanted, &bytes);
            now += if (slowed and wanted == slow) 1_200_000 else typists[0].interval_us;
            try owner.insertOs(true, bytes[0..len], now, false);
        }
        now += 2_000_000;
        // Sticky mastery: it stays green and unlocked.
        if (slowed and (!owner.learning.isGreen(slow) or !owner.learning.isUnlocked(slow))) return error.SlippedLetterLocked;
        if (full_unlock == null and owner.learning.unlocked_count == owner.learning.unlock_len) full_unlock = round + 1;
    }
    if (refreshes == 0) return error.NoRefreshLesson;
    if (full_unlock == null) return error.UnlockingStopped;
    std.debug.print("tutor learner: {s: <28} slow {c}: {d} refresh lessons in 100, all unlocked after {?d}\n", .{ entry.selector, slow, refreshes, full_unlock });
}

test "words with weak letters turn up more often, and every word keeps the focus" {
    const t = std.testing;
    var layouts: usize = 0;
    var plain_total: usize = 0;
    var weighted_total: usize = 0;
    for (catalog.entries) |entry| {
        if (catalog.defaultData(entry.selector) == null) continue;
        layouts += 1;
        const share = weakLetterShare(entry) catch |err| {
            std.debug.print("tutor learner weighting failed on {s}: {t}\n", .{ entry.selector, err });
            return err;
        };
        plain_total += share[0];
        weighted_total += share[1];
    }
    try t.expect(layouts > 0);
    try t.expect(weighted_total * 10 > plain_total * 13);
}

/// Words per thousand that contain a slipped letter, without and with the
/// weighting, over the same 40 seeds.
fn weakLetterShare(entry: catalog.Entry) ![2]usize {
    const t = std.testing;
    const profile = try deriveDefault(entry);
    const owner = try t.allocator.create(control.Controller);
    defer t.allocator.destroy(owner);
    owner.* = control.Controller.init(@splat(1));
    _ = owner.bindProfile(profile, null);
    _ = try owner.dispatch(owner.action(.{ .set_stage = .all_letters }), 0);
    const lm = &owner.learning;
    lm.unlocked_count = @min(14, lm.unlock_len);
    const active = lm.activeLetters();
    const focus = active[active.len - 1];
    for (active) |ch| {
        const st = lm.getOrAddStat(ch).?;
        st.* = .{ .cp = ch, .ema_ms = 300, .samples = 90, .acc_initialized = true, .mastered = true, .best_ms = 280 };
        st.recordOutcomes(0x3fff_ffff, 30);
    }
    lm.getOrAddStat(focus).?.* = .{ .cp = focus, .ema_ms = 700, .samples = 14, .acc_initialized = true };
    lm.focus_cp = focus;
    const weak = active[2];
    lm.getOrAddStat(weak).?.ema_ms = 1000;
    if (owner.slipOf(weak) == null) return error.LetterDidNotSlip;

    const hands = desktop.practice_letter_order.handsOf(&profile);
    var per_mille: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |on, i| {
        _ = try owner.dispatch(owner.action(.{ .set_refresh_slipped = on }), 0);
        owner.seed = 0x5eed;
        var words: usize = 0;
        var with_weak: usize = 0;
        var left: usize = 0;
        var right: usize = 0;
        for (0..40) |_| {
            owner.lessons_since_refresh = 0;
            try owner.start();
            if (owner.lesson_refresh != null or owner.lesson_bigram != null) return error.UnexpectedSpecialLesson;
            if (owner.lessonFocus() != focus) return error.FocusMoved;
            var it = std.mem.splitScalar(u21, owner.session.reference[0..owner.session.reference_len], ' ');
            while (it.next()) |word| {
                if (word.len == 0) continue;
                words += 1;
                if (std.mem.indexOfScalar(u21, word, focus) == null) return error.WordWithoutFocus;
                if (std.mem.indexOfScalar(u21, word, weak) != null) with_weak += 1;
                for (word) |cp| if (cp >= 'a' and cp <= 'z') switch (hands[cp - 'a']) {
                    .left => left += 1,
                    .right => right += 1,
                    .neutral => {},
                };
            }
        }
        if (@max(left, right) * 100 > (left + right) * max_hand_share_percent) return error.OneHandTypesMost;
        per_mille[i] = with_weak * 1000 / @max(words, 1);
    }
    std.debug.print("tutor learner: {s: <28} words with slipped {c} (focus {c}): {d}.{d}% -> {d}.{d}%\n", .{
        entry.selector, weak, focus, per_mille[0] / 10, per_mille[0] % 10, per_mille[1] / 10, per_mille[1] % 10,
    });
    if (per_mille[1] < per_mille[0]) return error.WeightingMadeWeakLetterRarer;
    return per_mille;
}
