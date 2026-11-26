//! Tap/hold feedback of Test layout and the Tutor: how home-row modifiers
//! and layer-tap keys resolved, from the keyboard's own decisions (companion
//! protocol version 2). Test layout shows the latest decisions and marks the
//! keys involved. The Tutor marks keys that keep holding (or tapping) by
//! mistake on the confidence strip and the last lesson's keyboard, explains
//! them in the hover card, a lesson notice and the Progress sheet. Nothing
//! here changes scoring: an accidental hold still counts as a miss.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const keyboard_view = @import("practice_keyboard_ui.zig");

const control = desktop.practice_controller;
const model = desktop.practice_model;
const lp = desktop.practice_layout_profile;
const storage = desktop.practice_storage;
const tap_hold = desktop.practice_tap_hold;
const LabelCache = desktop.label_cache.LabelCache;
const Modifiers = @typeInfo(@FieldType(desktop.label_cache.CachedKeyContent, "hold_mods")).optional.child;

/// A key the Progress sheet asks the editor to open with the tapping term
/// field focused.
pub const EditKey = struct { key_index: usize, layer: usize = 0 };

/// Test layout marks the keys of the newest hold this long.
pub const mark_us: u64 = 2_000_000;
const fade_us: u64 = 600_000;

pub const holdColor = keyboard_view.holdColor;

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/// A key's tap character as a legend: an upper-case letter, ␣ for Space.
pub fn glyph(cp: u21, buf: *[8]u8) []const u8 {
    if (cp == ' ') return "␣";
    if (cp >= 'a' and cp <= 'z') {
        buf[0] = @intCast(cp - 32);
        return buf[0..1];
    }
    const n = std.unicode.utf8Encode(cp, buf[0..4]) catch return "?";
    return buf[0..n];
}

/// A key's tap character in a sentence: an upper-case letter, "Space".
pub fn keyName(cp: u21, buf: *[8]u8) []const u8 {
    return if (cp == ' ') "Space" else glyph(cp, buf);
}

/// What a key does while held, and where it sits.
pub const Role = struct {
    /// "⇧", "⌃", "⌥", "⌘" or "L2"; empty when unknown.
    glyph: []const u8 = "",
    /// "Shift", "Ctrl", "Alt", "Gui" or "Layer 2".
    name: []const u8 = "hold",
    finger: lp.Finger = .unknown,
    hand: lp.Hand = .neutral,
    thumb: bool = false,
    home_row: bool = false,
    key_index: ?usize = null,

    /// "Home-row Shift", "Thumb Layer 2" or the plain name.
    pub fn title(self: Role, arena: std.mem.Allocator) ![]const u8 {
        if (self.thumb) return std.fmt.allocPrint(arena, "Thumb {s}", .{self.name});
        if (self.home_row) return std.fmt.allocPrint(arena, "Home-row {s}", .{self.name});
        return self.name;
    }

    /// "⇧ Shift" or "Layer 2".
    pub fn head(self: Role, arena: std.mem.Allocator) ![]const u8 {
        return if (self.glyph.len > 0 and !std.mem.startsWith(u8, self.name, "Layer"))
            try std.fmt.allocPrint(arena, "{s} {s}", .{ self.glyph, self.name })
        else
            self.name;
    }

    /// "⇧ Shift · left pinky".
    pub fn describe(self: Role, arena: std.mem.Allocator) ![]const u8 {
        const finger = try lowerFinger(arena, self.finger);
        const lead = try self.head(arena);
        if (self.finger == .unknown) return lead;
        return std.fmt.allocPrint(arena, "{s} · {s}", .{ lead, finger });
    }
};

fn lowerFinger(arena: std.mem.Allocator, finger: lp.Finger) ![]const u8 {
    const text = try arena.dupe(u8, finger.name());
    if (text.len > 0) text[0] = std.ascii.toLower(text[0]);
    return text;
}

fn modifierRole(mods: Modifiers) ?[2][]const u8 {
    if (mods.left_shift or mods.right_shift) return .{ "⇧", "Shift" };
    if (mods.left_ctrl or mods.right_ctrl) return .{ "⌃", "Ctrl" };
    if (mods.left_alt or mods.right_alt) return .{ "⌥", "Alt" };
    if (mods.left_gui or mods.right_gui) return .{ "⌘", "Gui" };
    return null;
}

/// The key that types `cp` on tap; Space prefers the profile's space key.
pub fn keyOf(profile: *const lp.LayoutProfile, cp: u21) ?usize {
    if (cp == ' ') if (profile.space_key) |key| return key;
    for (profile.base_taps[0..profile.key_count], 0..) |tap, index| if (tap == cp) return index;
    return null;
}

/// The hold of `key_index` on `layer`: from the keycap labels, else from
/// the Shift and layer keys the profile knows.
pub fn roleOf(
    arena: std.mem.Allocator,
    profile: ?*const lp.LayoutProfile,
    labels: ?*const LabelCache,
    key_index: usize,
    layer: usize,
) !Role {
    var role: Role = .{ .key_index = key_index };
    if (profile) |p| if (key_index < p.key_count) {
        const key = p.keys[key_index];
        role.finger = key.finger;
        role.hand = key.hand;
        role.thumb = key.group == .thumb;
        role.home_row = key.home_row and key.group != .thumb;
    };
    if (labels) |cache| if (key_index < cache.key_count and cache.layer_count > 0) {
        const entry = cache.lookup(@min(layer, cache.layer_count - 1), key_index, .{});
        if (entry.hold_mods) |mods| if (modifierRole(mods)) |m| {
            role.glyph = m[0];
            role.name = m[1];
            return role;
        };
        if (entry.hold_layer) |target| {
            role.glyph = try std.fmt.allocPrint(arena, "L{d}", .{target});
            role.name = try std.fmt.allocPrint(arena, "Layer {d}", .{target});
            return role;
        }
    };
    if (profile) |p| {
        for (p.shiftSlice()) |shift| if (shift.key_index == key_index) switch (shift.kind) {
            .home_row_hold, .thumb_hold, .hold => {
                role.glyph = "⇧";
                role.name = "Shift";
                return role;
            },
            .one_shot, .dedicated => {},
        };
        for (p.layerActivatorSlice()) |activator| if (activator.key_index == key_index and !activator.one_shot) {
            role.glyph = try std.fmt.allocPrint(arena, "L{d}", .{activator.target_layer});
            role.name = try std.fmt.allocPrint(arena, "Layer {d}", .{activator.target_layer});
            return role;
        };
    }
    return role;
}

/// The hold of the key that types `cp` on tap.
pub fn roleOfChar(arena: std.mem.Allocator, profile: ?*const lp.LayoutProfile, labels: ?*const LabelCache, cp: u21) !Role {
    const p = profile orelse return .{};
    const key = keyOf(p, cp) orelse return .{};
    return roleOf(arena, p, labels, key, 0);
}

fn otherHand(hand: lp.Hand) []const u8 {
    return switch (hand) {
        .left => "a right-hand key",
        .right => "a left-hand key",
        .neutral => "the next key",
    };
}

/// What usually turns the key's tap into a hold (or its hold into a tap),
/// or null without accidental decisions. `short` is the Progress table form.
pub fn usually(arena: std.mem.Allocator, s: model.TapHoldSummary, role: Role, short: bool) !?[]const u8 {
    if (s.accidental_holds == 0 and s.accidental_taps == 0) return null;
    const reason = s.dominant_reason orelse return null;
    return switch (reason) {
        .permissive_hold => if (short)
            try std.fmt.allocPrint(arena, "still down when {s} went up (~{d:.0} ms)", .{ otherHand(role.hand), s.overlap_ms })
        else
            try std.fmt.allocPrint(arena, "still down when the next key went up (~{d:.0} ms after the press)", .{s.overlap_ms}),
        .term_elapsed => try std.fmt.allocPrint(arena, "held past {d} ms", .{s.tapping_term_ms}),
        .released_within_term => "released before the letter",
        .released_after_term => try std.fmt.allocPrint(arena, "released alone after {d} ms", .{s.tapping_term_ms}),
        .same_side_tap => "a key on the same hand went up first",
    };
}

/// The decision time from which a correct tap counts as a close call.
pub fn closeAt(term_ms: u16) u16 {
    return @intFromFloat(@ceil(model.near_hold_fraction * @as(f32, @floatFromInt(term_ms))));
}

/// "5 taps at ≥ 150 of 200 ms".
pub fn closeCalls(arena: std.mem.Allocator, s: model.TapHoldSummary) ![]const u8 {
    if (s.near_holds == 0) return "none";
    return std.fmt.allocPrint(arena, "{d} {s} at ≥ {d} of {d} ms", .{
        s.near_holds,
        if (s.near_holds == 1) "tap" else "taps",
        closeAt(s.tapping_term_ms),
        s.tapping_term_ms,
    });
}

/// The lesson notice: "A became Shift 3× · let go before the next key".
pub fn noticeText(arena: std.mem.Allocator, notice: control.TapHoldNotice, role: Role) ![]const u8 {
    var buf: [8]u8 = undefined;
    const key = keyName(notice.cp, &buf);
    if (!notice.hold) return std.fmt.allocPrint(arena, "{s} on {s} came as a tap {d}× · hold it until the letter", .{ role.name, key, notice.count });
    const advice: []const u8 = if (notice.reason) |reason| switch (reason) {
        .permissive_hold => " · let go before the next key",
        .term_elapsed => " · tap it quicker",
        else => "",
    } else "";
    return std.fmt.allocPrint(arena, "{s} became {s} {d}×{s}", .{ key, role.name, notice.count, advice });
}

pub const LessonTags = struct { hold: ?[]const u8 = null, tap: ?[]const u8 = null };

/// The Recent lessons tags of a run: "A → Shift ×2" and "O → tap ×1".
pub fn lessonTags(arena: std.mem.Allocator, run: storage.RunRecord, profile: ?*const lp.LayoutProfile, labels: ?*const LabelCache) !LessonTags {
    var buf: [8]u8 = undefined;
    var tags: LessonTags = .{};
    if (run.top_accidental_hold) |entry| if (entry[0] <= std.math.maxInt(u21)) {
        const cp: u21 = @intCast(entry[0]);
        const role = try roleOfChar(arena, profile, labels, cp);
        tags.hold = try std.fmt.allocPrint(arena, "{s} → {s} ×{d}", .{ keyName(cp, &buf), role.name, entry[1] });
    };
    if (run.top_accidental_tap) |entry| if (entry[0] <= std.math.maxInt(u21)) {
        const cp: u21 = @intCast(entry[0]);
        tags.tap = try std.fmt.allocPrint(arena, "{s} → tap ×{d}", .{ keyName(cp, &buf), entry[1] });
    };
    return tags;
}

/// A Test layout decision in a sentence: what the key became and why.
pub fn sentence(arena: std.mem.Allocator, decision: tap_hold.Decision, key: []const u8, other: ?[]const u8, role: Role) ![]const u8 {
    const term = decision.tapping_term_ms;
    const ms = decision.elapsed_ms;
    return switch (decision.outcome) {
        .hold => switch (decision.reason) {
            .permissive_hold => if (other) |o|
                std.fmt.allocPrint(arena, "{s} became {s} after {d} ms (term {d} ms): {s} went up while {s} was still down", .{ key, role.name, ms, term, o, key })
            else
                std.fmt.allocPrint(arena, "{s} became {s} after {d} ms (term {d} ms): the next key went up while {s} was still down", .{ key, role.name, ms, term, key }),
            .term_elapsed => std.fmt.allocPrint(arena, "{s} became {s}: held past {d} ms", .{ key, role.name, term }),
            else => std.fmt.allocPrint(arena, "{s} became {s} after {d} ms (term {d} ms)", .{ key, role.name, ms, term }),
        },
        .tap => switch (decision.reason) {
            .same_side_tap => if (other) |o|
                std.fmt.allocPrint(arena, "{s} stayed a tap: {s} on the same hand went up first ({d} ms)", .{ key, o, ms })
            else
                std.fmt.allocPrint(arena, "{s} stayed a tap: a same-hand key went up first ({d} ms)", .{ key, ms }),
            else => if (close(decision))
                std.fmt.allocPrint(arena, "{s} tapped after {d} ms: released within the term, close to {d} ms", .{ key, ms, term })
            else
                std.fmt.allocPrint(arena, "{s} tapped after {d} ms: released within the term ({d} ms)", .{ key, ms, term }),
        },
        .retro_tap => std.fmt.allocPrint(arena, "{s} tapped late: released alone after the {d} ms term", .{ key, term }),
    };
}

/// A tap decided at `model.near_hold_fraction` of the term or later.
pub fn close(decision: tap_hold.Decision) bool {
    if (decision.outcome != .tap or decision.tapping_term_ms == 0) return false;
    return decision.elapsed_ms >= closeAt(decision.tapping_term_ms);
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

fn rectId(bounds: dvui.Rect, salt: usize) u64 {
    return std.hash.Wyhash.hash(salt, std.mem.asBytes(&bounds));
}

fn drawText(t: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color, align_x: f32, weight: dvui.Font.Weight) void {
    dvui.labelNoFmt(@src(), t, .{ .align_x = align_x, .align_y = 0.5, .ellipsize = true }, .{
        .rect = bounds,
        .font = ui.editorFont(t, size).withWeight(weight),
        .color_text = .{ .color = color },
        .margin = .{},
        .padding = .{},
        .id_extra = rectId(bounds, t.len),
    });
}

fn fill(rect: dvui.Rect, color: dvui.Color, border: ?dvui.Color, radius: f32, id: usize) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const b = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = color },
        .color_border = if (border) |c| .{ .color = c } else null,
        .border = if (border != null) .all(1) else .{},
        .corners = .all(radius),
        .padding = .{},
        .margin = .{},
    });
    b.deinit();
}

/// A key legend in a small rounded tile, as in the chips and the table.
fn keyTile(theme: ui.Theme, legend: []const u8, x: f32, y: f32, h: f32, size: f32, id: usize) f32 {
    const font = dvui.Font.theme(.mono).withSize(size).withWeight(.bold);
    const w = @max(h, ui.editorFont(legend, size).textSize(legend).w + 12);
    const rect: dvui.Rect = .{ .x = x, .y = y, .w = w, .h = h };
    fill(rect, ui.mix(theme.panel, theme.text, 0.12), null, 4, id);
    dvui.labelNoFmt(@src(), legend, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = id,
        .rect = rect,
        .font = if (legend.len == 1 and legend[0] < 128) font else ui.editorFont(legend, size).withWeight(.bold),
        .color_text = .{ .color = theme.text },
        .padding = .{},
        .margin = .{},
    });
    return w;
}

/// The key's legend for a decision: its tap character, else its caption.
fn decisionKey(arena: std.mem.Allocator, profile: ?*const lp.LayoutProfile, labels: ?*const LabelCache, key: usize, layer: usize) ![]const u8 {
    if (profile) |p| {
        const cp = p.tapCharFor(key, layer) orelse p.tapCharFor(key, 0);
        if (cp) |c| {
            var buf: [8]u8 = undefined;
            return arena.dupe(u8, glyph(c, &buf));
        }
    }
    if (labels) |cache| if (key < cache.key_count and cache.layer_count > 0) {
        if (cache.lookup(@min(layer, cache.layer_count - 1), key, .{}).label) |label| if (label.len > 0 and label.len <= 6) return label;
    };
    return std.fmt.allocPrint(arena, "#{d}", .{key});
}

fn decisionKeyName(arena: std.mem.Allocator, legend: []const u8) []const u8 {
    if (std.mem.eql(u8, legend, "␣")) return "Space";
    _ = arena;
    return legend;
}

// ---------------------------------------------------------------------------
// Test layout
// ---------------------------------------------------------------------------

/// Height of the tap/hold row of the Test layout telemetry card.
pub const test_row_h: f32 = 42;

/// Whether the layout has a key that taps and holds, so the row is worth
/// showing; decisions that already arrived always show it.
pub fn layoutHasTapHolds(owner: *const control.Controller) bool {
    if (owner.test_keys.tap_hold_len > 0) return true;
    if (!owner.profile_bound) return false;
    for (owner.profile.shiftSlice()) |shift| switch (shift.kind) {
        .home_row_hold, .thumb_hold, .hold => return true,
        .one_shot, .dedicated => {},
    };
    for (owner.profile.layerActivatorSlice()) |activator| if (!activator.one_shot) return true;
    return false;
}

/// The second row of the Test layout telemetry card: the keyboard's last
/// four tap/hold decisions, newest right, and one sentence on the newest.
pub fn testRow(
    owner: *const control.Controller,
    theme: ui.Theme,
    rect: dvui.Rect,
    labels: ?*const LabelCache,
    support: control.TapHoldSupport,
) !void {
    const arena = dvui.currentWindow().arena();
    const profile: ?*const lp.LayoutProfile = if (owner.profile_bound) &owner.profile else null;
    fill(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, theme.border, null, 0, 0x9a00);
    const y = rect.y + 1;
    const h = rect.h - 1;
    const label_w = ui.editorFont("Tap/hold:", 14).textSize("Tap/hold:").w + 10;
    drawText("Tap/hold:", .{ .x = rect.x, .y = y, .w = label_w, .h = h }, 14, theme.muted, 0, .normal);
    const decisions = owner.test_keys.tapHoldSlice();
    if (decisions.len == 0) {
        const note = switch (support) {
            .reporting => "hold or roll a home-row key to see how the keyboard decides",
            .old_firmware => "needs current firmware on the keyboard",
            .unknown => "connect your Zigmkay keyboard to see how it decides",
        };
        drawText(note, .{ .x = rect.x + label_w, .y = y, .w = @max(0, rect.w - label_w), .h = h }, 14, theme.muted, 0, .normal);
        return;
    }

    // Chips, newest right; the oldest give way when the card is narrow.
    const chip_h: f32 = 28;
    const chip_y = y + (h - chip_h) / 2;
    const hold = holdColor(theme);
    var widths: [control.TestKeysTelemetry.max_test_tap_holds]f32 = undefined;
    var legends: [control.TestKeysTelemetry.max_test_tap_holds][]const u8 = undefined;
    var captions: [control.TestKeysTelemetry.max_test_tap_holds][]const u8 = undefined;
    for (decisions, 0..) |entry, i| {
        const d = entry.decision;
        legends[i] = try decisionKey(arena, profile, labels, d.key_index, d.layer);
        const role = try roleOf(arena, profile, labels, d.key_index, d.layer);
        captions[i] = switch (d.outcome) {
            .hold => if (role.glyph.len > 0)
                try std.fmt.allocPrint(arena, "HOLD {s} {d} ms", .{ role.glyph, d.elapsed_ms })
            else
                try std.fmt.allocPrint(arena, "HOLD {d} ms", .{d.elapsed_ms}),
            .tap => if (close(d))
                try std.fmt.allocPrint(arena, "tap {d} ms · close", .{d.elapsed_ms})
            else
                try std.fmt.allocPrint(arena, "tap {d} ms", .{d.elapsed_ms}),
            .retro_tap => try std.fmt.allocPrint(arena, "tap {d} ms · late", .{d.elapsed_ms}),
        };
        const legend_w = @max(chip_h - 6, ui.editorFont(legends[i], 13).textSize(legends[i]).w + 12);
        widths[i] = 3 + legend_w + 6 + ui.editorFont(captions[i], 13).textSize(captions[i]).w + 10;
    }
    const chips_max = rect.w * 0.55 - label_w;
    var first: usize = 0;
    var total: f32 = 0;
    for (0..decisions.len) |k| total += widths[k] + 6;
    while (first + 1 < decisions.len and total > chips_max) : (first += 1) total -= widths[first] + 6;

    var x = rect.x + label_w;
    for (decisions[first..], first..) |entry, i| {
        const d = entry.decision;
        const is_hold = d.outcome == .hold;
        const chip: dvui.Rect = .{ .x = x, .y = chip_y, .w = widths[i], .h = chip_h };
        fill(
            chip,
            if (is_hold) ui.mix(theme.panel, hold, 0.2) else theme.control,
            if (is_hold) ui.mix(theme.panel, hold, 0.65) else theme.border,
            6,
            0x9a10 + i,
        );
        const legend_w = keyTile(theme, legends[i], x + 3, chip_y + 3, chip_h - 6, 13, 0x9a20 + i);
        const caption_color = if (is_hold)
            ui.mix(theme.text, hold, 0.25)
        else if (close(d) or d.outcome == .retro_tap)
            ui.mix(theme.muted, theme.warning, 0.6)
        else
            theme.muted;
        drawText(captions[i], .{ .x = x + 3 + legend_w + 6, .y = chip_y, .w = widths[i] - legend_w - 9, .h = chip_h }, 13, caption_color, 0, if (is_hold) .bold else .normal);
        x += widths[i] + 6;
    }

    const newest = decisions[decisions.len - 1].decision;
    const key = decisionKeyName(arena, legends[decisions.len - 1]);
    const other: ?[]const u8 = if (newest.other_key) |o| decisionKeyName(arena, try decisionKey(arena, profile, labels, o, newest.layer)) else null;
    const role = try roleOf(arena, profile, labels, newest.key_index, newest.layer);
    const line = try sentence(arena, newest, key, other, role);
    const sx = x + 10;
    drawText(line, .{ .x = sx, .y = y, .w = @max(0, rect.x + rect.w - sx), .h = h }, 14, theme.text, 1, .normal);
}

/// The keys of the newest hold, for two seconds: the key that held (teal,
/// "HOLD ⇧") and the key whose release made it a permissive hold (blue,
/// "went up").
pub fn testMarks(arena: std.mem.Allocator, owner: *const control.Controller, theme: ui.Theme, labels: ?*const LabelCache, now_us: u64) ![]const keyboard_view.KeyMark {
    const decisions = owner.test_keys.tapHoldSlice();
    if (decisions.len == 0) return &.{};
    const newest = decisions[decisions.len - 1];
    const age = now_us -| newest.at_us;
    if (newest.decision.outcome != .hold or age >= mark_us) return &.{};
    const left = mark_us - age;
    const alpha: f32 = if (left < fade_us) @as(f32, @floatFromInt(left)) / @as(f32, @floatFromInt(fade_us)) else 1;
    const profile: ?*const lp.LayoutProfile = if (owner.profile_bound) &owner.profile else null;
    const role = try roleOf(arena, profile, labels, newest.decision.key_index, newest.decision.layer);
    var marks: std.ArrayList(keyboard_view.KeyMark) = .empty;
    try marks.append(arena, .{
        .key_index = newest.decision.key_index,
        .color = holdColor(theme),
        .badge = if (role.glyph.len > 0) try std.fmt.allocPrint(arena, "HOLD {s}", .{role.glyph}) else "HOLD",
        .alpha = alpha,
    });
    if (newest.decision.reason == .permissive_hold) if (newest.decision.other_key) |other| {
        try marks.append(arena, .{ .key_index = other, .color = theme.accent, .badge = "went up", .alpha = alpha });
    };
    return marks.items;
}

/// How long until the Test layout marks change: when they start to fade and
/// while they fade. Null when nothing is marked.
pub fn testMarksRefresh(owner: *const control.Controller, now_us: u64) ?u64 {
    const decisions = owner.test_keys.tapHoldSlice();
    if (decisions.len == 0) return null;
    const newest = decisions[decisions.len - 1];
    const age = now_us -| newest.at_us;
    if (newest.decision.outcome != .hold or age >= mark_us) return null;
    const left = mark_us - age;
    return if (left > fade_us) left - fade_us else @min(left, 50_000);
}

// ---------------------------------------------------------------------------
// Tutor
// ---------------------------------------------------------------------------

/// The confidence strip marker of a key that keeps holding ("⇧3", teal) or
/// tapping ("TAP 2", amber) by mistake; nothing below the threshold.
pub fn chipMarker(theme: ui.Theme, chip: dvui.Rect, summary: model.TapHoldSummary, role: Role, i: usize) void {
    const holds = summary.accidental_holds >= control.tap_hold_marker_at;
    const taps = summary.accidental_taps >= control.tap_hold_marker_at;
    if (!holds and !taps) return;
    var buf: [24]u8 = undefined;
    const label = if (holds)
        std.fmt.bufPrint(&buf, "{s}{d}", .{ if (role.glyph.len > 0) role.glyph else "H", summary.accidental_holds }) catch return
    else
        std.fmt.bufPrint(&buf, "TAP {d}", .{summary.accidental_taps}) catch return;
    const color = if (holds) holdColor(theme) else theme.warning;
    const font = ui.editorFont(label, 11.5).withWeight(.bold);
    const w = font.textSize(label).w + 12;
    const h: f32 = 18;
    const rect: dvui.Rect = .{ .x = chip.x + chip.w - w + 5, .y = chip.y - 9, .w = w, .h = h };
    const pill = dvui.box(@src(), .{}, .{
        .id_extra = 0x9b00 + i,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, color, 0.32) },
        .color_border = .{ .color = color },
        .border = .all(1.5),
        .corners = .all(h / 2),
        .padding = .{},
        .margin = .{},
        .tag = if (holds) "practice.confidence.tap_hold" else null,
    });
    pill.deinit();
    dvui.labelNoFmt(@src(), label, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = 0x9b40 + i,
        .rect = rect,
        .font = font,
        .color_text = .{ .color = theme.text },
        .padding = .{},
        .margin = .{},
    });
}

fn tooltipRow(theme: ui.Theme, key: []const u8, value: []const u8, value_color: dvui.Color, id: usize) void {
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .padding = .{ .y = 1, .h = 1 }, .margin = .{} });
    defer row.deinit();
    dvui.labelNoFmt(@src(), key, .{}, .{
        .font = ui.editorFont(key, 12.5),
        .color_text = .{ .color = theme.muted },
        .min_size_content = .{ .w = 92 },
        .padding = .{},
        .margin = .{},
    });
    dvui.labelNoFmt(@src(), value, .{}, .{
        .font = ui.editorFont(value, 12.5),
        .color_text = .{ .color = value_color },
        .padding = .{},
        .margin = .{},
    });
}

/// The hover card section of a key that taps and holds. Returns whether
/// "Details in Progress" was clicked.
pub fn tooltipSection(theme: ui.Theme, cp: u21, summary: model.TapHoldSummary, role: Role) !bool {
    const arena = dvui.currentWindow().arena();
    const sep = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 1 },
        .background = true,
        .color_fill = .{ .color = theme.border },
        .margin = .{ .y = 6, .h = 5 },
        .padding = .{},
    });
    sep.deinit();
    var buf: [8]u8 = undefined;
    const title = try std.fmt.allocPrint(arena, "{s} (hold {s})", .{ try role.title(arena), keyName(cp, &buf) });
    dvui.labelNoFmt(@src(), title, .{}, .{
        .font = ui.editorFont(title, 12.5).withWeight(.bold),
        .color_text = .{ .color = ui.mix(theme.text, holdColor(theme), 0.55) },
        .padding = .{ .y = 1, .h = 2 },
        .margin = .{},
    });
    const became_key = try std.fmt.allocPrint(arena, "Became {s}", .{role.name});
    const became = try std.fmt.allocPrint(arena, "{d} of its last {d} taps", .{ summary.accidental_holds, summary.window });
    tooltipRow(theme, became_key, became, if (summary.accidental_holds >= control.tap_hold_marker_at) theme.text else theme.muted, 1);
    if (summary.accidental_taps > 0) {
        const tapped = try std.fmt.allocPrint(arena, "{d} of its last {d} holds", .{ summary.accidental_taps, summary.window });
        tooltipRow(theme, "Came as a tap", tapped, theme.warning, 2);
    }
    if (try usually(arena, summary, role, false)) |reason| tooltipRow(theme, "Usually", reason, theme.text, 3);
    tooltipRow(theme, "Close calls", try closeCalls(arena, summary), theme.muted, 4);
    return dvui.button(@src(), "Details in Progress", .{}, .{
        .font = ui.editorFont("Details in Progress", 12.5),
        .color_text = .{ .color = theme.accent },
        .background = false,
        .border = .{},
        .padding = .{ .y = 4 },
        .margin = .{},
        .tag = "practice.tooltip.tap_hold_details",
    });
}

/// The heatmap marks of the last lesson's keys that held (teal dashed,
/// "HOLD ×3") or tapped (amber dashed, "TAP ×2") by mistake.
pub fn lessonMarks(arena: std.mem.Allocator, owner: *const control.Controller, theme: ui.Theme, key_count: usize) ![]const keyboard_view.KeyMark {
    const lesson = owner.last_lesson orelse return &.{};
    if (!owner.profile_bound) return &.{};
    var marks: std.ArrayList(keyboard_view.KeyMark) = .empty;
    for (lesson.tapHoldKeySlice()) |key| {
        const index = keyOf(&owner.profile, key.cp) orelse continue;
        if (index >= key_count) continue;
        if (key.accidental_holds > 0) {
            try marks.append(arena, .{ .key_index = index, .color = holdColor(theme), .dashed = true, .badge = try std.fmt.allocPrint(arena, "HOLD ×{d}", .{key.accidental_holds}) });
        } else if (key.accidental_taps > 0) {
            try marks.append(arena, .{ .key_index = index, .color = theme.warning, .dashed = true, .badge = try std.fmt.allocPrint(arena, "TAP ×{d}", .{key.accidental_taps}) });
        }
    }
    return marks.items;
}

// ---------------------------------------------------------------------------
// Progress sheet
// ---------------------------------------------------------------------------

const max_rows = 6;
const max_tap_rows = 2;
const row_h: f32 = 44;
const head_h: f32 = 46;
const column_h: f32 = 32;
const foot_h: f32 = 40;
/// The mini keyboard beside the table, when the sheet is wide enough.
const mini_w: f32 = 200;
const mini_min_w: f32 = 700;

fn moreAccidental(_: void, a: model.TapHoldSummary, b: model.TapHoldSummary) bool {
    if (a.accidental_holds != b.accidental_holds) return a.accidental_holds > b.accidental_holds;
    if (a.near_holds != b.near_holds) return a.near_holds > b.near_holds;
    return a.total > b.total;
}

const Rows = struct {
    holds: [max_rows]model.TapHoldSummary = undefined,
    hold_len: usize = 0,
    taps: [max_tap_rows]model.TapHoldSummary = undefined,
    tap_len: usize = 0,
};

fn collect(owner: *const control.Controller) Rows {
    var all: [model.max_tap_hold_keys]model.TapHoldSummary = undefined;
    var len: usize = 0;
    for (owner.learning.tapHoldSlice()) |st| {
        if (st.recent_len == 0) continue;
        all[len] = st.summary();
        len += 1;
    }
    std.mem.sort(model.TapHoldSummary, all[0..len], {}, moreAccidental);
    var rows: Rows = .{};
    for (all[0..len]) |s| {
        // A key whose taps came by mistake gets its own amber row; it is
        // listed with its holds only when those went wrong as well.
        if (s.accidental_taps > 0 and rows.tap_len < max_tap_rows) {
            rows.taps[rows.tap_len] = s;
            rows.tap_len += 1;
            if (s.accidental_holds == 0) continue;
        }
        if (rows.hold_len < max_rows) {
            rows.holds[rows.hold_len] = s;
            rows.hold_len += 1;
        }
    }
    return rows;
}

/// Whether the Progress sheet has tap/hold keys to show.
pub fn hasProgressData(owner: *const control.Controller) bool {
    for (owner.learning.tapHoldSlice()) |st| if (st.recent_len > 0) return true;
    return false;
}

/// The height of the "Tap/hold keys" section.
pub fn progressHeight(owner: *const control.Controller, w: f32) f32 {
    const rows = collect(owner);
    const count: f32 = @floatFromInt(rows.hold_len + rows.tap_len);
    const table = head_h + column_h + count * row_h + foot_h;
    return if (w >= mini_min_w) @max(table, head_h + 196 + foot_h) else table;
}

/// The "Tap/hold keys" section of the Progress sheet: a table sorted by
/// accidental holds, a mini keyboard marking the keys, and a tapping term
/// suggestion that opens the key in the editor when `can_edit`.
pub fn progressSection(
    owner: *const control.Controller,
    theme: ui.Theme,
    rect: dvui.Rect,
    labels: ?*const LabelCache,
    geometry: []const @import("layout-model").physical_layout.Key,
    can_edit: bool,
) !?EditKey {
    const panel = dvui.box(@src(), .{}, .{
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.progress.tap_hold",
    });
    defer panel.deinit();
    const arena = dvui.currentWindow().arena();
    const profile: ?*const lp.LayoutProfile = if (owner.profile_bound) &owner.profile else null;
    const pad: f32 = 14;
    drawText("Tap/hold keys", .{ .x = pad, .y = 12, .w = 200, .h = 20 }, 14, theme.text, 0, .bold);
    drawText("Last 30 decisions per key · from the keyboard", .{ .x = rect.w * 0.35, .y = 12, .w = rect.w * 0.65 - pad, .h = 20 }, 12.5, theme.muted, 1, .normal);

    const with_mini = rect.w >= mini_min_w and geometry.len > 0;
    const table_w = rect.w - pad * 2 - if (with_mini) mini_w + 16 else 0;
    // Key · Became a hold by mistake · Close calls · Usually · suggestion
    const shares = [_]f32{ 0.19, 0.17, 0.08, 0.31, 0.25 };
    var cols: [shares.len]f32 = undefined;
    var cx: f32 = pad;
    for (shares, 0..) |share, i| {
        cols[i] = cx;
        cx += table_w * share;
    }
    const col_w = struct {
        fn of(c: []const f32, i: usize, end: f32) f32 {
            return (if (i + 1 < c.len) c[i + 1] else end) - c[i] - 8;
        }
    }.of;
    const end = pad + table_w;
    const header_y = head_h - 6;
    const headers = [_][]const u8{ "Key", "Became a hold by mistake", "Close calls", "Usually", "" };
    for (headers, 0..) |h, i| twoLines(h, .{ .x = cols[i], .y = header_y, .w = col_w(&cols, i, end), .h = column_h }, 11.5, theme.muted, 0x9c08 + i);
    fill(.{ .x = pad, .y = header_y + column_h, .w = table_w, .h = 1 }, theme.border, null, 0, 0x9c00);

    const rows = collect(owner);
    var result: ?EditKey = null;
    var y = header_y + column_h + 1;
    const hold = holdColor(theme);
    for (rows.holds[0..rows.hold_len], 0..) |s, r| {
        const role = try roleOfChar(arena, profile, labels, s.cp);
        try keyCell(arena, theme, s.cp, role, cols[0], y, col_w(&cols, 0, end), 0x9c10 + r * 4);
        meterCell(theme, cols[1], y, col_w(&cols, 1, end), s.accidental_holds, s.window, hold, try std.fmt.allocPrint(arena, "{d} of {d}", .{ s.accidental_holds, s.window }), 0x9d00 + r * 4);
        drawText(try std.fmt.allocPrint(arena, "{d}", .{s.near_holds}), .{ .x = cols[2], .y = y, .w = col_w(&cols, 2, end), .h = row_h }, 13, if (s.near_holds > 0) theme.text else theme.muted, 0, .normal);
        const reason = try usually(arena, s, role, true);
        twoLines(reason orelse "–", .{ .x = cols[3], .y = y, .w = col_w(&cols, 3, end), .h = row_h }, 12, if (reason != null) theme.text else theme.muted, 0x9e00 + r * 4);
        if (s.accidental_holds > 0) {
            const suggest_rect: dvui.Rect = .{ .x = cols[4], .y = y, .w = end - cols[4], .h = row_h };
            if (control.suggestsTerm(s)) {
                const label = try std.fmt.allocPrint(arena, "Term {d} → {d} ms", .{ s.tapping_term_ms, control.suggestedTerm(s.tapping_term_ms) });
                if (suggestionPill(theme, label, suggest_rect, theme.accent, can_edit and role.key_index != null, 0x9f00 + r * 4)) {
                    result = .{ .key_index = role.key_index.? };
                }
            } else if (s.dominant_reason == .permissive_hold) {
                _ = suggestionPill(theme, "practice: let go sooner", suggest_rect, hold, false, 0x9f00 + r * 4);
            }
        }
        y += row_h;
        fill(.{ .x = pad, .y = y - 1, .w = table_w, .h = 1 }, ui.mix(theme.panel, theme.border, 0.6), null, 0, 0x9c40 + r);
    }
    for (rows.taps[0..rows.tap_len], 0..) |s, r| {
        const role = try roleOfChar(arena, profile, labels, s.cp);
        try keyCell(arena, theme, s.cp, role, cols[0], y, col_w(&cols, 0, end), 0x9c80 + r * 4);
        const span = cols[3] - cols[1] - 8;
        meterCell(theme, cols[1], y, span, s.accidental_taps, s.window, theme.warning, try std.fmt.allocPrint(arena, "tapped instead of held: {d} of {d}", .{ s.accidental_taps, s.window }), 0x9d80 + r * 4);
        twoLines((try usually(arena, s, role, true)) orelse "–", .{ .x = cols[3], .y = y, .w = col_w(&cols, 3, end), .h = row_h }, 12, theme.warning, 0x9e80 + r * 4);
        y += row_h;
        fill(.{ .x = pad, .y = y - 1, .w = table_w, .h = 1 }, ui.mix(theme.panel, theme.border, 0.6), null, 0, 0x9cc0 + r);
    }

    if (with_mini) {
        const mx = rect.w - pad - mini_w;
        // The two legend entries are wider than the keyboard side by side,
        // so they stand one above the other.
        const legend_line_h: f32 = 18;
        const legend_h: f32 = 22 + legend_line_h;
        const area: dvui.Rect = .{ .x = mx, .y = header_y, .w = mini_w, .h = @max(80, rect.h - header_y - foot_h - legend_h) };
        try miniKeyboard(owner, theme, area, geometry, rows);
        legendSwatch(theme, mx, area.y + area.h + 4, hold, "mistaken holds", 0x9a80);
        legendSwatch(theme, mx, area.y + area.h + 4 + legend_line_h, theme.warning, "mistaken taps", 0x9a90);
    }

    const note = try std.fmt.allocPrint(arena, "The suggestion opens the key in the editor with the tapping term field focused; nothing changes until you flash. Shown once a key has {d} decisions.", .{control.tap_hold_suggest_after});
    twoLines(note, .{ .x = pad, .y = rect.h - foot_h + 2, .w = rect.w - pad * 2, .h = foot_h - 8 }, 11.5, theme.muted, 0x9aa0);
    return result;
}

/// The key legend with its hold above the finger: "⇧ Shift" over "left pinky".
fn keyCell(arena: std.mem.Allocator, theme: ui.Theme, cp: u21, role: Role, x: f32, y: f32, w: f32, id: usize) !void {
    var buf: [8]u8 = undefined;
    const tile_w = keyTile(theme, glyph(cp, &buf), x, y + (row_h - 22) / 2, 22, 13, id);
    const tx = x + tile_w + 8;
    const tw = @max(0, w - tile_w - 8);
    if (role.finger == .unknown) return drawText(try role.head(arena), .{ .x = tx, .y = y, .w = tw, .h = row_h }, 12, theme.text, 0, .normal);
    drawText(try role.head(arena), .{ .x = tx, .y = y + 5, .w = tw, .h = 17 }, 12, theme.text, 0, .normal);
    drawText(try lowerFinger(arena, role.finger), .{ .x = tx, .y = y + 22, .w = tw, .h = 16 }, 11.5, theme.muted, 0, .normal);
}

fn meterCell(theme: ui.Theme, x: f32, y: f32, w: f32, count: u8, window: u8, color: dvui.Color, label: []const u8, id: usize) void {
    const meter_w = @min(44.0, w * 0.36);
    const my = y + row_h / 2 - 2.5;
    fill(.{ .x = x, .y = my, .w = meter_w, .h = 5 }, ui.mix(theme.panel, theme.border, 0.9), null, 2.5, id);
    if (count > 0 and window > 0) {
        const share = @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(window));
        fill(.{ .x = x, .y = my, .w = @max(4, meter_w * @min(1, share * 3)), .h = 5 }, color, null, 2.5, id + 1);
    }
    twoLines(label, .{ .x = x + meter_w + 8, .y = y, .w = @max(0, w - meter_w - 8), .h = row_h }, 12, if (count > 0) theme.text else theme.muted, id + 2);
}

/// A small pill in the suggestion column, on two lines when one does not
/// fit; a button when `clickable`.
fn suggestionPill(theme: ui.Theme, label: []const u8, cell: dvui.Rect, color: dvui.Color, clickable: bool, id: usize) bool {
    const size: f32 = 11.5;
    const font = ui.editorFont(label, size);
    const inner = cell.w - 16;
    var lines: [2][]const u8 = .{ label, "" };
    if (font.textSize(label).w > inner) {
        var i: usize = 0;
        var split: usize = 0;
        while (std.mem.indexOfScalarPos(u8, label, i, ' ')) |space| : (i = space + 1) {
            if (font.textSize(label[0..space]).w > inner) break;
            split = space;
        }
        if (split > 0) lines = .{ label[0..split], label[split + 1 ..] };
    }
    const two = lines[1].len > 0;
    const text_w = @max(font.textSize(lines[0]).w, font.textSize(lines[1]).w);
    const h: f32 = if (two) 36 else 22;
    const rect: dvui.Rect = .{ .x = cell.x, .y = cell.y + (cell.h - h) / 2, .w = @min(cell.w, text_w + 16), .h = h };
    const fill_color = ui.mix(theme.panel, color, 0.16);
    const border_color = ui.mix(theme.panel, color, 0.55);
    const text_color = ui.mix(theme.text, color, 0.3);
    var clicked = false;
    if (clickable) {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .id_extra = id,
            .rect = rect,
            .background = true,
            .color_fill = .{ .color = fill_color },
            .color_fill_hover = .{ .color = ui.mix(theme.panel, color, 0.3) },
            .color_border = .{ .color = border_color },
            .border = .all(1),
            .corners = .all(6),
            .padding = .{},
            .margin = .{},
            .tag = "practice.progress.tap_hold.suggestion",
        });
        button.processEvents();
        button.drawBackground();
        if (button.hovered()) dvui.cursorSet(.hand);
        clicked = button.clicked();
        button.deinit();
    } else {
        fill(rect, fill_color, border_color, 6, id);
    }
    const line_h: f32 = if (two) 16 else h;
    const top = rect.y + if (two) @as(f32, 2) else 0;
    for (lines, 0..) |line, n| {
        if (line.len == 0) continue;
        const y = top + @as(f32, @floatFromInt(n)) * line_h;
        dvui.labelNoFmt(@src(), line, .{ .align_x = 0.5, .align_y = 0.5, .ellipsize = true }, .{
            .id_extra = id * 4 + n,
            .rect = .{ .x = rect.x + 8, .y = y, .w = rect.w - 16, .h = line_h },
            .font = font,
            .color_text = .{ .color = text_color },
            .padding = .{},
            .margin = .{},
        });
    }
    return clicked;
}

/// `t` on one line, or split at a space onto two when it does not fit.
fn twoLines(t: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color, id: usize) void {
    const font = ui.editorFont(t, size);
    if (font.textSize(t).w <= bounds.w) return drawText(t, bounds, size, color, 0, .normal);
    var split: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, t, i, ' ')) |space| : (i = space + 1) {
        if (font.textSize(t[0..space]).w > bounds.w) break;
        split = space;
    }
    if (split == 0) return drawText(t, bounds, size, color, 0, .normal);
    const line_h = @min(bounds.h / 2, size * 1.4);
    const top = bounds.y + (bounds.h - line_h * 2) / 2;
    _ = id;
    drawText(t[0..split], .{ .x = bounds.x, .y = top, .w = bounds.w, .h = line_h }, size, color, 0, .normal);
    drawText(t[split + 1 ..], .{ .x = bounds.x, .y = top + line_h, .w = bounds.w, .h = line_h }, size, color, 0, .normal);
}

fn legendSwatch(theme: ui.Theme, x: f32, y: f32, color: dvui.Color, label: []const u8, id: usize) void {
    const swatch: dvui.Rect = .{ .x = x, .y = y + 4, .w = 12, .h = 12 };
    fill(swatch, ui.mix(theme.panel, color, 0.12), null, 3, id);
    keyboard_view.drawDashedOutline(swatch, .{}, color, 1.5);
    drawText(label, .{ .x = x + 18, .y = y, .w = mini_w - 18, .h = 20 }, 11.5, theme.muted, 0, .normal);
}

/// A small outline of the keyboard: keys with mistaken holds teal dashed,
/// mistaken taps amber dashed, the rest faint.
fn miniKeyboard(
    owner: *const control.Controller,
    theme: ui.Theme,
    area: dvui.Rect,
    geometry: []const @import("layout-model").physical_layout.Key,
    rows: Rows,
) !void {
    const fitted = desktop.physical_view.fit(geometry, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h });
    if (!std.math.isFinite(fitted.scale) or fitted.scale <= 0) return;
    const hold = holdColor(theme);
    for (geometry, 0..) |item, order| {
        const placed = fitted.place(item);
        const gap = @max(0.75, @min(2.5, fitted.scale * 0.06));
        const rect: dvui.Rect = .{
            .x = placed.rect.x + gap,
            .y = placed.rect.y + gap,
            .w = @max(1, placed.rect.w - gap * 2),
            .h = @max(1, placed.rect.h - gap * 2),
        };
        const turn: ui.Turn = .{ .radians = placed.rotation, .pivot = rect.center() };
        var marked: ?dvui.Color = null;
        if (owner.profile_bound) {
            for (rows.holds[0..rows.hold_len]) |s| if (s.accidental_holds > 0 and keyOf(&owner.profile, s.cp) == placed.key_index) {
                marked = hold;
            };
            if (marked == null) for (rows.taps[0..rows.tap_len]) |s| if (keyOf(&owner.profile, s.cp) == placed.key_index) {
                marked = theme.warning;
            };
        }
        const face = if (marked) |c| ui.mix(theme.panel, c, 0.16) else ui.mix(theme.panel, theme.bg, 0.4);
        const corner = @max(2, rect.w * 0.14);
        ui.keycapPart(rect, turn, @intCast(order % 4096), 6, .round(corner), face, if (marked == null) ui.mix(theme.panel, theme.border, 0.8) else null, 1);
        if (marked) |c| keyboard_view.drawDashedOutline(rect, turn, c, 1.5);
    }
}

test "tap/hold texts name the key, its hold and the cause" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shift: Role = .{ .glyph = "⇧", .name = "Shift", .finger = .left_pinky, .hand = .left, .home_row = true };
    try t.expectEqualStrings("⇧ Shift · left pinky", try shift.describe(arena));
    try t.expectEqualStrings("Home-row Shift", try shift.title(arena));
    const layer: Role = .{ .glyph = "L2", .name = "Layer 2", .finger = .left_thumb, .thumb = true };
    try t.expectEqualStrings("Layer 2 · left thumb", try layer.describe(arena));

    try t.expectEqualStrings("A became Shift 3× · let go before the next key", try noticeText(arena, .{ .cp = 'a', .count = 3, .hold = true, .reason = .permissive_hold }, shift));
    try t.expectEqualStrings("Space became Layer 2 1× · tap it quicker", try noticeText(arena, .{ .cp = ' ', .count = 1, .hold = true, .reason = .term_elapsed }, layer));
    try t.expectEqualStrings("Shift on O came as a tap 2× · hold it until the letter", try noticeText(arena, .{ .cp = 'o', .count = 2, .hold = false }, shift));

    const roll: tap_hold.Decision = .{ .key_index = 0, .outcome = .hold, .reason = .permissive_hold, .elapsed_ms = 143, .other_key = 1, .tapping_term_ms = 200 };
    try t.expectEqualStrings("A became Shift after 143 ms (term 200 ms): N went up while A was still down", try sentence(arena, roll, "A", "N", shift));
    var slow = roll;
    slow.reason = .term_elapsed;
    try t.expectEqualStrings("A became Shift: held past 200 ms", try sentence(arena, slow, "A", null, shift));
    const tap: tap_hold.Decision = .{ .key_index = 0, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 171, .tapping_term_ms = 200 };
    try t.expect(close(tap));
    try t.expectEqualStrings("S tapped after 171 ms: released within the term, close to 200 ms", try sentence(arena, tap, "S", null, shift));
    var quick = tap;
    quick.elapsed_ms = 149;
    try t.expect(!close(quick));
    try t.expectEqual(@as(u16, 150), closeAt(200));

    var s: model.TapHoldSummary = .{
        .cp = 'a',
        .window = 30,
        .accidental_holds = 3,
        .accidental_taps = 0,
        .near_holds = 5,
        .wanted_holds = 0,
        .dominant_reason = .permissive_hold,
        .typical_ms = 110,
        .overlap_ms = 41.6,
        .tapping_term_ms = 200,
        .last_overlap_cp = 'n',
        .total = 80,
    };
    try t.expectEqualStrings("still down when a right-hand key went up (~42 ms)", (try usually(arena, s, shift, true)).?);
    try t.expectEqualStrings("still down when the next key went up (~42 ms after the press)", (try usually(arena, s, shift, false)).?);
    try t.expectEqualStrings("5 taps at ≥ 150 of 200 ms", try closeCalls(arena, s));
    s.dominant_reason = .term_elapsed;
    try t.expectEqualStrings("held past 200 ms", (try usually(arena, s, shift, true)).?);
    s.accidental_holds = 0;
    try t.expectEqual(@as(?[]const u8, null), try usually(arena, s, shift, true));

    const run: storage.RunRecord = .{ .utc_timestamp = 1, .stage = 2, .wpm = 30, .accuracy = 97, .active_seconds = 30, .top_accidental_hold = .{ 'a', 2 }, .top_accidental_tap = .{ 'o', 1 } };
    const tags = try lessonTags(arena, run, null, null);
    try t.expectEqualStrings("A → hold ×2", tags.hold.?);
    try t.expectEqualStrings("O → tap ×1", tags.tap.?);
}

test "a key's hold comes from the profile when no labels are known" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = tap_hold.testProfile();
    p.space_key = 6;
    try t.expectEqual(@as(?usize, 3), keyOf(&p, 'f'));
    try t.expectEqual(@as(?usize, 6), keyOf(&p, ' '));
    try t.expectEqual(@as(?usize, null), keyOf(&p, 'q'));
    const f = try roleOfChar(arena, &p, null, 'f');
    try t.expectEqualStrings("Shift", f.name);
    try t.expectEqualStrings("⇧", f.glyph);
    const space = try roleOfChar(arena, &p, null, ' ');
    try t.expectEqualStrings("Layer 1", space.name);
    try t.expectEqualStrings("hold", (try roleOfChar(arena, &p, null, 'a')).name);
}
