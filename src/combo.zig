const core = @import("core.zig");

/// Configuration for chord combos.
pub const Options = struct {
    combo_timeout: core.TimeSpan = .{ .ms = 40 },
    tapping_term: core.TimeSpan = .{ .ms = 200 },

    /// Defines a chord combo where pressing two keys simultaneously triggers a single key press.
    pub fn Combo_Tap(self: Options, key_indexes: [2]core.KeyIndex, layer: core.LayerIndex, keycode_fire: core.KeyCodeFire) core.Combo2Def {
        return core.Combo2Def{
            .key_indexes = key_indexes,
            .layer = layer,
            .timeout = self.combo_timeout,
            .key_def = core.KeyDef{ .tap_only = .{ .key_press = keycode_fire } },
        };
    }

    /// Defines a chord combo that triggers a custom ID in 'on_event' when pressed.
    pub fn Combo_Custom(self: Options, key_indexes: [2]core.KeyIndex, layer: core.LayerIndex, custom: u8) core.Combo2Def {
        return core.Combo2Def{
            .key_indexes = key_indexes,
            .layer = layer,
            .timeout = self.combo_timeout,
            .key_def = core.KeyDef{ .tap_only = .{ .custom = custom } },
        };
    }

    /// Defines a chord combo with Tap-Hold behavior: triggers a key on tap, or a modifier on hold.
    pub fn Combo_Tap_HoldMod(self: Options, key_indexes: [2]core.KeyIndex, layer: core.LayerIndex, keycode_fire: core.KeyCodeFire, mods: core.Modifiers) core.Combo2Def {
        return core.Combo2Def{
            .key_indexes = key_indexes,
            .layer = layer,
            .timeout = self.combo_timeout,
            .key_def = core.KeyDef{ .tap_hold = .{ .tap = .{ .key_press = keycode_fire }, .hold = .{ .hold_modifiers = mods }, .tapping_term = self.tapping_term } },
        };
    }
};
