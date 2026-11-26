//! Classifies the keyboard's tap/hold decisions against what the lesson
//! expects at the cursor: a home-row modifier or layer key that typed its
//! character when its hold was wanted, or held when its character was wanted.
//!
//! OS text and keyboard reports arrive on separate channels in either order,
//! so a decision is matched against a small window around the cursor: a tap
//! also against the character before it (its own text may already be in) unless
//! an earlier tap already typed it, and both against the one after it (the
//! previous character's text may still be on its way). The statistics belong
//! to the character the key types on tap.
const std = @import("std");
const practice = @import("practice.zig");
const layout_profile = @import("practice_layout_profile.zig");
pub const model = @import("practice_model.zig");
const view = @import("practice_view.zig");

pub const Outcome = enum { tap, hold, retro_tap };

/// A decision as the keyboard reported it, independent of the wire format.
pub const Decision = struct {
    key_index: usize,
    outcome: Outcome,
    reason: model.TapHoldReason,
    /// From the press to the decision.
    elapsed_ms: u16,
    /// The key whose press and release decided it, if any.
    other_key: ?usize = null,
    tapping_term_ms: u16,
    /// The layer the key was taken from.
    layer: usize = 0,
    /// The key started a combo; combos are not classified.
    combo: bool = false,
};

pub const Classified = struct {
    /// The character the key types on tap.
    cp: u21,
    sample: model.TapHoldSample,
    /// The text position a tap typed, which no later tap can type again.
    typed_at: ?usize = null,
};

const shift_bits: u8 = 0x22;

/// The class of `decision` and the character it belongs to, or null when it
/// has nothing to do with the text around the cursor. `claimed` lists text
/// positions earlier taps typed: every tap reports exactly one decision, so a
/// position is matched once.
pub fn classify(
    profile: *const layout_profile.LayoutProfile,
    session: *const practice.Session,
    decision: Decision,
    claimed: []const usize,
) ?Classified {
    if (decision.combo) return null;
    const key = decision.key_index;
    const cp = profile.tapCharFor(key, decision.layer) orelse return null;
    const at = view.focus(session);
    var typed_at: ?usize = null;
    const class: model.TapHoldClass = switch (decision.outcome) {
        .hold => for ([_]?usize{ at, at + 1 }) |index| {
            const expected = expectedAt(session, index) orelse continue;
            if (needsHold(profile, key, decision.layer, expected)) break .wanted_hold;
            if (typesWithTap(profile, key, decision.layer, cp, expected)) break .accidental_hold;
        } else return null,
        .tap, .retro_tap => blk: {
            // In order: the character at the cursor, the one before it when
            // this is its own late decision, a hold the cursor needs, and the
            // next character when the text before it is still on its way.
            const Step = struct { index: ?usize, hold: bool };
            const steps = [_]Step{
                .{ .index = at, .hold = false },
                .{ .index = if (at > 0) at - 1 else null, .hold = false },
                .{ .index = at, .hold = true },
                .{ .index = at + 1, .hold = false },
                .{ .index = at + 1, .hold = true },
            };
            for (steps) |step| {
                const index = step.index orelse continue;
                const expected = expectedAt(session, index) orelse continue;
                if (step.hold) {
                    if (decision.outcome == .tap and needsHold(profile, key, decision.layer, expected)) break :blk .accidental_tap;
                } else if (std.mem.indexOfScalar(usize, claimed, index) == null and
                    typesWithTap(profile, key, decision.layer, cp, expected))
                {
                    typed_at = index;
                    break :blk if (decision.outcome == .retro_tap or late(decision)) .near_hold else .wanted_tap;
                }
            }
            return null;
        },
    };
    return .{ .cp = cp, .typed_at = typed_at, .sample = .{
        .class = class,
        .reason = decision.reason,
        .elapsed_ms = decision.elapsed_ms,
        .tapping_term_ms = decision.tapping_term_ms,
        .other_cp = if (decision.other_key) |other|
            profile.tapCharFor(other, decision.layer) orelse profile.tapCharFor(other, 0)
        else
            null,
    } };
}

fn expectedAt(session: *const practice.Session, index: ?usize) ?u21 {
    const i = index orelse return null;
    return if (i < session.reference_len) session.reference[i] else null;
}

/// A tap decided this late in the tapping term was nearly a hold.
fn late(decision: Decision) bool {
    if (decision.tapping_term_ms == 0) return false;
    const elapsed: f32 = @floatFromInt(decision.elapsed_ms);
    return elapsed >= model.near_hold_fraction * @as(f32, @floatFromInt(decision.tapping_term_ms));
}

/// Whether tapping `key` is part of typing `expected`: it is the key's own
/// character, or the key the character's route taps.
fn typesWithTap(profile: *const layout_profile.LayoutProfile, key: usize, layer: usize, cp: u21, expected: u21) bool {
    if (cp == expected) return true;
    const route = profile.routeFor(expected) orelse return false;
    return route.kind != .combo and route.key_index == key and route.layer == layer;
}

/// Whether `expected` wants `key` held: a Shift it needs, or the layer it is on.
fn needsHold(profile: *const layout_profile.LayoutProfile, key: usize, layer: usize, expected: u21) bool {
    if (layer != 0) return false;
    const route = profile.routeFor(expected) orelse return false;
    if (route.kind == .combo or route.key_index == key) return false;
    if (route.modifiers & shift_bits != 0) {
        for (profile.shiftSlice()) |provider| {
            if (provider.key_index != key) continue;
            switch (provider.kind) {
                .home_row_hold, .thumb_hold, .hold => return true,
                .one_shot, .dedicated => {},
            }
        }
    }
    if (route.kind == .layer_tap) {
        for (profile.layerActivatorSlice()) |activator| {
            if (activator.key_index == key and activator.target_layer == route.layer and !activator.one_shot) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests: a synthetic profile with home-row Shift on f and j and a layer-tap
// Space on the left thumb that reaches a symbol layer.
// ---------------------------------------------------------------------------

/// Keys: 0 a, 1 s, 2 d, 3 f (Shift hold), 4 j (Shift hold), 5 k, 6 Space
/// (layer 1 hold), 7 a second Space; layer 1 has '{' on key 5.
pub fn testProfile() layout_profile.LayoutProfile {
    var p: layout_profile.LayoutProfile = .{ .key_count = 8, .layer_count = 2 };
    for ("asdfjk  ", 0..) |ch, i| p.base_taps[i] = ch;
    for ([_]usize{ 0, 1, 2, 3 }) |i| p.keys[i].hand = .left;
    for ([_]usize{ 4, 5 }) |i| p.keys[i].hand = .right;
    p.shifts[0] = .{ .key_index = 3, .hand = .left, .finger = .left_index, .modifier_bit = 0x02, .kind = .home_row_hold };
    p.shifts[1] = .{ .key_index = 4, .hand = .right, .finger = .right_index, .modifier_bit = 0x20, .kind = .home_row_hold };
    p.shift_len = 2;
    p.layer_activators[0] = .{ .key_index = 6, .target_layer = 1, .hand = .left, .finger = .left_thumb };
    p.layer_activator_len = 1;
    const routes = [_]layout_profile.CharRoute{
        .{ .cp = 'a', .kind = .base, .layer = 0, .key_index = 0 },
        .{ .cp = 's', .kind = .base, .layer = 0, .key_index = 1 },
        .{ .cp = 'd', .kind = .base, .layer = 0, .key_index = 2 },
        .{ .cp = 'f', .kind = .base, .layer = 0, .key_index = 3 },
        .{ .cp = 'j', .kind = .base, .layer = 0, .key_index = 4 },
        .{ .cp = 'k', .kind = .base, .layer = 0, .key_index = 5 },
        .{ .cp = ' ', .kind = .base, .layer = 0, .key_index = 6 },
        .{ .cp = 'A', .kind = .shifted, .layer = 0, .key_index = 0, .modifiers = 0x20 },
        .{ .cp = 'F', .kind = .shifted, .layer = 0, .key_index = 3, .modifiers = 0x20 },
        .{ .cp = '{', .kind = .layer_tap, .layer = 1, .key_index = 5, .layer_activator = 6 },
    };
    @memcpy(p.routes[0..routes.len], &routes);
    p.route_len = routes.len;
    return p;
}

fn lessonAt(text: []const u8, typed: []const u8) !practice.Session {
    var session: practice.Session = .{ .error_mode = .forgive };
    try session.load(text);
    try session.insert(typed, 1_000, false);
    return session;
}

fn classOf(profile: *const layout_profile.LayoutProfile, session: *const practice.Session, decision: Decision) ?model.TapHoldClass {
    return if (classify(profile, session, decision, &.{})) |c| c.sample.class else null;
}

const tap_f: Decision = .{ .key_index = 3, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 70, .tapping_term_ms = 200 };
const hold_f: Decision = .{ .key_index = 3, .outcome = .hold, .reason = .permissive_hold, .elapsed_ms = 90, .other_key = 0, .tapping_term_ms = 200 };

test "a home-row Shift that fires while its letter is expected is an accidental hold" {
    const t = std.testing;
    const p = testProfile();
    // "fad": the roll f→a made Shift+A; the cursor waits on 'f' either way.
    var s = try lessonAt("fad", "");
    const held = classify(&p, &s, hold_f, &.{}).?;
    try t.expectEqual(@as(u21, 'f'), held.cp);
    try t.expectEqual(model.TapHoldClass.accidental_hold, held.sample.class);
    try t.expectEqual(@as(?u21, 'a'), held.sample.other_cp);
    try t.expectEqual(model.TapHoldReason.permissive_hold, held.sample.reason);
    s = try lessonAt("fad", "A");
    try t.expectEqual(@as(?model.TapHoldClass, .accidental_hold), classOf(&p, &s, hold_f));
    // The decision can come before the text of the character before it.
    s = try lessonAt("dfa", "");
    try t.expectEqual(@as(?model.TapHoldClass, .accidental_hold), classOf(&p, &s, hold_f));
}

test "a capital through the opposite home-row Shift is a wanted hold, a tap there is accidental" {
    const t = std.testing;
    const p = testProfile();
    const hold_j: Decision = .{ .key_index = 4, .outcome = .hold, .reason = .permissive_hold, .elapsed_ms = 120, .other_key = 0, .tapping_term_ms = 200 };
    const tap_j: Decision = .{ .key_index = 4, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 60, .tapping_term_ms = 200 };
    var s = try lessonAt("ds Ad", "ds ");
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_hold), classOf(&p, &s, hold_j));
    const tapped = classify(&p, &s, tap_j, &.{}).?;
    try t.expectEqual(@as(u21, 'j'), tapped.cp);
    try t.expectEqual(model.TapHoldClass.accidental_tap, tapped.sample.class);
    // A j typed right before the capital is the j, not a missed Shift.
    s = try lessonAt("jAd", "j");
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_tap), classOf(&p, &s, tap_j));
    try t.expectEqual(@as(?usize, 0), classify(&p, &s, tap_j, &.{}).?.typed_at);
    // Once the j's own decision typed it, the next tap missed the Shift.
    try t.expectEqual(model.TapHoldClass.accidental_tap, classify(&p, &s, tap_j, &.{0}).?.sample.class);
    // Holding j for the capital after typing j is still the Shift.
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_hold), classOf(&p, &s, hold_j));
    // A double letter: the first tap typed the cursor, the second the next one.
    s = try lessonAt("ffa", "");
    try t.expectEqual(@as(?usize, 1), classify(&p, &s, tap_f, &.{0}).?.typed_at);
}

test "taps are wanted, near holds when late, and unrelated decisions are ignored" {
    const t = std.testing;
    const p = testProfile();
    var s = try lessonAt("fad", "");
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_tap), classOf(&p, &s, tap_f));
    // The tap's own text arrived first and moved the cursor on.
    s = try lessonAt("fad", "f");
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_tap), classOf(&p, &s, tap_f));
    var slow = tap_f;
    slow.elapsed_ms = 150;
    try t.expectEqual(@as(?model.TapHoldClass, .near_hold), classOf(&p, &s, slow));
    slow.elapsed_ms = 149;
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_tap), classOf(&p, &s, slow));
    var retro = tap_f;
    retro.outcome = .retro_tap;
    retro.reason = .released_after_term;
    try t.expectEqual(@as(?model.TapHoldClass, .near_hold), classOf(&p, &s, retro));
    // Far from the cursor, a combo, or an unknown key: nothing to say.
    s = try lessonAt("sadsad", "sa");
    try t.expectEqual(@as(?model.TapHoldClass, null), classOf(&p, &s, tap_f));
    try t.expectEqual(@as(?model.TapHoldClass, null), classOf(&p, &s, hold_f));
    var combo = tap_f;
    combo.combo = true;
    s = try lessonAt("fad", "");
    try t.expectEqual(@as(?model.TapHoldClass, null), classOf(&p, &s, combo));
    var unknown = tap_f;
    unknown.key_index = 99;
    try t.expectEqual(@as(?model.TapHoldClass, null), classOf(&p, &s, unknown));
}

test "the layer-tap Space: an accidental hold on a space, an accidental tap before a layer symbol" {
    const t = std.testing;
    const p = testProfile();
    const hold_space: Decision = .{ .key_index = 6, .outcome = .hold, .reason = .term_elapsed, .elapsed_ms = 230, .tapping_term_ms = 200 };
    const tap_space: Decision = .{ .key_index = 6, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 50, .tapping_term_ms = 200 };
    var s = try lessonAt("as df", "as");
    const held = classify(&p, &s, hold_space, &.{}).?;
    try t.expectEqual(@as(u21, ' '), held.cp);
    try t.expectEqual(model.TapHoldClass.accidental_hold, held.sample.class);
    try t.expectEqual(@as(?u21, null), held.sample.other_cp);
    s = try lessonAt("a{d", "a");
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_hold), classOf(&p, &s, hold_space));
    try t.expectEqual(@as(?model.TapHoldClass, .accidental_tap), classOf(&p, &s, tap_space));
    // The symbol key itself, tapped on layer 1, is its symbol.
    const brace: Decision = .{ .key_index = 5, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 40, .tapping_term_ms = 200, .layer = 1 };
    try t.expectEqual(@as(u21, '{'), classify(&p, &s, brace, &.{}).?.cp);
    // A second Space key without a route of its own is still a Space.
    s = try lessonAt("as df", "as");
    var other_space = tap_space;
    other_space.key_index = 7;
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_tap), classOf(&p, &s, other_space));
}
