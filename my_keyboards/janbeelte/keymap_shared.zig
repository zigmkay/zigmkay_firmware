// Helpers shared by all janbeelte keymaps: layer indices, key definitions,
// combo options and custom functions. The layers and combos themselves live
// in each keymap.
const std = @import("std");

const zigmkay = @import("zigmkay");
pub const core = zigmkay.core;
const keycodes = @import("zkeycodes");
const kc = keycodes.layouts.keycodes.kcf;
const us = keycodes.layouts.us_international;
const macros = zigmkay.macros;
const kcm = keycodes.core;

pub const tapping_term: core.TimeSpan = .{ .ms = 200 };

pub const H_ = macros.OptionsHomeRowMods{ .tapping_term = tapping_term };
pub const B_ = macros.OptionsBasicKeydef{ .tapping_term = tapping_term };
/// Home-row mods sending the right-hand modifiers (for keys on the right half).
pub const HR_ = RightHomeRowMods{ .tapping_term = tapping_term };

pub const RightHomeRowMods = struct {
    tapping_term: core.TimeSpan,

    /// Tap sends `keycode_fire`; hold sends Right GUI.
    pub fn G(self: RightHomeRowMods, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return self.mod(.{ .right_gui = true }, keycode_fire);
    }

    /// Tap sends `keycode_fire`; hold sends Right Control.
    pub fn C(self: RightHomeRowMods, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return self.mod(.{ .right_ctrl = true }, keycode_fire);
    }

    /// Tap sends `keycode_fire`; hold sends Right Alt (AltGr on Windows/Linux international layouts).
    pub fn A(self: RightHomeRowMods, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return self.mod(.{ .right_alt = true }, keycode_fire);
    }

    /// Tap sends `keycode_fire`; hold sends Right Shift.
    pub fn S(self: RightHomeRowMods, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return self.mod(.{ .right_shift = true }, keycode_fire);
    }

    fn mod(self: RightHomeRowMods, modifiers: core.Modifiers, keycode_fire: core.KeyCodeFire) core.KeyDef {
        return core.KeyDef{
            .tap_hold = .{
                .tap = .{ .key_press = keycode_fire },
                .hold = core.HoldDef{ .hold_modifiers = modifiers },
                .tapping_term = self.tapping_term,
            },
        };
    }
};

pub const L_BASE: usize = 0;
pub const L_ARROWS: usize = 1;
pub const L_NUM: usize = 2;
pub const L_EMPTY: usize = 3;
pub const L_BOTH: usize = 4;
pub const L_WIN: usize = 5;
pub const L_LEFT = L_NUM;
pub const L_RIGHT = L_ARROWS;

pub const UNDO = kcm.L_GUI(us.Z);
pub const REDO: core.KeyCodeFire = .{ .tap_keycode = us.Z.tap_keycode, .tap_modifiers = .{ .left_shift = true, .left_gui = true } };
pub const SCRNSHT = _GCS(us.N4);

// Plain Shift+' instead of us.DIAE: the dead variant makes the firmware tap a
// space afterwards, which macOS layouts without a dead " print literally.
pub const DQUO = kcm.L_SFT(kc.QUOT);

// Plain Shift+` instead of us.DTIL, for the same trailing-space reason as DQUO.
pub const TILD = kcm.L_SFT(kc.GRV);

pub const combo = zigmkay.combo.Options{
    .combo_timeout = .{ .ms = 40 },
    .tapping_term = .{ .ms = 200 },
};

pub const CUSTOM_TAP_EQ_COL: u8 = 3;

fn on_event(event: core.ProcessorEvent, layers: *core.LayerActivations, output_queue: *core.OutputCommandQueue) void {
    switch (event) {
        .OnHoldEnterAfter => |data| {
            layers.set_layer_state(L_BOTH, layers.is_layer_active(L_LEFT) and layers.is_layer_active(L_RIGHT));
            if (data.hold.custom) |keycode| {
                output_queue.tap_key(.{
                    .tap_keycode = keycode,
                    .tap_modifiers = data.hold.hold_modifiers,
                }) catch {};
            }
        },
        .OnHoldExitAfter => {
            layers.set_layer_state(L_BOTH, layers.is_layer_active(L_LEFT) and layers.is_layer_active(L_RIGHT));
        },
        .OnTapEnterBefore => |data| {
            if (data.tap.custom == CUSTOM_TAP_EQ_COL) {
                output_queue.tap_key(kc.SPC) catch {};
                output_queue.tap_key(us.COLN) catch {};
                output_queue.tap_key(us.EQL) catch {};
                output_queue.tap_key(kc.SPC) catch {};
            }
        },
        else => {},
    }
}

pub const custom_functions: core.CustomFunctions = .{ .on_event = on_event };

fn _GCS(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.tap_modifiers.left_gui = true;
    copy.tap_modifiers.left_ctrl = true;
    copy.tap_modifiers.left_shift = true;
    return copy;
}

/// Tap sends `keycode_fire`; hold sends Gui+`keycode_hold` (macOS shortcuts).
pub fn GuiH(keycode_fire: core.KeyCodeFire, keycode_hold: core.KeyCodeFire) core.KeyDef {
    return ModH(.{ .left_gui = true }, keycode_fire, keycode_hold);
}

/// Tap sends `keycode_fire`; hold sends Ctrl+`keycode_hold` (Windows/Linux shortcuts).
pub fn CtlH(keycode_fire: core.KeyCodeFire, keycode_hold: core.KeyCodeFire) core.KeyDef {
    return ModH(.{ .left_ctrl = true }, keycode_fire, keycode_hold);
}

fn ModH(modifiers: core.Modifiers, keycode_fire: core.KeyCodeFire, keycode_hold: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_hold = .{
            .tap = .{ .key_press = keycode_fire },
            .hold = core.HoldDef{ .hold_modifiers = modifiers, .custom = keycode_hold.tap_keycode },
            .tapping_term = tapping_term,
        },
    };
}
