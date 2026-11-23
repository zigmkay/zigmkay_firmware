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

fn learn(entry: catalog.Entry, typist: Typist) !void {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    var board = try catalog_project.OwnedBoard.init(t.allocator, entry.selector);
    defer board.deinit();
    var defaults = try catalog_project.createDefault(t.allocator, board);
    defer defaults.deinit();
    var model = try desktop.model.Model.init(t.allocator, board.board, defaults.snapshot);
    defer model.deinit();
    var translator: OfflineTranslator = .{};
    var labels = try desktop.label_cache.buildProjectCache(t.allocator, &translator, model.document());
    defer labels.deinit();
    const profile = try desktop.practice_profile_source.derive(.{
        .selector = entry.selector,
        .geometry = entry.geometry,
        .fidelity = switch (entry.fidelity) {
            .schematic => .schematic,
            .linear => .linear,
        },
    }, &labels, model.document(), &translator, "en-US");

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
        _ = try owner.dispatch(owner.action(.{ .set_stage = stage }), null, now);
        for (0..count) |_| {
            const unlocked_before = owner.learning.unlocked_count;
            _ = try owner.start(true, null, now);
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

            var presses: usize = 0;
            while (session.state != .complete) : (presses += 1) {
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
            try t.expect(owner.rundown != null);
            try t.expect(owner.learning.unlocked_count >= unlocked_before);
            if (full_unlock_round == null and owner.learning.unlocked_count == owner.learning.unlock_len)
                full_unlock_round = rounds;

            try owner.persistPending(t.allocator, t.io, tmp.dir, entry.selector, "en-US");
            try t.expect(!owner.needs_persist);
            owner.utc_now_sec += 3 * 3600;
            now += 2_000_000;
            _ = try owner.handleRundownContinue(null, now);
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
