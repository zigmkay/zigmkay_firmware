const std = @import("std");

const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const keycodes = @import("zkeycodes");
const dk = keycodes.layouts.danish;
const us = keycodes.layouts.keycodes.kcf;

// zig fmt: off
pub const key_count = 30;
pub const ________ = core.KeyDef.none;

pub const BASE_LAYER = 0;
pub const NUMBER_LAYER = 1;
pub const ARROW_KEYS_LAYER = 2;

pub const keymap = [_][key_count]?zigmkay.core.KeyDef{
    // BASE_LAYER: 0 
    .{
         T(dk.Q), T(dk.W), T(dk.E), T(dk.R),     T(dk.T),                  T(dk.Y), T(dk.U),      T(dk.I),    T(dk.O),   T(dk.P),
         T(dk.A), T(dk.S), T(dk.D), T(dk.F),     T(dk.G),                  T(dk.H), T(dk.J),      T(dk.K),    T(dk.L),   T(dk.SCLN),
                  T(dk.X), T(dk.C), T(dk.V),     T(dk.B),                  T(dk.N), T(dk.M),      T(dk.COMM), T(dk.DOT),
                                             Enter_Shift,                  Space_Arrows
    }, 
    // NUMBER_LAYER: 1
    .{
         ________, ________, ________, ________, ________,                  ________, T(dk.N7), T(dk.N8), T(dk.N9), ________,
         ________, ________, ________, ________, ________,                  ________, T(dk.N4), T(dk.N5), T(dk.N6), ________,
                   ________, ________, ________, ________,                  ________, T(dk.N1), T(dk.N2), T(dk.N3), 
                                                 ________,                  ________,
    },
    // ARROW_KEYS_LAYER: 2
    .{
         CloseWindow, ________, ________, ________, ________,                  ________, T(us.HOME), T(us.UP),   T(us.END),   ________,
         VolDown,     VolUp,    ________, ________, ________,                  ________, T(us.LEFT), T(us.DOWN), T(us.RIGHT), ________,
                      ________, ________, ________, ________,                  ________, ________,   ________,   ________,    
                                                    ________,                  ________,
    },
};

// zig fmt: on

pub const tapping_term = core.TimeSpan{ .ms = 250 };
pub const Enter_Shift = core.KeyDef{
    .tap_hold = .{
        .tap = .{ .key_press = us.ENTER },
        .hold = .{ .hold_modifiers = .{ .left_shift = true } },
        .tapping_term = tapping_term,
    },
};

pub const Space_Arrows = core.KeyDef{
    .tap_hold = .{
        .tap = .{ .key_press = dk.A },
        .hold = .{ .hold_layer = ARROW_KEYS_LAYER },
        .tapping_term = tapping_term,
    },
};

// fires alt+f4
const CloseWindow = core.KeyDef{
    .tap_only = .{
        .key_press = us.F4,
        //.hold_modifiers = .{ .left_alt = true },
    },
};

pub const VolUp = core.KeyDef{ .tap_only = .{ .media_key = .VolumeUp } };
pub const VolDown = core.KeyDef{ .tap_only = .{ .media_key = .VolumeDown } };

fn T(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .key_press = keycode_fire },
    };
}
