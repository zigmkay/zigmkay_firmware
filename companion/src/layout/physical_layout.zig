//! Physical identities and schematic geometry, independent of GPIO and processing side.
const std = @import("std");
const types = @import("zigmkay").core;

pub const KeyId = u16;
pub const Hand = enum { left, right, neutral };
pub const Group = enum { finger, thumb };

pub const Key = struct {
    id: KeyId,
    key_index: types.KeyIndex,
    x: f32,
    y: f32,
    width: f32 = 1,
    height: f32 = 1,
    rotation: f32 = 0,
    hand: Hand,
    group: Group = .finger,
    /// Explicit catalog metadata; never inferred from a letter or board size.
    home_row: bool = false,
};

pub const ValidationError = error{
    InvalidDimensions,
    WrongKeyCount,
    DuplicateId,
    DuplicateIndex,
    InvalidKeyIndex,
    InvalidGeometry,
    InvalidLayer,
    InvalidCombo,
};

pub fn validateKeys(keys: []const Key, dimensions: types.KeymapDimensions) ValidationError!void {
    if (dimensions.key_count == 0 or dimensions.layer_count == 0) return error.InvalidDimensions;
    if (keys.len != dimensions.key_count) return error.WrongKeyCount;
    var seen: [128]bool = @splat(false);
    for (keys, 0..) |key, i| {
        if (key.key_index >= dimensions.key_count) return error.InvalidKeyIndex;
        if (seen[key.key_index]) return error.DuplicateIndex;
        seen[key.key_index] = true;
        for (keys[0..i]) |earlier| {
            if (key.id == earlier.id) return error.DuplicateId;
        }
        if (!std.math.isFinite(key.x) or !std.math.isFinite(key.y) or
            !std.math.isFinite(key.rotation) or !std.math.isFinite(key.width) or
            !std.math.isFinite(key.height) or key.width <= 0 or key.height <= 0)
            return error.InvalidGeometry;
    }
}

pub fn validateAction(action: types.KeyDef, layer_count: types.LayerIndex) ValidationError!void {
    switch (action) {
        .none => {},
        .tap_only => |tap| try validateTap(tap, layer_count),
        .hold_only => |hold| try validateHold(hold, layer_count),
        .tap_hold => |both| {
            try validateTap(both.tap, layer_count);
            try validateHold(both.hold, layer_count);
        },
        .tap_with_autofire => |autofire| try validateTap(autofire.tap, layer_count),
    }
}

fn validateTap(tap: types.TapDef, layer_count: types.LayerIndex) ValidationError!void {
    if (tap.one_shot) |hold| try validateHold(hold, layer_count);
}

fn validateHold(hold: types.HoldDef, layer_count: types.LayerIndex) ValidationError!void {
    if (hold.hold_layer) |layer| {
        if (layer >= layer_count) return error.InvalidLayer;
    }
}

pub fn validateLogical(
    comptime dimensions: types.KeymapDimensions,
    keymap: *const [dimensions.layer_count][dimensions.key_count]?types.KeyDef,
    combos: []const types.Combo2Def,
) ValidationError!void {
    if (dimensions.key_count == 0 or dimensions.layer_count == 0) return error.InvalidDimensions;
    for (keymap) |layer| {
        for (layer) |entry| {
            if (entry) |action| try validateAction(action, dimensions.layer_count);
        }
    }
    for (combos) |combo| {
        if (combo.layer >= dimensions.layer_count) return error.InvalidLayer;
        if (combo.key_indexes[0] >= dimensions.key_count or combo.key_indexes[1] >= dimensions.key_count)
            return error.InvalidKeyIndex;
        if (combo.key_indexes[0] == combo.key_indexes[1]) return error.InvalidCombo;
        try validateAction(combo.key_def, dimensions.layer_count);
    }
}
