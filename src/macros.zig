const core = @import("core.zig");

// ---------------------------------------------------------------------
// KeyDef Macros
// ---------------------------------------------------------------------

/// Basic Tap key: Sends a single scancode on press.
pub fn T(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .key_press = keycode_fire },
    };
}

/// Media key: Sends a consumer page keycode.
pub fn MED(media_key: core.MediaCode) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .media_key = media_key },
    };
}

/// Mouse action: Sends a mouse button or wheel command.
pub fn MS(action: core.MouseAction) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .mouse_action = action },
    };
}

/// Helper to create a key that sends a custom signal to the companion app.
pub fn SIG(id: u8) core.KeyDef {
    return core.KeyDef{ .tap_only = .{ .custom = id } };
}

/// Creates a momentary layer-switch KeyDef. Activates 'layer_index' only while held.
pub fn MO(layer_index: core.LayerIndex) core.KeyDef {
    return core.KeyDef{
        .hold_only = .{ .hold_layer = layer_index },
    };
}

/// Creates a KeyDef that repeats the key press automatically while held.
pub fn AF(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_with_autofire = .{
            .tap = .{ .key_press = keycode_fire },
            .repeat_interval = .{ .ms = 50 },
            .initial_delay = .{ .ms = 150 },
        },
    };
}

/// Creates a tap-only KeyDef that includes the Left GUI (Windows) modifier. Use for OS shortcuts.
pub fn WinNav(keycode: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .key_press = .{ .tap_keycode = keycode.tap_keycode, .tap_modifiers = .{ .left_gui = true } } },
    };
}
/// Configuration for tap temrination time of basic.
pub const OptionsBasicKeydef = struct {
    tapping_term: core.TimeSpan = .{ .ms = 200 },

    /// Layer-Tap: Sends a key press on tap, activates 'layer_index' on hold.
    pub fn LT(self: OptionsBasicKeydef, layer_index: core.LayerIndex, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return core.KeyDef{
            .tap_hold = .{
                .tap = .{ .key_press = keycode_fire },
                .hold = .{ .hold_layer = layer_index },
                .tapping_term = self.tapping_term,
            },
        };
    }

    /// Specialized dual-role key: Sends 'keycode_fire' on tap, GUI + 'keycode_hold' on hold.
    pub fn GT(self: OptionsBasicKeydef, keycode_fire: core.KeyCodeFire, keycode_hold: core.KeyCodeFire) core.KeyDef {
        return core.KeyDef{
            .tap_hold = .{
                .tap = .{ .key_press = keycode_fire },
                .hold = core.HoldDef{ .hold_modifiers = .{ .left_gui = true }, .custom = keycode_hold.tap_keycode },
                .tapping_term = self.tapping_term,
            },
        };
    }
};

// ---------------------------------------------------------------------
// Home Row Mods
// ---------------------------------------------------------------------
/// Configuration for home row mods.
pub const OptionsHomeRowMods = struct {
    tapping_term: core.TimeSpan = .{ .ms = 200 },

    /// Dual-role key: Sends a key on tap, Left GUI on hold. (Home-row mod).
    pub fn G(self: OptionsHomeRowMods, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return core.KeyDef{
            .tap_hold = .{
                .tap = .{ .key_press = keycode_fire },
                .hold = core.HoldDef{ .hold_modifiers = .{ .left_gui = true } },
                .tapping_term = self.tapping_term,
            },
        };
    }

    /// Dual-role key: Sends a key on tap, Left Control on hold. (Home-row mod).
    pub fn C(self: OptionsHomeRowMods, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return core.KeyDef{
            .tap_hold = .{
                .tap = .{ .key_press = keycode_fire },
                .hold = core.HoldDef{ .hold_modifiers = .{ .left_ctrl = true } },
                .tapping_term = self.tapping_term,
            },
        };
    }

    /// Dual-role key: Sends a key on tap, Left Alt on hold. (Home-row mod).
    pub fn A(self: OptionsHomeRowMods, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return core.KeyDef{
            .tap_hold = .{
                .tap = .{ .key_press = keycode_fire },
                .hold = core.HoldDef{ .hold_modifiers = .{ .left_alt = true } },
                .tapping_term = self.tapping_term,
            },
        };
    }

    /// Dual-role key: Sends a key on tap, Left Shift on hold. (Home-row mod).
    pub fn S(self: OptionsHomeRowMods, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return core.KeyDef{
            .tap_hold = .{
                .tap = .{ .key_press = keycode_fire },
                .hold = core.HoldDef{ .hold_modifiers = .{ .left_shift = true } },
                .tapping_term = self.tapping_term,
            },
        };
    }

    /// Creates a TapHold definition where the hold action triggers a custom ID in 'on_event'.
    pub fn Cus(self: OptionsHomeRowMods, key_press: core.KeyCodeFire, custom_hold: u8) core.KeyDef {
        return core.KeyDef{
            .tap_hold = .{
                .tap = .{ .key_press = key_press },
                .hold = .{ .custom = custom_hold },
                .tapping_term = self.tapping_term,
            },
        };
    }
};
