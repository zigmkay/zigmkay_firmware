const std = @import("std");

const zigmkay = @import("zigmkay");
pub const core = zigmkay.core;
const _______: ?core.KeyDef = null;
const keycodes = @import("zkeycodes");
const kc = keycodes.layouts.keycodes.kcf;
const us = keycodes.layouts.us_international;
const kcm = keycodes.core;
const T = zigmkay.macros.T;
const AF = zigmkay.macros.AF;
const WinNav = zigmkay.macros.WinNav;

const shared = @import("keymap_shared.zig");
const H_ = shared.H_;
const HR_ = shared.HR_;
const B_ = shared.B_;
const GuiH = shared.GuiH;
const UNDO = shared.UNDO;
const REDO = shared.REDO;
const SCRNSHT = shared.SCRNSHT;
const DQUO = shared.DQUO;
const TILD = shared.TILD;
const combo = shared.combo;

const L_BASE = shared.L_BASE;
const L_ARROWS = shared.L_ARROWS;
const L_NUM = shared.L_NUM;
const L_BOTH = shared.L_BOTH;
const L_WIN = shared.L_WIN;
const L_LEFT = shared.L_LEFT;
const L_RIGHT = shared.L_RIGHT;

// zig fmt: off
pub const key_count = 30;
pub const sides = [key_count]core.Side{
  .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
  .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
     .L,.L,.L,.L,       .R,.R,.R,.R,
              .X,       .X
};

pub const keymap = [_][key_count]?core.KeyDef{
    // L_BASE
    .{
        T(us.Q),       T(us.W),            T(us.F),            H_.S(us.P),    T(us.B),                   T(us.J),                T(us.L),        T(us.U),        T(us.Y),              T(us.SCLN),
        H_.S(us.A),    H_.C(us.R),         H_.A(us.S),         H_.G(us.T),    GuiH(us.G, us.T),          T(us.M),                HR_.G(us.N),    HR_.A(us.E),    HR_.C(us.I),          HR_.S(us.O),
                       GuiH(us.X, us.X),   GuiH(us.C, us.C),   T(us.D),       GuiH(us.V, us.V),          T(us.K),                T(us.H),        T(us.COMM),     B_.LT(L_WIN, us.DOT),
                                                                              B_.LT(L_LEFT, kc.SPC),     B_.LT(L_RIGHT, kc.ENT),
    },
    // L_ARROWS - WIP (SEMICOLON & PLUS & TILD up for debate)
    .{
        H_.G(us.LBRC), T(us.RBRC),         T(us.LCBR),         H_.S(us.RCBR), T(us.HASH),                T(us.AT),               T(kc.HOME),     AF(kc.UP),      T(kc.END),            T(us.PLUS),
        H_.S(us.LABK), H_.C(us.RABK),      H_.A(us.LPRN),      H_.G(us.RPRN), T(us.SLSH),                T(kc.PGUP),             AF(kc.LEFT),    AF(kc.DOWN),    AF(kc.RIGHT),         HR_.S(kc.PGDN),
                       T(TILD),            T(us.AMPR),         T(us.ASTR),    T(kc.BSLS),                T(us.DLR),              HR_.G(us.SCLN), HR_.A(us.ACUT), HR_.C(kc.GRV),
                                                                              B_.LT(L_LEFT, kc.ENT),     _______,
    },
    // L_NUM
    .{
        H_.G(kc.ESC),  T(SCRNSHT),         T(us.PERC),         H_.S(us.DCIR), T(kc.GRV),                 T(us.UNDS),             T(us.N7),       T(us.N8),       T(us.N9),             T(us.EQL),
        AF(kc.BSPC),   H_.C(UNDO),         H_.A(REDO),         H_.G(kc.ENT),  T(kc.TAB),                 T(us.MINS),             HR_.G(us.N4),   HR_.A(us.N5),   HR_.C(us.N6),         HR_.S(us.PLUS),
                       T(kcm.L_GUI(us.X)), T(kcm.L_GUI(us.C)), T(kc.DEL),     T(kcm.L_GUI(us.V)),        T(us.EURO),             T(us.N1),       T(us.N2),       T(us.N3),
                                                                              _______,                   B_.LT(L_RIGHT, us.N0),
    },
    // L_EMPTY
    .{
        _______,       _______,            _______,            _______,       _______,                   _______,                _______,        _______,        _______,              _______,
        _______,       _______,            _______,            _______,       _______,                   _______,                _______,        _______,        _______,              _______,
                       _______,            _______,            _______,       _______,                   _______,                _______,        _______,        _______,
                                                                              B_.LT(L_LEFT, kc.SPC),     B_.LT(L_RIGHT, kc.ENT),
    },
    // L_BOTH - WIP (BACKSPC & ESC & TAB & GRAVE & CART up for debate, do we want SCRNSHT without shift?)
    .{
        H_.G(kc.ESC),  T(kc.F7),           T(kc.F8),           H_.S(kc.F9),   T(kc.F10),                 T(kcm.L_GUI(us.DGRV)),  HR_.S(kc.SPC),  T(kc.SPC),      T(kc.SPC),            T(kc.TAB),
        AF(kc.BSPC),   H_.C(kc.F4),        H_.A(kc.F5),        H_.G(kc.F6),   T(kc.F11),                 T(us.SS),               HR_.G(kc.BSPC), HR_.A(kc.BSPC), HR_.C(kc.BSPC),       HR_.S(kc.ESC),
                       T(kc.F1),           T(kc.F2),           T(kc.F3),      T(kc.F12),                 T(us.DCIR),             T(kc.DEL),      T(kc.DEL),      T(kc.DEL),
                                                                              _______,                   _______,
    },
    // L_WIN - window navigation shortcuts, activated by holding the base-layer dot key
    .{
        WinNav(us.N7), _______,            WinNav(us.N1),      WinNav(us.N6), _______,                   _______,                _______,        _______,        _______,              _______,
        WinNav(us.N4), _______,            WinNav(us.N2),      WinNav(us.N5), _______,                   _______,                _______,        _______,        _______,              _______,
                       _______,            WinNav(us.N3),      WinNav(us.N8), _______,                   _______,                _______,        _______,        _______,
                                                                              _______,                   _______,
    },
};
// zig fmt: on

pub const dimensions = core.KeymapDimensions{
    .key_count = key_count,
    .layer_count = keymap.len,
};

pub const combos = [_]core.Combo2Def{
    combo.Combo_Tap(.{ 25, 26 }, L_BASE, us.COLN),
    combo.Combo_Tap(.{ 25, 26 }, L_ARROWS, us.COLN),
    combo.Combo_Tap(.{ 26, 27 }, L_BASE, DQUO),
    combo.Combo_Tap(.{ 26, 27 }, L_ARROWS, DQUO),
    combo.Combo_Tap_HoldMod(.{ 20, 21 }, L_BASE, us.Z, .{ .right_ctrl = true }),
    combo.Combo_Tap_HoldMod(.{ 1, 2 }, L_BASE, us.Z, .{ .right_ctrl = true }),

    // Dots for DE Umlaute:
    combo.Combo_Tap(.{ 22, 23 }, L_BASE, kcm.L_ALT(us.U)),
    combo.Combo_Tap(.{ 24, 25 }, L_BASE, kcm.L_ALT(us.U)),

    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_BASE, us.V, .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_NUM, _Ctl(us.V), .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 11, 12 }, L_NUM, _Ctl(us.X), .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_ARROWS, us.AMPR, .{ .left_ctrl = true, .left_shift = true }),

    combo.Combo_Tap(.{ 13, 16 }, L_BOTH, kcm.L_ALT(kc.F4)),

    combo.Combo_Tap(.{ 23, 24 }, L_BASE, core.KC_BOOT),
    combo.Combo_Tap(.{ 0, 4 }, L_BASE, core.KC_BOOT),
    combo.Combo_Tap(.{ 5, 4 }, L_BASE, core.KC_BOOT),
    // combo.Combo_Tap(.{ 6, 7 }, L_BASE, de.AE),
    // combo.Combo_Tap(.{ 6, 8 }, L_BASE, de.OE),
    // combo.Combo_Tap(.{ 7, 8 }, L_BASE, de.UE),

    combo.Combo_Tap(.{ 7, 8 }, L_ARROWS, us.QUES),
    combo.Combo_Tap(.{ 7, 8 }, L_NUM, us.QUES),
    combo.Combo_Tap(.{ 7, 8 }, L_BOTH, us.QUES),

    combo.Combo_Tap(.{ 1, 2 }, L_ARROWS, us.EXLM),
    combo.Combo_Tap(.{ 1, 2 }, L_NUM, us.EXLM),
    combo.Combo_Tap(.{ 1, 2 }, L_BOTH, us.EXLM),

    // combo.Combo_Tap_HoldMod(.{ 17, 18 }, L_BASE, us.MINS, .{ .left_ctrl = true, .left_alt = true }),
    combo.Combo_Tap(.{ 17, 18 }, L_ARROWS, us.PLUS),
    combo.Combo_Tap(.{ 16, 17 }, L_ARROWS, us.PIPE),

    combo.Combo_Tap(.{ 20, 21 }, L_ARROWS, us.BSLS),

    combo.Combo_Custom(.{ 1, 3 }, L_ARROWS, shared.CUSTOM_TAP_EQ_COL),
};

pub const custom_functions = shared.custom_functions;
