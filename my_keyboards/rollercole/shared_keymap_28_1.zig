const std = @import("std");

const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const _______ = core.KeyDef.none;
const keycodes = @import("zkeycodes");
const dk = keycodes.layouts.danish;
const us = keycodes.layouts.keycodes.kcf;

pub const key_count = 30;

// zig fmt: off
//core.KeyDef.transparent;
const L_BASE:usize = 0;
const L_ARROWS:usize = 1;
const L_NUM:usize = 2;
const L_BOTH:usize = 3;
const L_GAMING:usize = 4;

pub const sides = [key_count]core.Side{
  .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
  .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
     .L,.L,.L,.L,       .R,.R,.R,.R,
             .X,       .X
};

pub const keymap = [_][key_count]?core.KeyDef{
    .{
         T(dk.Q), AF_slow(dk.W), GUI(dk.R),   T(dk.P), AF_slow(dk.B),                  T(dk.K),   T(dk.L),   GUI(dk.O),   T(dk.U), T(dk.QUOT),
         T(dk.F),     ALT(dk.A), CTL(dk.S), SFT(dk.T),       T(dk.G),                  T(dk.M), SFT(dk.N),   CTL(dk.E), ALT(dk.I),    T(dk.Y),
                        T(dk.X),   T(dk.C),   T(dk.D),       T(dk.V),                  T(dk.J),   T(dk.H), T(dk.COMM), T(dk.DOT),
                                            C(us.ENTER, CUSTOM_HOLD_LEFT),                  C( us.SPACE, CUSTOM_HOLD_RIGHT)
    },
    // L_ARROWS
    .{
    T(dk.EXLM),   T(dk.LABK),  GUI(dk.EQL),   T(dk.RABK), T(dk.PERC),             T(dk.SLSH),       T(us.HOME),   AF_fast(us.UP),         T(us.END),  T(us.APP),
AF_slow(dk.AT),   ALT(dk.LCBR), CTL(dk.LPRN), SFT(dk.RPRN), T(dk.RCBR),             T(us.PGUP), AF_fast(us.LEFT), AF_fast(us.DOWN), AF_fast(us.RIGHT), T(us.PGDN),
                  T(dk.HASH),   T(dk.LBRC),   T(dk.RBRC),    _______,                _______,        T(us.TAB),     CTL(dk.DQUO),         T(us.ESC),
                                                        C(us.SPACE, CUSTOM_HOLD_LEFT),                _______
    },
    // L_NUM
    .{
              _______, TC(CUSTOM_TAP_ALT_TAB),       T(dk.R),   _______,           _______,            _______,   T(dk.N7),   T(dk.N8),   T(dk.N9),    _______,
     T(_Gui(us.LEFT)),                   UNDO,       _______,      REDO, T(_Gui(us.RIGHT)),            _______, SFT(dk.N4), CTL(dk.N5), ALT(dk.N6), T(dk.PLUS),
                                    T(us.ESC), T(_Ctl(dk.C)), T(us.DEL),           _______,         PrintStats,   T(dk.N1),   T(dk.N2),   T(dk.N3),
                                                                                   _______,  C( us.N0, CUSTOM_HOLD_RIGHT)
    },
        // BOTH
    .{
    MEDIA(.VolumeUp), T(us.F7),   T(us.F8),   T(us.F9), T(us.F10),            T(dk.TILD),  T(us.SPACE),  T(us.SPACE),  T(us.SPACE), T(dk.GRV),
    MEDIA(.VolumeDown), T(us.F4), CTL(us.F5), SFT(us.F6), T(us.F11),             T(dk.DLR), SFT(us.BSPC), CTL(us.BSPC), ALT(us.BSPC),   _______,
                        T(us.F1),   T(us.F2),   T(us.F3), T(us.F12),            T(dk.CIRC),    T(us.DEL),    T(us.DEL),    T(us.DEL),
                                                                    _______,              T(dk.N0)
    },
    // GAMING
    .{
      T(us.ESCAPE), T(dk.Q), T(dk.W), T(dk.E),    _______,                   _______,    _______,   T(us.UP),     _______, custom_key(CUSTOM_TAP_DISABLE_GAMING),
           T(dk.F), T(dk.A), T(dk.S), T(dk.D),    _______,                   _______, T(us.LEFT), T(us.DOWN), T(us.RIGHT),                              _______,
           T(dk.G), T(dk.G),    _______,    _______,                         _______,    _______,    _______,     _______,
                                        T(us.SPACE),                  _______
    },
};
// zig fmt: on

fn MEDIA(key: core.MediaCode) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .media_key = key },
    };
}

const volume_test = core.KeyDef{
    .tap_only = .{ .media_key = 0x00E9 },
};
const mouse_test = core.KeyDef{
    .tap_only = core.TapDef{
        .mouse_action = .WheelUp,
    },
};

//
const LEFT_THUMB = 1;
const RIGHT_THUMB = 2;

const UNDO = T(_Ctl(dk.Z));
const REDO = T(_Ctl(dk.Y));

fn _Ctl(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .left_ctrl = true });
    return copy;
}

fn _Sft(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .left_shift = true });
    return copy;
}

fn _Gui(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .left_gui = true });
    return copy;
}

fn C(key_press: core.KeyCodeFire, custom_hold: u8) core.KeyDef {
    return core.KeyDef{
        .tap_hold = .{
            .tap = .{ .key_press = key_press },
            .hold = .{ .custom = custom_hold },
            .tapping_term = tapping_term,
        },
    };
}

pub const dimensions = core.KeymapDimensions{ .key_count = key_count, .layer_count = keymap.len };
const PrintStats = core.KeyDef{ .tap_only = .{ .key_press = core.KC_PRINT_STATS } };
const tapping_term = core.TimeSpan{ .ms = 250 };
const combo_timeout = core.TimeSpan{ .ms = 40 };

const BOOT = core.KC_BOOT;

pub const combos = [_]core.Combo2Def{
    Combo_Tap(.{ 1, 2 }, L_BASE, dk.J),

    Combo_Tap_HoldMod(.{ 11, 12 }, L_BASE, dk.Z, .{ .right_ctrl = true, .right_alt = true }),
    Combo_Tap_HoldMod(.{ 12, 13 }, L_BASE, dk.V, .{ .left_ctrl = true, .left_shift = true }),

    Combo_Tap_HoldMod(.{ 12, 13 }, L_NUM, _Ctl(dk.V), .{ .left_ctrl = true, .left_shift = true }),
    Combo_Tap_HoldMod(.{ 11, 12 }, L_NUM, _Ctl(dk.X), .{ .left_ctrl = true, .left_shift = true }),
    Combo_Tap_HoldMod(.{ 12, 13 }, L_ARROWS, dk.AMPR, .{ .left_ctrl = true, .left_shift = true }),

    Combo_Tap(.{ 13, 16 }, L_BOTH, core.KeyCodeFire{ .tap_keycode = us.F4.tap_keycode, .tap_modifiers = .{ .left_alt = true } }),

    Combo_Tap(.{ 23, 24 }, L_BASE, BOOT),
    Combo_Tap(.{ 0, 4 }, L_BASE, BOOT),
    Combo_Tap(.{ 5, 9 }, L_BASE, BOOT),
    Combo_Tap(.{ 6, 7 }, L_BASE, dk.AE), //æ
    Combo_Tap(.{ 6, 8 }, L_BASE, dk.OSTR), //ø
    Combo_Tap(.{ 7, 8 }, L_BASE, dk.ARNG), //å

    Combo_Tap(.{ 7, 8 }, L_ARROWS, dk.QUES),
    Combo_Tap(.{ 7, 8 }, L_BOTH, dk.QUES),

    Combo_Tap(.{ 1, 2 }, L_ARROWS, dk.EXLM),
    Combo_Tap(.{ 1, 2 }, L_BOTH, dk.EXLM),

    Combo_Tap_HoldMod(.{ 17, 18 }, L_BASE, dk.MINS, .{ .left_ctrl = true, .left_alt = true }),
    Combo_Tap(.{ 17, 18 }, L_ARROWS, dk.PLUS),
    Combo_Tap(.{ 17, 18 }, L_NUM, dk.MINS),
    Combo_Tap(.{ 16, 17 }, L_ARROWS, dk.PIPE),

    Combo_Tap(.{ 20, 21 }, L_ARROWS, dk.BSLS),

    Combo_Custom(.{ 0, 9 }, L_BASE, CUSTOM_TAP_ENABLE_GAMING),
    Combo_Custom(.{ 1, 3 }, L_ARROWS, CUSTOM_TAP_EQ_COL),

    Combo_Media_Tap(.{ 12, 13 }, L_BOTH, .NextTrack),
    Combo_Media_Tap(.{ 11, 12 }, L_BOTH, .PreviousTrack),
};

// For now, all these shortcuts are placed in the custom keymap to let the user know how they are defined
// but maybe there should be some sort of helper module containing all of these
fn Combo_Tap(key_indexes: [2]core.KeyIndex, layer: core.LayerIndex, keycode_fire: core.KeyCodeFire) core.Combo2Def {
    return core.Combo2Def{
        .key_indexes = key_indexes,
        .layer = layer,
        .timeout = combo_timeout,
        .key_def = core.KeyDef{ .tap_only = .{ .key_press = keycode_fire } },
    };
}

fn Combo_Media_Tap(key_indexes: [2]core.KeyIndex, layer: core.LayerIndex, key: core.MediaCode) core.Combo2Def {
    return core.Combo2Def{
        .key_indexes = key_indexes,
        .layer = layer,
        .timeout = combo_timeout,
        .key_def = core.KeyDef{
            .tap_only = .{ .media_key = key },
        },
    };
}

fn Combo_Custom(key_indexes: [2]core.KeyIndex, layer: core.LayerIndex, custom: u8) core.Combo2Def {
    return core.Combo2Def{
        .key_indexes = key_indexes,
        .layer = layer,
        .timeout = combo_timeout,
        .key_def = core.KeyDef{ .tap_only = .{ .custom = custom } },
    };
}

fn Combo_Tap_HoldMod(key_indexes: [2]core.KeyIndex, layer: core.LayerIndex, keycode_fire: core.KeyCodeFire, mods: core.Modifiers) core.Combo2Def {
    return core.Combo2Def{
        .key_indexes = key_indexes,
        .layer = layer,
        .timeout = combo_timeout,
        .key_def = core.KeyDef{ .tap_hold = .{ .tap = .{ .key_press = keycode_fire }, .hold = .{ .hold_modifiers = mods }, .tapping_term = tapping_term } },
    };
}
// autofire
const one_shot_shift = core.KeyDef{ .tap_only = .{ .one_shot = .{ .hold_modifiers = .{ .left_shift = true } } } };
fn AF_fast(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return AF_internal(keycode_fire, 100);
}
fn AF_slow(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return AF_internal(keycode_fire, 200);
}
fn AF_internal(keycode_fire: core.KeyCodeFire, initial_delay: u16) core.KeyDef {
    return core.KeyDef{
        .tap_with_autofire = .{
            .tap = .{ .key_press = keycode_fire },
            .repeat_interval = .{ .ms = 50 },
            .initial_delay = .{ .ms = initial_delay },
        },
    };
}
fn MO(layer_index: core.LayerIndex) core.KeyDef {
    return core.KeyDef{
        .hold = .{ .hold_layer = layer_index },
    };
}

fn LT(layer_index: core.LayerIndex, keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_hold = .{
            .tap = .{ .key_press = keycode_fire },
            .hold = .{ .hold_layer = layer_index },
            .tapping_term = tapping_term,
        },
    };
}
// T for 'Tap-only'
fn WinNav(keycode: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .key_press = .{ .tap_keycode = keycode.tap_keycode, .tap_modifiers = .{ .left_gui = true } } },
    };
}
fn TC(custom_key_code: u8) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .custom = custom_key_code },
    };
}
fn T(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .key_press = keycode_fire },
    };
}
fn GUI(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_hold = .{
            .tap = .{ .key_press = keycode_fire },
            .hold = core.HoldDef{ .hold_modifiers = .{ .left_gui = true } },
            .tapping_term = .{ .ms = 750 },
        },
    };
}
fn CTL(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_hold = .{
            .tap = .{ .key_press = keycode_fire },
            .hold = core.HoldDef{ .hold_modifiers = .{ .left_ctrl = true } },
            .tapping_term = tapping_term,
        },
    };
}
fn ALT(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_hold = .{
            .tap = .{ .key_press = keycode_fire },
            .hold = core.HoldDef{ .hold_modifiers = .{ .left_alt = true } },
            .tapping_term = tapping_term,
        },
    };
}
fn SFT(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_hold = .{
            .tap = .{ .key_press = keycode_fire },
            .hold = core.HoldDef{ .hold_modifiers = .{ .left_shift = true } },
            .tapping_term = tapping_term,
        },
    };
}

const CUSTOM_TAP_ENABLE_GAMING = 1;
const CUSTOM_TAP_DISABLE_GAMING = 2;
const CUSTOM_TAP_EQ_COL = 3;
const CUSTOM_TAP_ALT_TAB: u8 = 4;

const CUSTOM_HOLD_LEFT: u8 = 1;
const CUSTOM_HOLD_RIGHT: u8 = 2;

fn custom_key(custom_key_val: u8) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .custom = custom_key_val },
    };
}

var left_held = false;
var right_held = false;

fn on_event(event: core.ProcessorEvent, layers: *core.LayerActivations, output_queue: *core.OutputCommandQueue) void {
    switch (event) {
        .OnHoldEnterAfter => |e| {
            if (e.hold.custom == CUSTOM_HOLD_LEFT) {
                left_held = true;
            }
            if (e.hold.custom == CUSTOM_HOLD_RIGHT) {
                right_held = true;
            }
            layers.set_layer_state(L_BOTH, left_held and right_held);
            layers.set_layer_state(L_NUM, left_held and !right_held);
            layers.set_layer_state(L_ARROWS, right_held and !left_held);
        },
        .OnHoldExitAfter => |e| {
            if (e.hold.custom == CUSTOM_HOLD_LEFT) {
                left_held = false;
                // if releasing left key, also ensure alt (as part of alt tab) is no longer held
                if (output_queue.current_mods.left_alt) {
                    var mods = output_queue.current_mods;
                    mods.left_alt = false;
                    output_queue.set_mods(mods) catch {};
                }
            }
            if (e.hold.custom == CUSTOM_HOLD_RIGHT) {
                right_held = false;
            }
            layers.set_layer_state(L_BOTH, left_held and right_held);
            layers.set_layer_state(L_NUM, left_held and !right_held);
            layers.set_layer_state(L_ARROWS, right_held and !left_held);
        },
        .OnTapEnterAfter => |data| {
            if (data.tap.custom == CUSTOM_TAP_ALT_TAB) {
                if (!output_queue.current_mods.left_alt) {
                    var mods = output_queue.current_mods;
                    mods.left_alt = true;
                    output_queue.set_mods(mods) catch {};
                }
                output_queue.tap_key(us.TAB) catch {};
            }
        },
        .OnTapEnterBefore => |data| {
            if (data.tap.custom == CUSTOM_TAP_ENABLE_GAMING) {
                layers.set_layer_state(L_GAMING, true);
            }
            if (data.tap.custom == CUSTOM_TAP_DISABLE_GAMING) {
                output_queue.tap_key(us.ESCAPE) catch {};
                layers.set_layer_state(L_GAMING, false);
            }
            if (data.tap.custom == CUSTOM_TAP_EQ_COL) {
                output_queue.tap_key(us.SPACE) catch {};
                output_queue.tap_key(dk.COLN) catch {};
                output_queue.tap_key(dk.EQL) catch {};
                output_queue.tap_key(us.SPACE) catch {};
            }
        },
        .OnTapExitAfter => {},
        else => {},
    }
}
pub const custom_functions = core.CustomFunctions{
    .on_event = on_event,
};
