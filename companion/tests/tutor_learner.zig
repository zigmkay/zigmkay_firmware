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

    std.debug.print("tutor learner: {s: <28} {s: <8} {d} letters, all unlocked after {?d} of {d} rounds\n", .{
        entry.selector, typist.name, owner.learning.unlock_len, full_unlock_round, rounds,
    });
    if (typist.must_unlock_all and full_unlock_round == null) return error.FluentTypistNeverUnlockedAllLetters;
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
