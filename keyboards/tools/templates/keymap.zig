// =============================================================================
// template_board: default keymap
// =============================================================================
// Created by `mise run //keyboards:board:new template_board` from
// keyboards/tools/templates/keymap.zig. Key index n is the n-th entry of
// pin_mappings in main.zig. The keymap guide, docs/keymaps.md, covers every
// key type, combos, encoders and custom code.
// =============================================================================

const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const macros = zigmkay.macros;
const combo = zigmkay.combo.Options{};

const keycodes = @import("zkeycodes");
// HID keycodes as named on a US layout. For keys that must type the symbol
// printed on another host layout, use that locale instead, such as
// keycodes.layouts.danish or keycodes.layouts.german.
const us = keycodes.layouts.keycodes.kcf;

pub const key_count = 34;

const L_BASE = 0;
const L_NAV = 1;

const T = macros.T;
const ____ = core.KeyDef.none;
const tapping_term = core.TimeSpan{ .ms = 200 };

/// Taps `key`, holds Left Shift.
fn SFT(key: core.KeyCodeFire) core.KeyDef {
    return .{ .tap_hold = .{
        .tap = .{ .key_press = key },
        .hold = .{ .hold_modifiers = .{ .left_shift = true } },
        .tapping_term = tapping_term,
    } };
}

/// Taps `key`, switches to `layer` while held.
fn LT(layer: core.LayerIndex, key: core.KeyCodeFire) core.KeyDef {
    return .{ .tap_hold = .{
        .tap = .{ .key_press = key },
        .hold = .{ .hold_layer = layer },
        .tapping_term = tapping_term,
    } };
}

// zig fmt: off
pub const keymap = [_][key_count]?core.KeyDef{
    // L_BASE
    .{
        T(us.Q), T(us.W), T(us.E), T(us.R), T(us.T),          T(us.Y), T(us.U), T(us.I),    T(us.O),   T(us.P),
        T(us.A), T(us.S), T(us.D), T(us.F), T(us.G),          T(us.H), T(us.J), T(us.K),    T(us.L),   T(us.SCLN),
        T(us.Z), T(us.X), T(us.C), T(us.V), T(us.B),          T(us.N), T(us.M), T(us.COMM), T(us.DOT), T(us.SLSH),
                          SFT(us.ENTER), LT(L_NAV, us.TAB),   LT(L_NAV, us.SPACE), T(us.BSPC),
    },
    // L_NAV: digits on the left, arrows on the right. `null` is transparent:
    // the key of the layer below.
    .{
        T(us.N1), T(us.N2), T(us.N3), T(us.N4), T(us.N5),     T(us.N6),  T(us.N7),   T(us.N8),   T(us.N9),    T(us.N0),
        T(us.ESC), ____,    ____,     ____,     ____,         T(us.HOME), T(us.LEFT), T(us.DOWN), T(us.UP),    T(us.RIGHT),
        ____,     ____,     ____,     ____,     ____,         T(us.END), T(us.MINS), T(us.EQL),  T(us.QUOT),  ____,
                                      null,     null,         null,      null,
    },
};

/// Which hand each key belongs to: .L, .R, or .X for either.
pub const sides = [key_count]core.Side{
    .L, .L, .L, .L, .L,   .R, .R, .R, .R, .R,
    .L, .L, .L, .L, .L,   .R, .R, .R, .R, .R,
    .L, .L, .L, .L, .L,   .R, .R, .R, .R, .R,
                .X, .X,   .X, .X,
};
// zig fmt: on

pub const dimensions = core.KeymapDimensions{ .key_count = key_count, .layer_count = keymap.len };

/// Two-key combos. Keep a way into the bootloader: pressing the two outer top
/// keys of each hand (indexes 0 and 4, or 5 and 9) together reboots the board
/// for flashing, so you need not reach the BOOT button.
pub const combos = [_]core.Combo2Def{
    combo.Combo_Tap(.{ 0, 4 }, L_BASE, core.KC_BOOT),
    combo.Combo_Tap(.{ 5, 9 }, L_BASE, core.KC_BOOT),
};

/// Optional custom code, called on every processor event; see docs/keymaps.md.
pub const custom_functions = core.CustomFunctions{};
