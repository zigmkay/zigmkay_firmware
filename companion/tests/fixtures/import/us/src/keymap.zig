// Keycaprio keymap with a US QWERTY base layer for Windows/Linux with the
// US-International OS layout. Home row index fingers hold Ctrl, shortcuts use Ctrl.
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

const tapping_term: core.TimeSpan = .{ .ms = 200 };
const H_ = zigmkay.macros.OptionsHomeRowMods{ .tapping_term = tapping_term };
const B_ = zigmkay.macros.OptionsBasicKeydef{ .tapping_term = tapping_term };
/// Home-row mods sending the right-hand modifiers (for keys on the right half).
const HR_ = RightHomeRowMods{ .tapping_term = tapping_term };
const combo = zigmkay.combo.Options{
    .combo_timeout = .{ .ms = 40 },
    .tapping_term = tapping_term,
};

const UNDO = kcm.L_CTL(us.Z);
const REDO = kcm.L_CTL(us.Y);
const SCRNSHT = kc.PSCR;
// US-International: " is a dead key, us.DIAE taps a space after it to print ".
const DQUO = us.DIAE;
// Raw dead diaeresis: the next vowel becomes an umlaut (" + a = ä).
const DEAD_DIAE = kcm.L_SFT(kc.QUOT);

const L_BASE: usize = 0;
const L_ARROWS: usize = 1;
const L_NUM: usize = 2;
const L_EMPTY: usize = 3;
const L_BOTH: usize = 4;
const L_WIN: usize = 5;
const L_LEFT = L_NUM;
const L_RIGHT = L_ARROWS;

const CUSTOM_TAP_EQ_COL: u8 = 3;

// zig fmt: off
pub const key_count = 34;
pub const sides = [key_count]core.Side{
  .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
  .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
  .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
           .X,.X,       .X,.X
};

pub const keymap = [_][key_count]?core.KeyDef{
    // L_BASE
    .{
        T(us.Q),       T(us.W),            T(us.E),            H_.S(us.R),       T(us.T),                   T(us.Y),                T(us.U),        T(us.I),        T(us.O),              T(us.P),
        H_.S(us.A),    H_.G(us.S),         H_.A(us.D),         H_.C(us.F),       CtlH(us.G, us.G),          T(us.H),                HR_.C(us.J),    HR_.A(us.K),    HR_.G(us.L),          HR_.S(us.SCLN),
        T(us.Z),       CtlH(us.X, us.X),   CtlH(us.C, us.C),   CtlH(us.V, us.V), T(us.B),                   T(us.N),                T(us.M),        T(us.COMM),     B_.LT(L_WIN, us.DOT), T(us.SLSH),
                                                               T(kc.ENT),        B_.LT(L_LEFT, kc.SPC),     B_.LT(L_RIGHT, kc.SPC), T(kc.ENT),
    },
    // L_ARROWS - WIP (SEMICOLON & PLUS & TILD up for debate)
    .{
        H_.C(us.LBRC), T(us.RBRC),         T(us.LCBR),         H_.S(us.RCBR),    T(us.HASH),                T(us.AT),               T(kc.HOME),     AF(kc.UP),      T(kc.END),            T(us.PLUS),
        H_.S(us.LABK), H_.G(us.RABK),      H_.A(us.LPRN),      H_.C(us.RPRN),    T(us.SLSH),                T(kc.PGUP),             AF(kc.LEFT),    AF(kc.DOWN),    AF(kc.RIGHT),         HR_.S(kc.PGDN),
        _______,       T(us.DTIL),         T(us.AMPR),         T(us.ASTR),       T(kc.BSLS),                T(us.DLR),              HR_.C(us.SCLN), HR_.A(us.ACUT), HR_.G(us.DGRV),       _______,
                                                               T(kc.ENT),        B_.LT(L_LEFT, kc.ENT),     _______,                T(kc.ENT),
    },
    // L_NUM
    .{
        H_.C(kc.ESC),  T(SCRNSHT),         T(us.PERC),         H_.S(us.DCIR),    T(us.DGRV),                T(us.UNDS),             T(us.N7),       T(us.N8),       T(us.N9),             T(us.EQL),
        AF(kc.BSPC),   H_.G(UNDO),         H_.A(REDO),         H_.C(kc.ENT),     T(kc.TAB),                 T(us.MINS),             HR_.C(us.N4),   HR_.A(us.N5),   HR_.G(us.N6),         HR_.S(us.PLUS),
        _______,       T(kcm.L_CTL(us.X)), T(kcm.L_CTL(us.C)), T(kc.DEL),        T(kcm.L_CTL(us.V)),        T(us.EURO),             T(us.N1),       T(us.N2),       T(us.N3),             _______,
                                                               T(kc.ENT),        _______,                   B_.LT(L_RIGHT, us.N0),  T(kc.ENT),
    },
    // L_EMPTY
    .{
        _______,       _______,            _______,            _______,          _______,                   _______,                _______,        _______,        _______,              _______,
        _______,       _______,            _______,            _______,          _______,                   _______,                _______,        _______,        _______,              _______,
        _______,       _______,            _______,            _______,          _______,                   _______,                _______,        _______,        _______,              _______,
                                                               T(kc.ENT),        B_.LT(L_LEFT, kc.SPC),     B_.LT(L_RIGHT, kc.SPC), T(kc.ENT),
    },
    // L_BOTH - WIP (BACKSPC & ESC & TAB & GRAVE & CART up for debate, do we want SCRNSHT without shift?)
    .{
        H_.C(kc.ESC),  T(kc.F7),           T(kc.F8),           H_.S(kc.F9),      T(kc.F10),                 T(kcm.L_ALT(kc.TAB)),   HR_.S(kc.SPC),  T(kc.SPC),      T(kc.SPC),            T(kc.TAB),
        AF(kc.BSPC),   H_.G(kc.F4),        H_.A(kc.F5),        H_.C(kc.F6),      T(kc.F11),                 T(us.SS),               HR_.C(kc.BSPC), HR_.A(kc.BSPC), HR_.G(kc.BSPC),       HR_.S(kc.ESC),
        _______,       T(kc.F1),           T(kc.F2),           T(kc.F3),         T(kc.F12),                 T(us.DCIR),             T(kc.DEL),      T(kc.DEL),      T(kc.DEL),            _______,
                                                               T(kc.ENT),        _______,                   _______,                T(kc.ENT),
    },
    // L_WIN - window navigation shortcuts, activated by holding the base-layer dot key
    .{
        WinNav(us.N7), _______,            WinNav(us.N1),      WinNav(us.N6),    _______,                   _______,                _______,        _______,        _______,              _______,
        WinNav(us.N4), _______,            WinNav(us.N2),      WinNav(us.N5),    _______,                   _______,                _______,        _______,        _______,              _______,
        _______,       _______,            WinNav(us.N3),      WinNav(us.N8),    _______,                   _______,                _______,        _______,        _______,              _______,
                                                               T(kc.ENT),        _______,                   _______,                T(kc.ENT),
    },
};
// zig fmt: on

pub const dimensions = core.KeymapDimensions{
    .key_count = key_count,
    .layer_count = keymap.len,
};

pub const combos = [_]core.Combo2Def{
    combo.Combo_Tap(.{ 26, 27 }, L_BASE, us.COLN),
    combo.Combo_Tap(.{ 26, 27 }, L_ARROWS, us.COLN),
    combo.Combo_Tap(.{ 27, 28 }, L_BASE, DQUO),
    combo.Combo_Tap(.{ 27, 28 }, L_ARROWS, DQUO),
    combo.Combo_Tap_HoldMod(.{ 21, 22 }, L_BASE, us.Z, .{ .right_ctrl = true }),
    combo.Combo_Tap_HoldMod(.{ 1, 2 }, L_BASE, us.Z, .{ .right_ctrl = true }),

    // Dots for DE Umlaute:
    combo.Combo_Tap(.{ 23, 24 }, L_BASE, DEAD_DIAE),
    combo.Combo_Tap(.{ 25, 26 }, L_BASE, DEAD_DIAE),

    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_BASE, us.V, .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_NUM, _Ctl(us.V), .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 11, 12 }, L_NUM, _Ctl(us.X), .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_ARROWS, us.AMPR, .{ .left_ctrl = true, .left_shift = true }),

    combo.Combo_Tap(.{ 13, 16 }, L_BOTH, kcm.L_ALT(kc.F4)),

    combo.Combo_Tap(.{ 24, 25 }, L_BASE, core.KC_BOOT),
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

    combo.Combo_Tap(.{ 21, 22 }, L_ARROWS, us.BSLS),

    combo.Combo_Custom(.{ 1, 3 }, L_ARROWS, CUSTOM_TAP_EQ_COL),
};

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

const RightHomeRowMods = struct {
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

/// Tap sends `keycode_fire`; hold sends Ctrl+`keycode_hold` (Windows/Linux shortcuts).
fn CtlH(keycode_fire: core.KeyCodeFire, keycode_hold: core.KeyCodeFire) core.KeyDef {
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
