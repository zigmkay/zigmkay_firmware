//! Headless keyboard layout profile derivation for the adaptive typing tutor.
//! Automatically derives finger assignments, home-row anchors, ergonomic unlock
//! zones, Shift/Layer/Combo routes, and a deterministic profile signature from
//! physical board geometry, resolved OS key labels, and combo definitions.
const std = @import("std");
const practice = @import("practice.zig");

pub const max_keys = 128;
pub const max_layers = 16;
pub const max_shift_providers = 16;
pub const max_layer_activators = 32;
pub const max_routes = 128;
pub const max_combos = 64;
pub const max_columns_per_hand = 16;

pub const Hand = enum(u8) {
    left,
    right,
    neutral,
};

pub const Group = enum(u8) {
    finger,
    thumb,
};

pub const Fidelity = enum(u8) {
    schematic,
    linear,
};

pub const Finger = enum(u8) {
    unknown = 0,
    left_pinky = 1,
    left_ring = 2,
    left_middle = 3,
    left_index = 4,
    left_thumb = 5,
    right_thumb = 6,
    right_index = 7,
    right_middle = 8,
    right_ring = 9,
    right_pinky = 10,

    pub const count = 11;

    pub fn hand(self: Finger) Hand {
        return switch (self) {
            .unknown => .neutral,
            .left_pinky, .left_ring, .left_middle, .left_index, .left_thumb => .left,
            .right_thumb, .right_index, .right_middle, .right_ring, .right_pinky => .right,
        };
    }

    pub fn name(self: Finger) []const u8 {
        return switch (self) {
            .unknown => "Any finger",
            .left_pinky => "Left pinky",
            .left_ring => "Left ring",
            .left_middle => "Left middle",
            .left_index => "Left index",
            .left_thumb => "Left thumb",
            .right_thumb => "Right thumb",
            .right_index => "Right index",
            .right_middle => "Right middle",
            .right_ring => "Right ring",
            .right_pinky => "Right pinky",
        };
    }
};

pub const GeometryKey = struct {
    key_index: usize,
    x: f32,
    y: f32,
    width: f32 = 1.0,
    height: f32 = 1.0,
    rotation: f32 = 0.0,
    hand: Hand = .neutral,
    group: Group = .finger,
    home_row: bool = false,
};

pub const ComboInput = struct {
    layer: usize,
    key_indices: [2]usize,
    output_cp: ?u21 = null,
    unproven: bool = false,
    dead: bool = false,
    shortcut: bool = false,
};

pub const KeyAssignment = struct {
    hand: Hand = .neutral,
    group: Group = .finger,
    finger: Finger = .unknown,
    home_row: bool = false,
    primary_home_anchor: bool = false,
    inner_index: bool = false,
    outer_pinky: bool = false,
    column_rank: u8 = 0, // 0 = outermost on that hand
    row_offset: i8 = 0, // -1 = upper, 0 = home, +1 = lower
};

pub const ShiftKind = enum(u8) {
    home_row_hold,
    thumb_hold,
    one_shot,
    dedicated,
    hold,
};

pub const ShiftProvider = struct {
    key_index: usize,
    layer: usize = 0,
    hand: Hand,
    finger: Finger,
    modifier_bit: u8, // 0x02 (LShift) or 0x20 (RShift)
    kind: ShiftKind,
};

pub const LayerActivator = struct {
    key_index: usize,
    target_layer: usize,
    hand: Hand,
    finger: Finger,
    one_shot: bool = false,
};

pub const RouteKind = enum(u8) {
    base,
    shifted,
    layer_tap,
    combo,
};

pub const CharRoute = struct {
    cp: u21,
    kind: RouteKind,
    layer: usize,
    key_index: usize,
    combo_key_index: ?usize = null,
    modifiers: u8 = 0,
    layer_activator: ?usize = null,
    layer_one_shot: bool = false,
};

/// Where a character sits, independent of the board: two keyboards with the
/// same layout give the same positions although their key indices differ.
pub const KeyPosition = struct {
    cp: u21,
    layer: u8,
    /// Hand, finger and row of the key; see `LayoutProfile.slot`.
    slot: u16,
    shift: bool,
    combo_slot: ?u16 = null,

    pub fn eql(a: KeyPosition, b: KeyPosition) bool {
        return a.cp == b.cp and
            a.layer == b.layer and
            a.slot == b.slot and
            a.shift == b.shift and
            a.combo_slot == b.combo_slot;
    }
};

/// How a character's position differs between two layouts, most telling first.
pub const MoveReason = enum(u8) {
    key_to_combo,
    combo_to_key,
    other_combo,
    other_layer,
    back_on_base_layer,
    needs_shift,
    drops_shift,
    other_hand,
    other_finger,
    other_row,
    other_column,
};

pub const max_move_reasons = @typeInfo(MoveReason).@"enum".field_values.len;

/// Lists what changed between `old` and `new` positions of one character.
pub fn describeMove(old: KeyPosition, new: KeyPosition, out: *[max_move_reasons]MoveReason) []const MoveReason {
    var len: usize = 0;
    const push = struct {
        fn f(buf: *[max_move_reasons]MoveReason, n: *usize, reason: MoveReason) void {
            buf[n.*] = reason;
            n.* += 1;
        }
    }.f;
    if (old.combo_slot == null and new.combo_slot != null) push(out, &len, .key_to_combo);
    if (old.combo_slot != null and new.combo_slot == null) push(out, &len, .combo_to_key);
    if (old.layer != new.layer) push(out, &len, if (new.layer == 0) .back_on_base_layer else .other_layer);
    if (!old.shift and new.shift) push(out, &len, .needs_shift);
    if (old.shift and !new.shift) push(out, &len, .drops_shift);
    const both_combos = old.combo_slot != null and new.combo_slot != null;
    if (both_combos and (old.slot != new.slot or old.combo_slot.? != new.combo_slot.?)) {
        push(out, &len, .other_combo);
    } else if (!both_combos and old.slot != new.slot) {
        const old_finger: u16 = old.slot & 0xf;
        const new_finger: u16 = new.slot & 0xf;
        const old_hand = (@as(Finger, @fromBackingInt(@intCast(@min(old_finger, Finger.count - 1))))).hand();
        const new_hand = (@as(Finger, @fromBackingInt(@intCast(@min(new_finger, Finger.count - 1))))).hand();
        if (old_hand != new_hand and old_hand != .neutral and new_hand != .neutral) {
            push(out, &len, .other_hand);
        } else if (old_finger != new_finger) {
            push(out, &len, .other_finger);
        }
        if (((old.slot >> 4) & 3) != ((new.slot >> 4) & 3)) push(out, &len, .other_row);
        if (len == 0 or (old_finger == new_finger and ((old.slot >> 4) & 3) == ((new.slot >> 4) & 3)))
            push(out, &len, .other_column);
    }
    return out[0..len];
}

pub const DeriveOptions = struct {
    host_layout: []const u8 = "default",
    fidelity: Fidelity = .schematic,
    combos: []const ComboInput = &.{},
};

/// Standard public-domain English letter frequency order (most frequent first).
pub const english_letter_frequency = "etaoinshrdlcumwfgypbvkjxqz";
pub const punctuation_chars = ".,?!-'\":;";
pub const programming_symbol_chars = "{}[]()<>+-=*/|\\:;@#$%^&_|~`!?";

pub const LayoutProfile = struct {
    key_count: usize = 0,
    layer_count: usize = 0,
    fidelity: Fidelity = .schematic,

    keys: [max_keys]KeyAssignment = @splat(.{}),
    finger_home_keys: [Finger.count]?usize = @splat(null),
    space_key: ?usize = null,

    /// Lowercase ASCII letters in automatic layout-first unlock order.
    unlock_order: [26]u8 = @splat(0),
    unlock_len: usize = 0,
    /// Number of initial Zone 1 (primary home-row anchor) letters.
    zone1_len: usize = 0,
    /// Number of Zone 2 (inner home-row) letters.
    zone2_len: usize = 0,
    /// Vowel count in the initial Zone 1 home-row letter pool.
    zone1_vowel_count: u8 = 0,
    /// When zone1_vowel_count < 2, the prioritized top-row vowel placed first after Zone 1.
    priority_vowel: ?u8 = null,

    shifts: [max_shift_providers]ShiftProvider = undefined,
    shift_len: usize = 0,
    has_left_shift: bool = false,
    has_right_shift: bool = false,
    has_altgr: bool = false,

    layer_activators: [max_layer_activators]LayerActivator = undefined,
    layer_activator_len: usize = 0,

    routes: [max_routes]CharRoute = undefined,
    route_len: usize = 0,
    /// The character each key types on the base layer without modifiers;
    /// 0 for none. Unlike `routes` it names every key, not one per character.
    base_taps: [max_keys]u21 = @splat(0),

    punctuation: [16]u8 = @splat(0),
    punctuation_len: usize = 0,
    digits: [10]u8 = @splat(0),
    digits_len: usize = 0,
    symbols: [40]u8 = @splat(0),
    symbols_len: usize = 0,
    layer_symbols: [40]u8 = @splat(0),
    layer_symbols_len: usize = 0,

    combos: [max_combos]CharRoute = undefined,
    combo_len: usize = 0,

    /// Sorted per-character physical key positions; see `LearningModel.adoptPositions`.
    key_positions: [max_routes]KeyPosition = undefined,
    key_position_len: usize = 0,

    /// Identity of the layout type: home-row letters and host layout. It does
    /// not depend on the board, so progress carries over between keyboards.
    profile_hash: [32]u8 = @splat(0),
    /// Exact content digest of key_positions for quick change detection.
    positions_digest: [32]u8 = @splat(0),

    pub fn unlockSlice(self: *const LayoutProfile) []const u8 {
        return self.unlock_order[0..self.unlock_len];
    }

    pub fn zone1Letters(self: *const LayoutProfile) []const u8 {
        return self.unlock_order[0..self.zone1_len];
    }

    pub fn lowVowelHomeRow(self: *const LayoutProfile) bool {
        return self.zone1_vowel_count < 2;
    }

    pub fn shiftSlice(self: *const LayoutProfile) []const ShiftProvider {
        return self.shifts[0..self.shift_len];
    }

    pub fn layerActivatorSlice(self: *const LayoutProfile) []const LayerActivator {
        return self.layer_activators[0..self.layer_activator_len];
    }

    pub fn routeSlice(self: *const LayoutProfile) []const CharRoute {
        return self.routes[0..self.route_len];
    }

    pub fn comboSlice(self: *const LayoutProfile) []const CharRoute {
        return self.combos[0..self.combo_len];
    }

    /// The finger position of a key: finger (which implies the hand), row and
    /// the inner-index and outer-pinky columns. Thumb keys and keys without a
    /// finger also carry their column, since nothing else tells them apart.
    pub fn slot(self: *const LayoutProfile, key_index: usize) u16 {
        if (key_index >= self.key_count) return 0xffff;
        const key = self.keys[key_index];
        const row: u16 = @intCast(std.math.clamp(@as(i16, key.row_offset) + 2, 0, 3));
        var value: u16 = @backingInt(key.finger);
        value |= row << 4;
        value |= @as(u16, @intFromBool(key.inner_index)) << 6;
        value |= @as(u16, @intFromBool(key.outer_pinky)) << 7;
        if (key.finger == .unknown or key.group == .thumb) {
            value |= @as(u16, @min(key.column_rank, 15)) << 8;
            value |= @as(u16, @backingInt(key.hand)) << 12;
        }
        return value;
    }

    pub fn keyPositionSlice(self: *const LayoutProfile) []const KeyPosition {
        return self.key_positions[0..self.key_position_len];
    }

    pub fn punctuationSlice(self: *const LayoutProfile) []const u8 {
        return self.punctuation[0..self.punctuation_len];
    }

    pub fn digitsSlice(self: *const LayoutProfile) []const u8 {
        return self.digits[0..self.digits_len];
    }

    pub fn symbolsSlice(self: *const LayoutProfile) []const u8 {
        return self.symbols[0..self.symbols_len];
    }

    pub fn layerSymbolsSlice(self: *const LayoutProfile) []const u8 {
        return self.layer_symbols[0..self.layer_symbols_len];
    }

    pub fn fingerFor(self: *const LayoutProfile, key_index: usize) Finger {
        if (key_index >= self.key_count) return .unknown;
        return self.keys[key_index].finger;
    }

    pub fn handFor(self: *const LayoutProfile, key_index: usize) Hand {
        if (key_index >= self.key_count) return .neutral;
        return self.keys[key_index].hand;
    }

    pub fn homeAnchorFor(self: *const LayoutProfile, finger: Finger) ?usize {
        return self.finger_home_keys[@backingInt(finger)];
    }

    pub fn routeFor(self: *const LayoutProfile, cp: u21) ?CharRoute {
        for (self.routeSlice()) |route| {
            if (route.cp == cp) return route;
        }
        return null;
    }

    /// The character `key_index` types on tap on `layer`, or null when it
    /// knows none there. Other layers only know the characters of their routes.
    pub fn tapCharFor(self: *const LayoutProfile, key_index: usize, layer: usize) ?u21 {
        if (key_index >= self.key_count) return null;
        if (layer > 0) {
            for (self.routeSlice()) |route| {
                if (route.kind == .layer_tap and route.layer == layer and route.key_index == key_index and route.modifiers == 0) return route.cp;
            }
            return null;
        }
        const cp = self.base_taps[key_index];
        return if (cp == 0) null else cp;
    }

    pub fn comboFor(self: *const LayoutProfile, cp: u21) ?CharRoute {
        for (self.comboSlice()) |combo| {
            if (combo.cp == cp) return combo;
        }
        return null;
    }

    pub fn preferredShiftFor(self: *const LayoutProfile, target_key: usize) ?ShiftProvider {
        const target_hand = self.handFor(target_key);
        var best: ?ShiftProvider = null;
        var best_score: u32 = 0;
        for (self.shiftSlice()) |provider| {
            if (provider.key_index == target_key) continue;
            var score: u32 = 1;
            if (target_hand != .neutral and provider.hand != .neutral and provider.hand != target_hand) {
                score += 64;
            }
            score += switch (provider.kind) {
                .home_row_hold => 16,
                .thumb_hold => 12,
                .one_shot => 8,
                .dedicated => 6,
                .hold => 4,
            };
            if (score > best_score) {
                best_score = score;
                best = provider;
            }
        }
        return best;
    }

    pub fn preferredLayerActivatorFor(self: *const LayoutProfile, target_layer: usize, target_key: usize) ?LayerActivator {
        const target_hand = self.handFor(target_key);
        var best: ?LayerActivator = null;
        var best_score: u32 = 0;
        for (self.layerActivatorSlice()) |act| {
            if (act.target_layer != target_layer or act.key_index == target_key) continue;
            var score: u32 = 1;
            if (target_hand != .neutral and act.hand != .neutral and act.hand != target_hand) {
                score += 32;
            }
            if (!act.one_shot) score += 4;
            if (self.keys[act.key_index].group == .thumb) score += 8;
            if (score > best_score) {
                best_score = score;
                best = act;
            }
        }
        return best;
    }

    pub fn toPracticeMetadata(self: *const LayoutProfile, out: []practice.KeyMetadata) ![]practice.KeyMetadata {
        if (out.len < self.key_count) return error.InvalidDimensions;
        for (0..self.key_count) |i| {
            out[i] = .{
                .hand = switch (self.keys[i].hand) {
                    .left => .left,
                    .right => .right,
                    .neutral => .neutral,
                },
                .thumb = self.keys[i].group == .thumb,
                .home_row = self.keys[i].home_row,
            };
        }
        return out[0..self.key_count];
    }
};

pub fn derive(
    geometry: []const GeometryKey,
    labels: practice.Labels,
    options: DeriveOptions,
) !LayoutProfile {
    try labels.validate();
    if (labels.key_count > max_keys or labels.layer_count > max_layers) return error.InvalidDimensions;
    if (geometry.len != labels.key_count) return error.InvalidDimensions;

    var profile: LayoutProfile = .{
        .key_count = labels.key_count,
        .layer_count = labels.layer_count,
        .fidelity = options.fidelity,
    };

    var geo_by_index: [max_keys]GeometryKey = undefined;
    var seen: [max_keys]bool = @splat(false);
    for (geometry) |g| {
        if (g.key_index >= labels.key_count or seen[g.key_index]) return error.InvalidGeometry;
        seen[g.key_index] = true;
        geo_by_index[g.key_index] = g;
    }

    assignFingers(&profile, geo_by_index[0..labels.key_count], options.fidelity);
    discoverSpaceAndAnchors(&profile, geo_by_index[0..labels.key_count], labels);
    discoverShiftsAndLayers(&profile, labels);
    discoverRoutesAndInventories(&profile, labels, options.combos);
    deriveUnlockOrder(&profile, labels);
    buildKeyPositionsAndHashes(&profile, options);

    return profile;
}

fn assignFingers(profile: *LayoutProfile, geo: []const GeometryKey, fidelity: Fidelity) void {
    for (geo, 0..) |g, idx| {
        profile.keys[idx] = .{
            .hand = g.hand,
            .group = g.group,
            .finger = .unknown,
            .home_row = if (fidelity == .schematic) g.home_row else false,
        };
    }

    if (fidelity == .linear) return;

    // Assign thumbs first.
    for (geo, 0..) |g, idx| {
        if (g.group == .thumb) {
            profile.keys[idx].finger = switch (g.hand) {
                .left => .left_thumb,
                .right => .right_thumb,
                .neutral => .unknown,
            };
        }
    }

    // Group finger keys per hand by unique x columns sorted outer-to-inner.
    for ([_]Hand{ .left, .right }) |side| {
        var cols: [max_columns_per_hand]f32 = undefined;
        var col_count: usize = 0;

        for (geo) |g| {
            if (g.group != .finger or g.hand != side) continue;
            if (!containsColumn(cols[0..col_count], g.x)) {
                if (col_count < max_columns_per_hand) {
                    cols[col_count] = g.x;
                    col_count += 1;
                }
            }
        }
        if (col_count == 0) continue;

        // Sort outer-to-inner: ascending for left hand, descending for right hand.
        for (0..col_count) |i| {
            for (i + 1..col_count) |j| {
                const swap = if (side == .left) cols[j] < cols[i] else cols[j] > cols[i];
                if (swap) std.mem.swap(f32, &cols[i], &cols[j]);
            }
        }

        // Compute home_y per column so row_offset (-1 upper, 0 home, +1 lower) is accurate.
        var col_home_y: [max_columns_per_hand]?f32 = @splat(null);
        for (geo) |g| {
            if (g.group != .finger or g.hand != side or !g.home_row) continue;
            if (findColumn(cols[0..col_count], g.x)) |rank| {
                col_home_y[rank] = g.y;
            }
        }

        for (geo, 0..) |g, idx| {
            if (g.group != .finger or g.hand != side) continue;
            const rank = findColumn(cols[0..col_count], g.x) orelse continue;
            const mapping = mapColumnToFinger(side, rank, col_count);
            profile.keys[idx].finger = mapping.finger;
            profile.keys[idx].column_rank = @intCast(rank);
            profile.keys[idx].inner_index = mapping.inner_index;
            profile.keys[idx].outer_pinky = mapping.outer_pinky;
            profile.keys[idx].primary_home_anchor = g.home_row and !mapping.inner_index and !mapping.outer_pinky;

            if (col_home_y[rank]) |hy| {
                const dy = g.y - hy;
                if (dy < -0.4) {
                    profile.keys[idx].row_offset = -1;
                } else if (dy > 0.4) {
                    profile.keys[idx].row_offset = 1;
                } else {
                    profile.keys[idx].row_offset = 0;
                }
            }

            if (profile.keys[idx].primary_home_anchor) {
                profile.finger_home_keys[@backingInt(mapping.finger)] = idx;
            }
        }
    }
}

const ColumnMapping = struct {
    finger: Finger,
    inner_index: bool = false,
    outer_pinky: bool = false,
};

fn mapColumnToFinger(side: Hand, rank: usize, col_count: usize) ColumnMapping {
    const pinky: Finger = if (side == .left) .left_pinky else .right_pinky;
    const ring: Finger = if (side == .left) .left_ring else .right_ring;
    const middle: Finger = if (side == .left) .left_middle else .right_middle;
    const index: Finger = if (side == .left) .left_index else .right_index;

    if (col_count <= 4) {
        return switch (rank) {
            0 => .{ .finger = pinky },
            1 => .{ .finger = ring },
            2 => .{ .finger = middle },
            else => .{ .finger = index },
        };
    }
    if (col_count == 5) {
        return switch (rank) {
            0 => .{ .finger = pinky },
            1 => .{ .finger = ring },
            2 => .{ .finger = middle },
            3 => .{ .finger = index },
            else => .{ .finger = index, .inner_index = true },
        };
    }
    // 6+ columns per hand (e.g. Molekula): outer columns are pinky, inner 4 are ring/middle/index/inner-index.
    const primary_pinky_rank = col_count - 5;
    if (rank < primary_pinky_rank) return .{ .finger = pinky, .outer_pinky = true };
    if (rank == primary_pinky_rank) return .{ .finger = pinky };
    if (rank == col_count - 4) return .{ .finger = ring };
    if (rank == col_count - 3) return .{ .finger = middle };
    if (rank == col_count - 2) return .{ .finger = index };
    return .{ .finger = index, .inner_index = true };
}

fn containsColumn(cols: []const f32, x: f32) bool {
    return findColumn(cols, x) != null;
}

fn findColumn(cols: []const f32, x: f32) ?usize {
    for (cols, 0..) |cx, i| {
        if (@abs(cx - x) < 0.25) return i;
    }
    return null;
}

fn discoverSpaceAndAnchors(profile: *LayoutProfile, geo: []const GeometryKey, labels: practice.Labels) void {
    var best_space: ?usize = null;
    var best_space_is_thumb = false;
    for (0..profile.key_count) |idx| {
        const entry = labels.get(0, idx, 0, 1);
        if (entry.unproven or entry.dead or entry.shortcut) continue;
        const is_space = (entry.hid_code != null and entry.hid_code.? == 44) or
            (entry.text != null and std.mem.eql(u8, entry.text.?, " "));
        if (is_space) {
            const is_thumb = profile.keys[idx].group == .thumb;
            if (best_space == null or (is_thumb and !best_space_is_thumb)) {
                best_space = idx;
                best_space_is_thumb = is_thumb;
            }
        }
    }
    profile.space_key = best_space;

    if (profile.fidelity == .linear) return;

    // Assign thumb home anchors (prefer space thumb on its hand, else upright rotation==0 thumb).
    for ([_]struct { hand: Hand, finger: Finger }{
        .{ .hand = .left, .finger = .left_thumb },
        .{ .hand = .right, .finger = .right_thumb },
    }) |pair| {
        var anchor: ?usize = null;
        if (best_space) |sk| {
            if (profile.keys[sk].group == .thumb and profile.keys[sk].hand == pair.hand) {
                anchor = sk;
            }
        }
        if (anchor == null) {
            for (geo, 0..) |g, idx| {
                if (g.group == .thumb and g.hand == pair.hand and @abs(g.rotation) < 0.5) {
                    anchor = idx;
                    break;
                }
            }
        }
        if (anchor == null) {
            for (geo, 0..) |g, idx| {
                if (g.group == .thumb and g.hand == pair.hand) {
                    anchor = idx;
                    break;
                }
            }
        }
        profile.finger_home_keys[@backingInt(pair.finger)] = anchor;
    }
}

fn discoverShiftsAndLayers(profile: *LayoutProfile, labels: practice.Labels) void {
    for (0..profile.key_count) |idx| {
        const entry = labels.get(0, idx, 0, 1);
        if (entry.provider_unknown) continue;

        // Check Shift providers.
        const hold_mods = entry.hold_modifiers orelse 0;
        const os_mods = entry.one_shot_modifiers;
        const hid_mod: u8 = if (entry.hid_code) |code|
            (if (code >= 224 and code <= 231) @as(u8, 1) << @intCast(code - 224) else 0)
        else
            0;

        if ((hold_mods | os_mods | hid_mod) & 0x40 != 0) {
            profile.has_altgr = true;
        }

        if (hold_mods & 0x22 != 0) {
            const bit: u8 = if (hold_mods & 0x02 != 0) 0x02 else 0x20;
            const kind: ShiftKind = if (profile.keys[idx].home_row)
                .home_row_hold
            else if (profile.keys[idx].group == .thumb)
                .thumb_hold
            else
                .hold;
            addShiftProvider(profile, .{
                .key_index = idx,
                .layer = 0,
                .hand = profile.keys[idx].hand,
                .finger = profile.keys[idx].finger,
                .modifier_bit = bit,
                .kind = kind,
            });
        }
        if (os_mods & 0x22 != 0) {
            const bit: u8 = if (os_mods & 0x02 != 0) 0x02 else 0x20;
            addShiftProvider(profile, .{
                .key_index = idx,
                .layer = 0,
                .hand = profile.keys[idx].hand,
                .finger = profile.keys[idx].finger,
                .modifier_bit = bit,
                .kind = .one_shot,
            });
        }
        if (hid_mod & 0x22 != 0) {
            const bit: u8 = if (hid_mod & 0x02 != 0) 0x02 else 0x20;
            addShiftProvider(profile, .{
                .key_index = idx,
                .layer = 0,
                .hand = profile.keys[idx].hand,
                .finger = profile.keys[idx].finger,
                .modifier_bit = bit,
                .kind = .dedicated,
            });
        }

        // Check Layer activators (hold_layer or one_shot_layer).
        if (entry.hold_layer) |target| {
            if (target > 0 and target < profile.layer_count) {
                addLayerActivator(profile, .{
                    .key_index = idx,
                    .target_layer = target,
                    .hand = profile.keys[idx].hand,
                    .finger = profile.keys[idx].finger,
                    .one_shot = false,
                });
            }
        }
        if (entry.one_shot_layer) |target| {
            if (target > 0 and target < profile.layer_count) {
                addLayerActivator(profile, .{
                    .key_index = idx,
                    .target_layer = target,
                    .hand = profile.keys[idx].hand,
                    .finger = profile.keys[idx].finger,
                    .one_shot = true,
                });
            }
        }
    }
}

fn addShiftProvider(profile: *LayoutProfile, provider: ShiftProvider) void {
    if (profile.shift_len >= max_shift_providers) return;
    profile.shifts[profile.shift_len] = provider;
    profile.shift_len += 1;
    if (provider.hand == .left) profile.has_left_shift = true;
    if (provider.hand == .right) profile.has_right_shift = true;
}

fn addLayerActivator(profile: *LayoutProfile, activator: LayerActivator) void {
    if (profile.layer_activator_len >= max_layer_activators) return;
    profile.layer_activators[profile.layer_activator_len] = activator;
    profile.layer_activator_len += 1;
}

fn literalCodepoint(entry: practice.Label) ?u21 {
    if (entry.unproven or entry.dead or entry.shortcut) return null;
    if (entry.hid_code) |code| {
        if (code == 44) return ' ';
        if (code == 40) return '\n';
        if (code == 43) return '\t';
    }
    const text = entry.text orelse return null;
    if (text.len == 0) return null;
    const cp_len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (cp_len != text.len) return null;
    const cp = std.unicode.utf8Decode(text) catch return null;
    if (cp < 0x20 or cp == 0x7f) return null;
    return cp;
}

fn addRouteIfNew(profile: *LayoutProfile, route: CharRoute) void {
    for (profile.routes[0..profile.route_len]) |existing| {
        if (existing.cp == route.cp) return;
    }
    if (profile.route_len < max_routes) {
        profile.routes[profile.route_len] = route;
        profile.route_len += 1;
    }
}

fn discoverRoutesAndInventories(
    profile: *LayoutProfile,
    labels: practice.Labels,
    combos: []const ComboInput,
) void {
    // Pass 1: Base layer (layer 0, mods = 0).
    for (0..profile.key_count) |idx| {
        const entry = labels.get(0, idx, 0, 1);
        const cp = literalCodepoint(entry) orelse continue;
        profile.base_taps[idx] = cp;
        addRouteIfNew(profile, .{
            .cp = cp,
            .kind = .base,
            .layer = 0,
            .key_index = idx,
            .modifiers = 0,
        });
    }

    // Pass 2: Base layer with Shift (if any Shift provider exists).
    if (profile.shift_len > 0) {
        for (0..profile.key_count) |idx| {
            const shift_provider = profile.preferredShiftFor(idx) orelse continue;
            const entry = labels.get(0, idx, shift_provider.modifier_bit, 1);
            const cp = literalCodepoint(entry) orelse continue;
            addRouteIfNew(profile, .{
                .cp = cp,
                .kind = .shifted,
                .layer = 0,
                .key_index = idx,
                .modifiers = shift_provider.modifier_bit,
            });
        }
    }

    // Pass 3: Non-base layers with a reachable activator on Base layer.
    for (1..profile.layer_count) |layer| {
        // Check if this layer is reachable at all.
        var reachable = false;
        for (profile.layerActivatorSlice()) |act| {
            if (act.target_layer == layer) {
                reachable = true;
                break;
            }
        }
        if (!reachable) continue;

        const mask = practice.layerMask(layer);
        // Unshifted on layer first.
        for (0..profile.key_count) |idx| {
            const act = profile.preferredLayerActivatorFor(layer, idx) orelse continue;
            const entry = labels.get(layer, idx, 0, mask);
            const cp = literalCodepoint(entry) orelse continue;
            addRouteIfNew(profile, .{
                .cp = cp,
                .kind = .layer_tap,
                .layer = layer,
                .key_index = idx,
                .modifiers = 0,
                .layer_activator = act.key_index,
                .layer_one_shot = act.one_shot,
            });
        }
        // Shifted on layer next (if Shift exists).
        if (profile.shift_len > 0) {
            for (0..profile.key_count) |idx| {
                const act = profile.preferredLayerActivatorFor(layer, idx) orelse continue;
                const shift_provider = profile.preferredShiftFor(idx) orelse continue;
                const entry = labels.get(layer, idx, shift_provider.modifier_bit, mask);
                const cp = literalCodepoint(entry) orelse continue;
                addRouteIfNew(profile, .{
                    .cp = cp,
                    .kind = .layer_tap,
                    .layer = layer,
                    .key_index = idx,
                    .modifiers = shift_provider.modifier_bit,
                    .layer_activator = act.key_index,
                    .layer_one_shot = act.one_shot,
                });
            }
        }
    }

    // Pass 4: 2-key text-producing combos.
    for (combos) |combo| {
        if (combo.unproven or combo.dead or combo.shortcut) continue;
        if (combo.layer >= profile.layer_count) continue;
        const k0 = combo.key_indices[0];
        const k1 = combo.key_indices[1];
        if (k0 >= profile.key_count or k1 >= profile.key_count or k0 == k1) continue;
        const cp = combo.output_cp orelse continue;
        if (cp < 0x20 or cp == 0x7f) continue;

        var layer_act: ?usize = null;
        var layer_os = false;
        if (combo.layer > 0) {
            const act = profile.preferredLayerActivatorFor(combo.layer, k0) orelse continue;
            layer_act = act.key_index;
            layer_os = act.one_shot;
        }

        const route: CharRoute = .{
            .cp = cp,
            .kind = .combo,
            .layer = combo.layer,
            .key_index = k0,
            .combo_key_index = k1,
            .modifiers = 0,
            .layer_activator = layer_act,
            .layer_one_shot = layer_os,
        };
        if (profile.combo_len < max_combos) {
            profile.combos[profile.combo_len] = route;
            profile.combo_len += 1;
        }
        addRouteIfNew(profile, route);
    }

    // Populate categorized inventories from discovered routes.
    for (punctuation_chars) |ch| {
        if (profile.routeFor(ch) != null and profile.punctuation_len < profile.punctuation.len) {
            profile.punctuation[profile.punctuation_len] = ch;
            profile.punctuation_len += 1;
        }
    }
    for ('0'..'9' + 1) |d| {
        const ch: u8 = @intCast(d);
        if (profile.routeFor(ch) != null and profile.digits_len < profile.digits.len) {
            profile.digits[profile.digits_len] = ch;
            profile.digits_len += 1;
        }
    }
    for (programming_symbol_chars) |ch| {
        if (std.mem.indexOfScalar(u8, profile.symbols[0..profile.symbols_len], ch) != null) continue;
        if (profile.routeFor(ch)) |route| {
            if (profile.symbols_len < profile.symbols.len) {
                profile.symbols[profile.symbols_len] = ch;
                profile.symbols_len += 1;
            }
            if (route.kind == .layer_tap and profile.layer_symbols_len < profile.layer_symbols.len) {
                profile.layer_symbols[profile.layer_symbols_len] = ch;
                profile.layer_symbols_len += 1;
            }
        }
    }
}

fn isVowel(ch: u8) bool {
    return ch == 'a' or ch == 'e' or ch == 'i' or ch == 'o' or ch == 'u';
}

fn englishFreqRank(ch: u8) usize {
    return std.mem.indexOfScalar(u8, english_letter_frequency, ch) orelse 26;
}

const LetterCandidate = struct {
    ch: u8,
    group: u8, // 0 = zone1, 1 = zone2, 2 = index/middle, 3 = ring, 4 = pinky, 5 = other
    freq_rank: usize,
    key_index: usize,
    is_top_row: bool,
};

fn deriveUnlockOrder(profile: *LayoutProfile, labels: practice.Labels) void {
    var candidates: [26]LetterCandidate = undefined;
    var count: usize = 0;
    var present: [26]bool = @splat(false);

    // Prefer Base-layer routes for lowercase letters first, then any discovered route.
    for (0..profile.key_count) |idx| {
        const entry = labels.get(0, idx, 0, 1);
        const cp = literalCodepoint(entry) orelse continue;
        if (cp < 'a' or cp > 'z') continue;
        const ch: u8 = @intCast(cp);
        if (present[ch - 'a']) continue;
        present[ch - 'a'] = true;

        const ka = profile.keys[idx];
        const reach_group: u8 = if (profile.fidelity == .linear)
            5
        else if (ka.primary_home_anchor)
            0
        else if (ka.home_row and ka.inner_index)
            1
        else switch (ka.finger) {
            .left_index, .right_index, .left_middle, .right_middle => 2,
            .left_ring, .right_ring => 3,
            .left_pinky, .right_pinky => 4,
            else => 5,
        };

        candidates[count] = .{
            .ch = ch,
            .group = reach_group,
            .freq_rank = englishFreqRank(ch),
            .key_index = idx,
            .is_top_row = ka.row_offset < 0,
        };
        count += 1;
    }

    // Include any remaining lowercase letters reachable via non-base layers or combos.
    for (profile.routeSlice()) |route| {
        if (route.cp < 'a' or route.cp > 'z') continue;
        const ch: u8 = @intCast(route.cp);
        if (present[ch - 'a']) continue;
        present[ch - 'a'] = true;
        candidates[count] = .{
            .ch = ch,
            .group = 5,
            .freq_rank = englishFreqRank(ch),
            .key_index = route.key_index,
            .is_top_row = false,
        };
        count += 1;
    }

    // Sort candidates: by reach group ascending, then within Zone 1 by key_index (left-to-right),
    // and within Zones 2+ by English letter frequency ascending (most frequent first).
    for (0..count) |i| {
        for (i + 1..count) |j| {
            const a = candidates[i];
            const b = candidates[j];
            const b_before_a = if (a.group != b.group)
                b.group < a.group
            else if (a.group == 0)
                b.key_index < a.key_index
            else if (a.freq_rank != b.freq_rank)
                b.freq_rank < a.freq_rank
            else
                b.key_index < a.key_index;
            if (b_before_a) std.mem.swap(LetterCandidate, &candidates[i], &candidates[j]);
        }
    }

    var zone1_len: usize = 0;
    var zone2_len: usize = 0;
    var zone1_vowels: u8 = 0;
    for (candidates[0..count]) |c| {
        if (c.group == 0) {
            zone1_len += 1;
            if (isVowel(c.ch)) zone1_vowels += 1;
        } else if (c.group == 1) {
            zone2_len += 1;
        }
    }

    // Linear fallback boards have no home_row metadata; start with the first 8 letters by frequency.
    if (profile.fidelity == .linear and zone1_len == 0) {
        zone1_len = @min(@as(usize, 8), count);
        zone1_vowels = 0;
        for (candidates[0..zone1_len]) |c| {
            if (isVowel(c.ch)) zone1_vowels += 1;
        }
    }

    // Low-vowel home-row prioritization: when Zone 1 has < 2 vowels (e.g. QWERTY),
    // promote the highest-frequency reachable top-row vowel (e.g. 'e') right after Zone 1.
    var priority_vowel: ?u8 = null;
    if (zone1_vowels < 2 and count > zone1_len) {
        var best_idx: ?usize = null;
        for (zone1_len..count) |i| {
            const c = candidates[i];
            if (!isVowel(c.ch)) continue;
            if (best_idx == null) {
                best_idx = i;
            } else {
                const cur = candidates[best_idx.?];
                const better = (c.is_top_row and !cur.is_top_row) or
                    (c.is_top_row == cur.is_top_row and c.freq_rank < cur.freq_rank);
                if (better) best_idx = i;
            }
        }
        if (best_idx) |idx| {
            const chosen = candidates[idx];
            priority_vowel = chosen.ch;
            // Shift elements right to place chosen immediately at zone1_len.
            var k = idx;
            while (k > zone1_len) : (k -= 1) {
                candidates[k] = candidates[k - 1];
            }
            candidates[zone1_len] = chosen;
        }
    }

    profile.unlock_len = count;
    profile.zone1_len = zone1_len;
    profile.zone2_len = zone2_len;
    profile.zone1_vowel_count = zone1_vowels;
    profile.priority_vowel = priority_vowel;
    for (0..count) |i| {
        profile.unlock_order[i] = candidates[i].ch;
    }
}

fn buildKeyPositionsAndHashes(profile: *LayoutProfile, options: DeriveOptions) void {
    var pos_len: usize = 0;
    for (profile.routeSlice()) |route| {
        if (pos_len >= max_routes) break;
        profile.key_positions[pos_len] = .{
            .cp = route.cp,
            .layer = @intCast(route.layer),
            .slot = profile.slot(route.key_index),
            .shift = (route.modifiers & 0x22) != 0,
            .combo_slot = if (route.combo_key_index) |ck| profile.slot(ck) else null,
        };
        pos_len += 1;
    }
    // Sort deterministically by codepoint.
    for (0..pos_len) |i| {
        for (i + 1..pos_len) |j| {
            if (profile.key_positions[j].cp < profile.key_positions[i].cp) {
                std.mem.swap(KeyPosition, &profile.key_positions[i], &profile.key_positions[j]);
            }
        }
    }
    profile.key_position_len = pos_len;

    // Exact positions digest.
    var pos_hash = std.crypto.hash.sha2.Sha256.init(.{});
    pos_hash.update("zigmkay-tutor-positions-v2\x00");
    for (profile.keyPositionSlice()) |pos| {
        var cp_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &cp_buf, pos.cp, .little);
        pos_hash.update(&cp_buf);
        var slots: [4]u8 = undefined;
        std.mem.writeInt(u16, slots[0..2], pos.slot, .little);
        std.mem.writeInt(u16, slots[2..4], pos.combo_slot orelse 0xffff, .little);
        pos_hash.update(&slots);
        pos_hash.update(&.{ pos.layer, @intFromBool(pos.shift) });
    }
    profile.positions_digest = pos_hash.finalResult();

    // The profile is a layout type, not a keyboard: home-row letters keep
    // QWERTY and Colemak apart, and the board is left out on purpose so the
    // same layout on two keyboards shares its progress.
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-tutor-profile-v2\x00");
    hash.update(profile.zone1Letters());
    hash.update(&.{0});
    hash.update(options.host_layout);
    profile.profile_hash = hash.finalResult();
}

// ---------------------------------------------------------------------------
// Unit tests covering all 6 catalog schematics + linear fallback, QWERTY & Colemak-DH
// ---------------------------------------------------------------------------

const TestKey = struct {
    text: ?[]const u8 = null,
    shifted: ?[]const u8 = null,
    layer1: ?[]const u8 = null,
    hid_code: ?u8 = null,
    hold_layer: ?usize = null,
    hold_modifiers: ?u8 = null,
    one_shot_layer: ?usize = null,
    one_shot_modifiers: u8 = 0,
    dead: bool = false,
    shortcut: bool = false,
    unproven: bool = false,
};

const TestLabelsCtx = struct {
    keys: []const TestKey,

    fn lookup(ctx: *const anyopaque, layer: usize, key: usize, mods: u8, _: u16) practice.Label {
        const self: *const @This() = @ptrCast(@alignCast(ctx));
        if (key >= self.keys.len) return .{};
        const k = self.keys[key];
        if (layer == 0) {
            const shifted = (mods & 0x22) != 0;
            return .{
                .text = if (shifted) k.shifted else k.text,
                .hid_code = k.hid_code,
                .hold_layer = k.hold_layer,
                .hold_modifiers = k.hold_modifiers,
                .one_shot_layer = k.one_shot_layer,
                .one_shot_modifiers = k.one_shot_modifiers,
                .dead = k.dead,
                .shortcut = k.shortcut,
                .unproven = k.unproven,
            };
        }
        if (layer == 1) {
            return .{
                .text = if (mods == 0) k.layer1 else null,
            };
        }
        return .{};
    }

    fn labels(self: *const @This(), layer_count: usize) practice.Labels {
        return .{
            .context = self,
            .key_count = self.keys.len,
            .layer_count = layer_count,
            .lookup = lookup,
        };
    }
};

fn schematicKeycaprio34() [34]GeometryKey {
    return .{
        .{ .key_index = 0, .x = 0, .y = 1, .hand = .left },
        .{ .key_index = 1, .x = 1, .y = 0.25, .hand = .left },
        .{ .key_index = 2, .x = 2, .y = 0, .hand = .left },
        .{ .key_index = 3, .x = 3, .y = 0.25, .hand = .left },
        .{ .key_index = 4, .x = 4, .y = 0.5, .hand = .left },
        .{ .key_index = 5, .x = 6.25, .y = 0.5, .hand = .right },
        .{ .key_index = 6, .x = 7.25, .y = 0.25, .hand = .right },
        .{ .key_index = 7, .x = 8.25, .y = 0, .hand = .right },
        .{ .key_index = 8, .x = 9.25, .y = 0.25, .hand = .right },
        .{ .key_index = 9, .x = 10.25, .y = 1, .hand = .right },
        .{ .key_index = 10, .x = 0, .y = 2, .hand = .left, .home_row = true },
        .{ .key_index = 11, .x = 1, .y = 1.25, .hand = .left, .home_row = true },
        .{ .key_index = 12, .x = 2, .y = 1, .hand = .left, .home_row = true },
        .{ .key_index = 13, .x = 3, .y = 1.25, .hand = .left, .home_row = true },
        .{ .key_index = 14, .x = 4, .y = 1.5, .hand = .left, .home_row = true },
        .{ .key_index = 15, .x = 6.25, .y = 1.5, .hand = .right, .home_row = true },
        .{ .key_index = 16, .x = 7.25, .y = 1.25, .hand = .right, .home_row = true },
        .{ .key_index = 17, .x = 8.25, .y = 1, .hand = .right, .home_row = true },
        .{ .key_index = 18, .x = 9.25, .y = 1.25, .hand = .right, .home_row = true },
        .{ .key_index = 19, .x = 10.25, .y = 2, .hand = .right, .home_row = true },
        .{ .key_index = 20, .x = 0, .y = 3, .hand = .left },
        .{ .key_index = 21, .x = 1, .y = 2.25, .hand = .left },
        .{ .key_index = 22, .x = 2, .y = 2, .hand = .left },
        .{ .key_index = 23, .x = 3, .y = 2.25, .hand = .left },
        .{ .key_index = 24, .x = 4, .y = 2.5, .hand = .left },
        .{ .key_index = 25, .x = 6.25, .y = 2.5, .hand = .right },
        .{ .key_index = 26, .x = 7.25, .y = 2.25, .hand = .right },
        .{ .key_index = 27, .x = 8.25, .y = 2, .hand = .right },
        .{ .key_index = 28, .x = 9.25, .y = 2.25, .hand = .right },
        .{ .key_index = 29, .x = 10.25, .y = 3, .hand = .right },
        .{ .key_index = 30, .x = 3.26, .y = 3.97, .hand = .left, .group = .thumb },
        .{ .key_index = 31, .x = 4.35, .y = 4.06, .rotation = 10, .hand = .left, .group = .thumb },
        .{ .key_index = 32, .x = 5.9, .y = 4.06, .rotation = -10, .hand = .right, .group = .thumb },
        .{ .key_index = 33, .x = 6.99, .y = 3.97, .hand = .right, .group = .thumb },
    };
}

fn schematicKeycaprio30() [30]GeometryKey {
    return .{
        .{ .key_index = 0, .x = 0, .y = 1, .hand = .left },
        .{ .key_index = 1, .x = 1, .y = 0.25, .hand = .left },
        .{ .key_index = 2, .x = 2, .y = 0, .hand = .left },
        .{ .key_index = 3, .x = 3, .y = 0.25, .hand = .left },
        .{ .key_index = 4, .x = 4, .y = 0.5, .hand = .left },
        .{ .key_index = 5, .x = 6, .y = 0.5, .hand = .right },
        .{ .key_index = 6, .x = 7, .y = 0.25, .hand = .right },
        .{ .key_index = 7, .x = 8, .y = 0, .hand = .right },
        .{ .key_index = 8, .x = 9, .y = 0.25, .hand = .right },
        .{ .key_index = 9, .x = 10, .y = 1, .hand = .right },
        .{ .key_index = 10, .x = 0, .y = 2, .hand = .left, .home_row = true },
        .{ .key_index = 11, .x = 1, .y = 1.25, .hand = .left, .home_row = true },
        .{ .key_index = 12, .x = 2, .y = 1, .hand = .left, .home_row = true },
        .{ .key_index = 13, .x = 3, .y = 1.25, .hand = .left, .home_row = true },
        .{ .key_index = 14, .x = 4, .y = 1.5, .hand = .left, .home_row = true },
        .{ .key_index = 15, .x = 6, .y = 1.5, .hand = .right, .home_row = true },
        .{ .key_index = 16, .x = 7, .y = 1.25, .hand = .right, .home_row = true },
        .{ .key_index = 17, .x = 8, .y = 1, .hand = .right, .home_row = true },
        .{ .key_index = 18, .x = 9, .y = 1.25, .hand = .right, .home_row = true },
        .{ .key_index = 19, .x = 10, .y = 2, .hand = .right, .home_row = true },
        .{ .key_index = 20, .x = 1, .y = 2.25, .hand = .left },
        .{ .key_index = 21, .x = 2, .y = 2, .hand = .left },
        .{ .key_index = 22, .x = 3, .y = 2.25, .hand = .left },
        .{ .key_index = 23, .x = 4, .y = 2.5, .hand = .left },
        .{ .key_index = 24, .x = 6, .y = 2.5, .hand = .right },
        .{ .key_index = 25, .x = 7, .y = 2.25, .hand = .right },
        .{ .key_index = 26, .x = 8, .y = 2, .hand = .right },
        .{ .key_index = 27, .x = 9, .y = 2.25, .hand = .right },
        .{ .key_index = 28, .x = 4.19, .y = 4.05, .hand = .left, .group = .thumb },
        .{ .key_index = 29, .x = 5.81, .y = 4.05, .hand = .right, .group = .thumb },
    };
}

fn schematicDasbob() [36]GeometryKey {
    return .{
        .{ .key_index = 0, .x = 0, .y = 1.25, .hand = .left },
        .{ .key_index = 1, .x = 1, .y = 0.5, .hand = .left },
        .{ .key_index = 2, .x = 2, .y = 0, .hand = .left },
        .{ .key_index = 3, .x = 3, .y = 0.5, .hand = .left },
        .{ .key_index = 4, .x = 4, .y = 0.5, .hand = .left },
        .{ .key_index = 5, .x = 7.75, .y = 0.5, .hand = .right },
        .{ .key_index = 6, .x = 8.75, .y = 0.5, .hand = .right },
        .{ .key_index = 7, .x = 9.75, .y = 0, .hand = .right },
        .{ .key_index = 8, .x = 10.75, .y = 0.5, .hand = .right },
        .{ .key_index = 9, .x = 11.75, .y = 1.25, .hand = .right },
        .{ .key_index = 10, .x = 0, .y = 2.25, .hand = .left, .home_row = true },
        .{ .key_index = 11, .x = 1, .y = 1.5, .hand = .left, .home_row = true },
        .{ .key_index = 12, .x = 2, .y = 1, .hand = .left, .home_row = true },
        .{ .key_index = 13, .x = 3, .y = 1.5, .hand = .left, .home_row = true },
        .{ .key_index = 14, .x = 4, .y = 1.5, .hand = .left, .home_row = true },
        .{ .key_index = 15, .x = 7.75, .y = 1.5, .hand = .right, .home_row = true },
        .{ .key_index = 16, .x = 8.75, .y = 1.5, .hand = .right, .home_row = true },
        .{ .key_index = 17, .x = 9.75, .y = 1, .hand = .right, .home_row = true },
        .{ .key_index = 18, .x = 10.75, .y = 1.5, .hand = .right, .home_row = true },
        .{ .key_index = 19, .x = 11.75, .y = 2.25, .hand = .right, .home_row = true },
        .{ .key_index = 20, .x = 0, .y = 3.25, .hand = .left },
        .{ .key_index = 21, .x = 1, .y = 2.5, .hand = .left },
        .{ .key_index = 22, .x = 2, .y = 2, .hand = .left },
        .{ .key_index = 23, .x = 3, .y = 2.5, .hand = .left },
        .{ .key_index = 24, .x = 4, .y = 2.5, .hand = .left },
        .{ .key_index = 25, .x = 7.75, .y = 2.5, .hand = .right },
        .{ .key_index = 26, .x = 8.75, .y = 2.5, .hand = .right },
        .{ .key_index = 27, .x = 9.75, .y = 2, .hand = .right },
        .{ .key_index = 28, .x = 10.75, .y = 2.5, .hand = .right },
        .{ .key_index = 29, .x = 11.75, .y = 3.25, .hand = .right },
        .{ .key_index = 30, .x = 2.99, .y = 3.71, .hand = .left, .group = .thumb },
        .{ .key_index = 31, .x = 4.09, .y = 3.81, .rotation = 10, .hand = .left, .group = .thumb },
        .{ .key_index = 32, .x = 5.15, .y = 4.09, .rotation = 20, .hand = .left, .group = .thumb },
        .{ .key_index = 33, .x = 6.6, .y = 4.09, .rotation = -20, .hand = .right, .group = .thumb },
        .{ .key_index = 34, .x = 7.66, .y = 3.81, .rotation = -10, .hand = .right, .group = .thumb },
        .{ .key_index = 35, .x = 8.76, .y = 3.71, .hand = .right, .group = .thumb },
    };
}

fn schematicClackyChan() [30]GeometryKey {
    var g = schematicKeycaprio30();
    g[4].y = 0.25;
    g[5].y = 0.25;
    g[14].y = 1.25;
    g[15].y = 1.25;
    g[23].y = 2.25;
    g[24].y = 2.25;
    g[28] = .{ .key_index = 28, .x = 3.7, .y = 3.85, .hand = .left, .group = .thumb };
    g[29] = .{ .key_index = 29, .x = 6.3, .y = 3.85, .hand = .right, .group = .thumb };
    return g;
}

fn schematicTuckyTwoTimes() [30]GeometryKey {
    var g = schematicClackyChan();
    g[28] = .{ .key_index = 28, .x = 4.14, .y = 3.72, .hand = .left, .group = .thumb };
    g[29] = .{ .key_index = 29, .x = 5.86, .y = 3.72, .hand = .right, .group = .thumb };
    return g;
}

fn schematicMolekula() [38]GeometryKey {
    return .{
        .{ .key_index = 0, .x = 1, .y = 0.5, .hand = .left },
        .{ .key_index = 1, .x = 2, .y = 0.25, .hand = .left },
        .{ .key_index = 2, .x = 3, .y = 0, .hand = .left },
        .{ .key_index = 3, .x = 4, .y = 0.25, .hand = .left },
        .{ .key_index = 4, .x = 5, .y = 0.5, .hand = .left },
        .{ .key_index = 5, .x = 8.25, .y = 0.5, .hand = .right },
        .{ .key_index = 6, .x = 9.25, .y = 0.25, .hand = .right },
        .{ .key_index = 7, .x = 10.25, .y = 0, .hand = .right },
        .{ .key_index = 8, .x = 11.25, .y = 0.25, .hand = .right },
        .{ .key_index = 9, .x = 12.25, .y = 0.5, .hand = .right },
        .{ .key_index = 10, .x = 0, .y = 1.5, .hand = .left, .home_row = true },
        .{ .key_index = 11, .x = 1, .y = 1.5, .hand = .left, .home_row = true },
        .{ .key_index = 12, .x = 2, .y = 1.25, .hand = .left, .home_row = true },
        .{ .key_index = 13, .x = 3, .y = 1, .hand = .left, .home_row = true },
        .{ .key_index = 14, .x = 4, .y = 1.25, .hand = .left, .home_row = true },
        .{ .key_index = 15, .x = 5, .y = 1.5, .hand = .left, .home_row = true },
        .{ .key_index = 16, .x = 8.25, .y = 1.5, .hand = .right, .home_row = true },
        .{ .key_index = 17, .x = 9.25, .y = 1.25, .hand = .right, .home_row = true },
        .{ .key_index = 18, .x = 10.25, .y = 1, .hand = .right, .home_row = true },
        .{ .key_index = 19, .x = 11.25, .y = 1.25, .hand = .right, .home_row = true },
        .{ .key_index = 20, .x = 12.25, .y = 1.5, .hand = .right, .home_row = true },
        .{ .key_index = 21, .x = 13.25, .y = 1.5, .hand = .right, .home_row = true },
        .{ .key_index = 22, .x = 1, .y = 2.5, .hand = .left },
        .{ .key_index = 23, .x = 2, .y = 2.25, .hand = .left },
        .{ .key_index = 24, .x = 3, .y = 2, .hand = .left },
        .{ .key_index = 25, .x = 4, .y = 2.25, .hand = .left },
        .{ .key_index = 26, .x = 5, .y = 2.5, .hand = .left },
        .{ .key_index = 27, .x = 8.25, .y = 2.5, .hand = .right },
        .{ .key_index = 28, .x = 9.25, .y = 2.25, .hand = .right },
        .{ .key_index = 29, .x = 10.25, .y = 2, .hand = .right },
        .{ .key_index = 30, .x = 11.25, .y = 2.25, .hand = .right },
        .{ .key_index = 31, .x = 12.25, .y = 2.5, .hand = .right },
        .{ .key_index = 32, .x = 3.79, .y = 3.75, .hand = .left, .group = .thumb },
        .{ .key_index = 33, .x = 4.89, .y = 3.85, .rotation = 10, .hand = .left, .group = .thumb },
        .{ .key_index = 34, .x = 5.95, .y = 4.13, .rotation = 20, .hand = .left, .group = .thumb },
        .{ .key_index = 35, .x = 7.3, .y = 4.13, .rotation = -20, .hand = .right, .group = .thumb },
        .{ .key_index = 36, .x = 8.36, .y = 3.85, .rotation = -10, .hand = .right, .group = .thumb },
        .{ .key_index = 37, .x = 9.46, .y = 3.75, .hand = .right, .group = .thumb },
    };
}

fn makeQwerty34() [34]TestKey {
    var keys: [34]TestKey = @splat(.{});
    const base = [_][]const u8{
        "q", "w", "e", "r", "t", "y", "u", "i", "o", "p",
        "a", "s", "d", "f", "g", "h", "j", "k", "l", ";",
        "z", "x", "c", "v", "b", "n", "m", ",", ".", "/",
    };
    const shifted = [_][]const u8{
        "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P",
        "A", "S", "D", "F", "G", "H", "J", "K", "L", ":",
        "Z", "X", "C", "V", "B", "N", "M", "<", ">", "?",
    };
    const sym_layer = [_]?[]const u8{
        "1", "2", "3", "4", "5", "6", "7", "8", "9",  "0",
        "{", "}", "[", "]", "(", ")", "-", "=", "+",  "|",
        "!", "@", "#", "$", "%", "^", "&", "*", "\\", "`",
    };
    for (0..30) |i| {
        keys[i].text = base[i];
        keys[i].shifted = shifted[i];
        keys[i].layer1 = sym_layer[i];
    }
    // Home-row hold Shift on F (left index) and J (right index).
    keys[13].hold_modifiers = 0x02;
    keys[16].hold_modifiers = 0x20;
    // Thumbs: left thumb 31 = Space, right thumb 32 = Hold Layer 1.
    keys[31] = .{ .text = " ", .hid_code = 44 };
    keys[32] = .{ .hold_layer = 1 };
    return keys;
}

fn makeColemakDh34() [34]TestKey {
    var keys: [34]TestKey = @splat(.{});
    const base = [_][]const u8{
        "q", "w", "f", "p", "b", "j", "l", "u", "y", ";",
        "a", "r", "s", "t", "g", "m", "n", "e", "i", "o",
        "z", "x", "c", "d", "v", "k", "h", ",", ".", "/",
    };
    const shifted = [_][]const u8{
        "Q", "W", "F", "P", "B", "J", "L", "U", "Y", ":",
        "A", "R", "S", "T", "G", "M", "N", "E", "I", "O",
        "Z", "X", "C", "D", "V", "K", "H", "<", ">", "?",
    };
    const sym_layer = [_]?[]const u8{
        "1", "2",  "3", "4", "5", "6", "7", "8", "9",  "0",
        "{", "}",  "[", "]", "(", ")", "-", "=", "+",  "'",
        "!", "\"", "#", "$", "%", "^", "&", "*", "\\", "~",
    };
    for (0..30) |i| {
        keys[i].text = base[i];
        keys[i].shifted = shifted[i];
        keys[i].layer1 = sym_layer[i];
    }
    // Home-row hold Shift on T (13) and N (16).
    keys[13].hold_modifiers = 0x02;
    keys[16].hold_modifiers = 0x20;
    // Thumbs: right thumb 32 = Space, left thumb 31 = Hold Layer 1.
    keys[31] = .{ .hold_layer = 1 };
    keys[32] = .{ .text = " ", .hid_code = 44 };
    return keys;
}

test "all 6 catalog schematics derive accurate fingers and home anchors plus linear fallback" {
    const t = std.testing;

    // 1. Keycaprio 34 (5 cols/hand, 34 keys)
    {
        const geo = schematicKeycaprio34();
        const keys = makeQwerty34();
        const ctx: TestLabelsCtx = .{ .keys = &keys };
        const p = try derive(&geo, ctx.labels(2), .{});
        try t.expectEqual(Finger.left_pinky, p.fingerFor(10));
        try t.expectEqual(Finger.left_ring, p.fingerFor(11));
        try t.expectEqual(Finger.left_middle, p.fingerFor(12));
        try t.expectEqual(Finger.left_index, p.fingerFor(13));
        try t.expectEqual(Finger.left_index, p.fingerFor(14));
        try t.expect(p.keys[14].inner_index);
        try t.expectEqual(Finger.right_index, p.fingerFor(15));
        try t.expect(p.keys[15].inner_index);
        try t.expectEqual(Finger.right_index, p.fingerFor(16));
        try t.expectEqual(Finger.right_middle, p.fingerFor(17));
        try t.expectEqual(Finger.right_ring, p.fingerFor(18));
        try t.expectEqual(Finger.right_pinky, p.fingerFor(19));
        try t.expectEqual(Finger.left_thumb, p.fingerFor(30));
        try t.expectEqual(Finger.right_thumb, p.fingerFor(33));
        try t.expectEqual(@as(?usize, 10), p.homeAnchorFor(.left_pinky));
        try t.expectEqual(@as(?usize, 13), p.homeAnchorFor(.left_index));
        try t.expectEqual(@as(?usize, 16), p.homeAnchorFor(.right_index));
        try t.expectEqual(@as(?usize, 19), p.homeAnchorFor(.right_pinky));
        try t.expectEqual(@as(?usize, 31), p.space_key);
        try t.expectEqual(@as(i8, -1), p.keys[2].row_offset);
        try t.expectEqual(@as(i8, 0), p.keys[12].row_offset);
        try t.expectEqual(@as(i8, 1), p.keys[22].row_offset);
    }

    // 2. Keycaprio 30, Clacky Chan, Tucky Two Times (5 cols/hand, 30 keys, no bottom pinky)
    inline for (.{ schematicKeycaprio30(), schematicClackyChan(), schematicTuckyTwoTimes() }) |geo| {
        var keys: [30]TestKey = @splat(.{});
        keys[28] = .{ .text = " ", .hid_code = 44 };
        const ctx: TestLabelsCtx = .{ .keys = &keys };
        const p = try derive(&geo, ctx.labels(1), .{});
        try t.expectEqual(Finger.left_ring, p.fingerFor(20)); // bottom row starts at ring
        try t.expectEqual(Finger.right_ring, p.fingerFor(27));
        try t.expectEqual(Finger.left_thumb, p.fingerFor(28));
        try t.expectEqual(Finger.right_thumb, p.fingerFor(29));
        try t.expectEqual(@as(?usize, 10), p.homeAnchorFor(.left_pinky));
        try t.expectEqual(@as(?usize, 19), p.homeAnchorFor(.right_pinky));
    }

    // 3. Dasbob (5 cols/hand, 36 keys, 3 thumbs/hand)
    {
        const geo = schematicDasbob();
        var keys: [36]TestKey = @splat(.{});
        keys[31] = .{ .text = " ", .hid_code = 44 };
        const ctx: TestLabelsCtx = .{ .keys = &keys };
        const p = try derive(&geo, ctx.labels(1), .{});
        try t.expectEqual(Finger.left_thumb, p.fingerFor(30));
        try t.expectEqual(Finger.left_thumb, p.fingerFor(32));
        try t.expectEqual(Finger.right_thumb, p.fingerFor(33));
        try t.expectEqual(Finger.right_thumb, p.fingerFor(35));
        try t.expectEqual(@as(?usize, 13), p.homeAnchorFor(.left_index));
        try t.expectEqual(@as(?usize, 16), p.homeAnchorFor(.right_index));
    }

    // 4. Molekula (6 cols/hand on home row, 38 keys)
    {
        const geo = schematicMolekula();
        var keys: [38]TestKey = @splat(.{});
        keys[33] = .{ .text = " ", .hid_code = 44 };
        const ctx: TestLabelsCtx = .{ .keys = &keys };
        const p = try derive(&geo, ctx.labels(1), .{});
        // Outer two columns are both pinky; inner pinky (col 1) is the primary home anchor.
        try t.expectEqual(Finger.left_pinky, p.fingerFor(10));
        try t.expect(p.keys[10].outer_pinky);
        try t.expect(!p.keys[10].primary_home_anchor);
        try t.expectEqual(Finger.left_pinky, p.fingerFor(11));
        try t.expect(p.keys[11].primary_home_anchor);
        try t.expectEqual(Finger.left_ring, p.fingerFor(12));
        try t.expectEqual(Finger.left_middle, p.fingerFor(13));
        try t.expectEqual(Finger.left_index, p.fingerFor(14));
        try t.expectEqual(Finger.left_index, p.fingerFor(15));
        try t.expect(p.keys[15].inner_index);
        try t.expectEqual(Finger.right_index, p.fingerFor(16));
        try t.expect(p.keys[16].inner_index);
        try t.expectEqual(Finger.right_index, p.fingerFor(17));
        try t.expectEqual(Finger.right_middle, p.fingerFor(18));
        try t.expectEqual(Finger.right_ring, p.fingerFor(19));
        try t.expectEqual(Finger.right_pinky, p.fingerFor(20));
        try t.expect(p.keys[20].primary_home_anchor);
        try t.expectEqual(Finger.right_pinky, p.fingerFor(21));
        try t.expect(p.keys[21].outer_pinky);
        try t.expectEqual(@as(?usize, 11), p.homeAnchorFor(.left_pinky));
        try t.expectEqual(@as(?usize, 20), p.homeAnchorFor(.right_pinky));
    }

    // 5. Linear fallback board: preserves hand from firmware sides, never fabricates fingers.
    {
        var geo: [12]GeometryKey = undefined;
        var keys: [12]TestKey = @splat(.{});
        const letters = [_][]const u8{ "a", "e", "i", "o", "t", "n", "s", "r", "h", "d", "l", " " };
        for (0..12) |i| {
            geo[i] = .{
                .key_index = i,
                .x = @floatFromInt(i % 10),
                .y = @floatFromInt(i / 10),
                .hand = if (i < 6) .left else .right,
            };
            keys[i].text = letters[i];
        }
        const ctx: TestLabelsCtx = .{ .keys = &keys };
        const p = try derive(&geo, ctx.labels(1), .{ .fidelity = .linear });
        for (0..12) |i| {
            try t.expectEqual(Finger.unknown, p.fingerFor(i));
            try t.expectEqual(if (i < 6) Hand.left else Hand.right, p.handFor(i));
        }
        try t.expectEqual(@as(usize, 11), p.unlock_len);
        try t.expectEqual(@as(usize, 8), p.zone1_len);
    }
}

test "QWERTY vs Colemak-DH unlock zones, low-vowel detection, opposite-hand shift, layers and combos" {
    const t = std.testing;
    const geo = schematicKeycaprio34();

    // QWERTY
    const qwerty_keys = makeQwerty34();
    const qwerty_ctx: TestLabelsCtx = .{ .keys = &qwerty_keys };
    const combos = [_]ComboInput{
        .{ .layer = 0, .key_indices = .{ 12, 13 }, .output_cp = '_' },
        .{ .layer = 0, .key_indices = .{ 16, 17 }, .output_cp = '?', .unproven = true },
    };
    const qwerty = try derive(&geo, qwerty_ctx.labels(2), .{
        .host_layout = "en-US",
        .combos = &combos,
    });
    // Zone 1 on QWERTY has 7 letters (a s d f j k l) and only 1 vowel ('a').
    try t.expectEqual(@as(usize, 7), qwerty.zone1_len);
    try t.expectEqualStrings("asdfjkl", qwerty.zone1Letters());
    try t.expectEqual(@as(u8, 1), qwerty.zone1_vowel_count);
    try t.expect(qwerty.lowVowelHomeRow());
    try t.expectEqual(@as(?u8, 'e'), qwerty.priority_vowel);
    // First letter unlocked after Zone 1 must be 'e'.
    try t.expectEqual(@as(u8, 'e'), qwerty.unlock_order[qwerty.zone1_len]);
    try t.expectEqual(@as(usize, 26), qwerty.unlock_len);

    // Opposite-hand home-row Shift preference: typing left-hand 'a' (10) prefers right-hand Shift (16).
    try t.expect(qwerty.has_left_shift and qwerty.has_right_shift);
    try t.expectEqual(@as(usize, 16), qwerty.preferredShiftFor(10).?.key_index);
    try t.expectEqual(@as(usize, 13), qwerty.preferredShiftFor(18).?.key_index);

    // Layer symbols, digits, punctuation, and combos.
    try t.expectEqual(@as(usize, 10), qwerty.digits_len);
    try t.expect(qwerty.punctuation_len >= 5);
    try t.expect(qwerty.layer_symbols_len >= 10);
    try t.expectEqual(RouteKind.layer_tap, qwerty.routeFor('{').?.kind);
    try t.expectEqual(@as(?usize, 32), qwerty.routeFor('{').?.layer_activator);
    // Unproven combo ignored; valid combo discovered.
    try t.expectEqual(@as(usize, 1), qwerty.combo_len);
    try t.expectEqual(@as(u21, '_'), qwerty.combos[0].cp);
    try t.expectEqual(@as(?usize, 13), qwerty.combos[0].combo_key_index);

    // Colemak-DH
    const colemak_keys = makeColemakDh34();
    const colemak_ctx: TestLabelsCtx = .{ .keys = &colemak_keys };
    const colemak = try derive(&geo, colemak_ctx.labels(2), .{
        .host_layout = "en-US",
    });
    // Zone 1 on Colemak-DH has 8 letters (a r s t n e i o) and 4 vowels!
    try t.expectEqual(@as(usize, 8), colemak.zone1_len);
    try t.expectEqualStrings("arstneio", colemak.zone1Letters());
    try t.expectEqual(@as(u8, 4), colemak.zone1_vowel_count);
    try t.expect(!colemak.lowVowelHomeRow());
    try t.expectEqual(@as(?u8, null), colemak.priority_vowel);
    try t.expectEqual(@as(usize, 26), colemak.unlock_len);
    // Distinct profile hashes between QWERTY and Colemak-DH on the same board.
    try t.expect(!std.mem.eql(u8, &qwerty.profile_hash, &colemak.profile_hash));
    // Distinct profile hashes between host layouts.
    const colemak_de = try derive(&geo, colemak_ctx.labels(2), .{
        .host_layout = "de-DE",
    });
    try t.expect(!std.mem.eql(u8, &colemak.profile_hash, &colemak_de.profile_hash));
}

test "describeMove names combo, layer, shift and finger changes" {
    const t = std.testing;
    var buf: [max_move_reasons]MoveReason = undefined;
    const left_index_home: u16 = @backingInt(Finger.left_index) | (2 << 4);
    const right_index_home: u16 = @backingInt(Finger.right_index) | (2 << 4);
    const left_index_bottom: u16 = @backingInt(Finger.left_index) | (3 << 4);
    const key: KeyPosition = .{ .cp = 'z', .layer = 0, .slot = left_index_home, .shift = false };
    var combo = key;
    combo.combo_slot = left_index_bottom;
    try t.expectEqualSlices(MoveReason, &.{.key_to_combo}, describeMove(key, combo, &buf));
    try t.expectEqualSlices(MoveReason, &.{.combo_to_key}, describeMove(combo, key, &buf));
    var layered = key;
    layered.layer = 1;
    try t.expectEqualSlices(MoveReason, &.{.other_layer}, describeMove(key, layered, &buf));
    try t.expectEqualSlices(MoveReason, &.{.back_on_base_layer}, describeMove(layered, key, &buf));
    var shifted = key;
    shifted.shift = true;
    try t.expectEqualSlices(MoveReason, &.{.needs_shift}, describeMove(key, shifted, &buf));
    var lower = key;
    lower.slot = left_index_bottom;
    try t.expectEqualSlices(MoveReason, &.{.other_row}, describeMove(key, lower, &buf));
    var right = key;
    right.slot = right_index_home;
    try t.expectEqualSlices(MoveReason, &.{.other_hand}, describeMove(key, right, &buf));
    var inner = key;
    inner.slot = left_index_home | (1 << 6);
    try t.expectEqualSlices(MoveReason, &.{.other_column}, describeMove(key, inner, &buf));
}
