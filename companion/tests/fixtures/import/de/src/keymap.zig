// Keycaprio keymap with a German QWERTZ base layer for Windows/Linux.
// Home row index fingers hold Ctrl, shortcuts use Ctrl.
const zigmkay = @import("zigmkay");
pub const core = zigmkay.core;
const _______: ?core.KeyDef = null;
const keycodes = @import("zkeycodes");
const kc = keycodes.layouts.keycodes.kcf;
const de = keycodes.layouts.german;
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

const UNDO = kcm.L_CTL(de.Z);
const REDO = kcm.L_CTL(de.Y);
const SCRNSHT = kc.PSCR;
const DQUO = de.DQUO;

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
        T(de.Q),       T(de.W),            T(de.E),            H_.S(de.R),       T(de.T),                   T(de.Z),                T(de.U),        T(de.I),        T(de.O),              T(de.P),
        H_.S(de.A),    H_.G(de.S),         H_.A(de.D),         H_.C(de.F),       CtlH(de.G, de.G),          T(de.H),                HR_.C(de.J),    HR_.A(de.K),    HR_.G(de.L),          HR_.S(kc.BSPC),
        T(de.Y),       CtlH(de.X, de.X),   CtlH(de.C, de.C),   CtlH(de.V, de.V), T(de.B),                   T(de.N),                T(de.M),        T(de.COMM),     B_.LT(L_WIN, de.DOT), T(de.MINS),
                                                               T(kc.ENT),        B_.LT(L_LEFT, kc.SPC),     B_.LT(L_RIGHT, kc.SPC), T(kc.ENT),
    },
    // L_ARROWS - WIP (SEMICOLON & PLUS & TILDE up for debate)
    .{
        H_.C(de.LBRC), T(de.RBRC),         T(de.LCBR),         H_.S(de.RCBR),    T(de.HASH),                T(de.AT),               T(kc.HOME),     AF(kc.UP),      T(kc.END),            T(de.UDIA),
        H_.S(de.LABK), H_.G(de.RABK),      H_.A(de.LPRN),      H_.C(de.RPRN),    T(de.SLSH),                T(de.SS),             AF(kc.LEFT),    AF(kc.DOWN),    AF(kc.RIGHT),         HR_.S(de.ODIA),
        _______,       T(de.TILD),         T(de.AMPR),         T(de.ASTR),       T(de.BSLS),                T(de.EURO),              HR_.C(de.SCLN), HR_.A(de.ACUT), HR_.G(de.GRV),        T(de.ADIA),
                                                               T(kc.ENT),        B_.LT(L_LEFT, kc.ENT),     _______,                T(kc.ENT),
    },
    // L_NUM - WIP (ENT up for debate)
    .{
        H_.C(kc.ESC),  T(SCRNSHT),         T(de.PERC),         H_.S(de.CIRC),    T(de.GRV),                 T(de.UNDS),             T(de.N7),       T(de.N8),       T(de.N9),             T(de.EQL),
        AF(kc.BSPC),   H_.G(UNDO),         H_.A(REDO),         H_.C(kc.ENT),     T(kc.TAB),                 T(de.MINS),             HR_.C(de.N4),   HR_.A(de.N5),   HR_.G(de.N6),         HR_.S(de.PLUS),
        _______,       T(kcm.L_CTL(de.X)), T(kcm.L_CTL(de.C)), T(kc.DEL),        T(kcm.L_CTL(de.V)),        T(de.DLR),             T(de.N1),       T(de.N2),       T(de.N3),             _______,
                                                               T(kc.ENT),        _______,                   B_.LT(L_RIGHT, de.N0),  T(kc.ENT),
    },
    // L_EMPTY
    .{
        _______,       _______,            _______,            _______,          _______,                   _______,                _______,        _______,        _______,              _______,
        _______,       _______,            _______,            _______,          _______,                   _______,                _______,        _______,        _______,              _______,
        _______,       _______,            _______,            _______,          _______,                   _______,                _______,        _______,        _______,              _______,
                                                               T(kc.ENT),        B_.LT(L_LEFT, kc.SPC),     B_.LT(L_RIGHT, kc.SPC), T(kc.ENT),
    },
    // L_BOTH - WIP (SS & BACKSPC & ESC & TAB & GRAVE & CART up for debate, do we want SCRNSHT without shift?)
    .{
        H_.C(kc.ESC),  T(kc.F7),           T(kc.F8),           H_.S(kc.F9),      T(kc.F10),                 T(kcm.L_ALT(kc.TAB)),   HR_.S(kc.SPC),  T(kc.SPC),      T(kc.SPC),            T(kc.TAB),
        AF(kc.BSPC),   H_.G(kc.F4),        H_.A(kc.F5),        H_.C(kc.F6),      T(kc.F11),                 T(de.SS),               HR_.C(kc.BSPC), HR_.A(kc.BSPC), HR_.G(kc.BSPC),       HR_.S(kc.ESC),
        _______,       T(kc.F1),           T(kc.F2),           T(kc.F3),         T(kc.F12),                 T(de.CIRC),             T(kc.DEL),      T(kc.DEL),      T(kc.DEL),            _______,
                                                               T(kc.ENT),        _______,                   _______,                T(kc.ENT),
    },
    // L_WIN - window navigation shortcuts, activated by holding the base-layer dot key
    .{
        WinNav(de.N7), _______,            WinNav(de.N1),      WinNav(de.N6),    _______,                   _______,                _______,        _______,        _______,              _______,
        WinNav(de.N4), _______,            WinNav(de.N2),      WinNav(de.N5),    _______,                   _______,                _______,        _______,        _______,              _______,
        _______,       _______,            WinNav(de.N3),      WinNav(de.N8),    _______,                   _______,                _______,        _______,        _______,              _______,
                                                               T(kc.ENT),        _______,                   _______,                T(kc.ENT),
    },
};
// zig fmt: on

pub const dimensions = core.KeymapDimensions{
    .key_count = key_count,
    .layer_count = keymap.len,
};

pub const combos = [_]core.Combo2Def{
    combo.Combo_Tap(.{ 26, 27 }, L_BASE, de.COLN),
    combo.Combo_Tap(.{ 26, 27 }, L_ARROWS, de.COLN),
    combo.Combo_Tap(.{ 27, 28 }, L_BASE, DQUO),
    combo.Combo_Tap(.{ 27, 28 }, L_ARROWS, DQUO),
    combo.Combo_Tap_HoldMod(.{ 21, 22 }, L_BASE, de.Z, .{ .right_ctrl = true }),
    combo.Combo_Tap_HoldMod(.{ 1, 2 }, L_BASE, de.Z, .{ .right_ctrl = true }),

    // Dots for German umlauts:
    combo.Combo_Tap(.{ 23, 24 }, L_BASE, de.ADIA),
    combo.Combo_Tap(.{ 25, 26 }, L_BASE, de.ODIA),
    combo.Combo_Tap(.{ 7, 8 }, L_BASE, de.UDIA),

    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_BASE, de.V, .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_NUM, _Ctl(de.V), .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 11, 12 }, L_NUM, _Ctl(de.X), .{ .left_ctrl = true, .left_shift = true }),
    // combo.Combo_Tap_HoldMod(.{ 12, 13 }, L_ARROWS, de.AMPR, .{ .left_ctrl = true, .left_shift = true }),

    combo.Combo_Tap(.{ 13, 16 }, L_BOTH, kcm.L_ALT(kc.F4)),

    combo.Combo_Tap(.{ 24, 25 }, L_BASE, core.KC_BOOT),
    combo.Combo_Tap(.{ 0, 4 }, L_BASE, core.KC_BOOT),
    combo.Combo_Tap(.{ 5, 4 }, L_BASE, core.KC_BOOT),
    combo.Combo_Tap(.{ 7, 8 }, L_ARROWS, de.QUES),
    combo.Combo_Tap(.{ 7, 8 }, L_NUM, de.QUES),
    combo.Combo_Tap(.{ 7, 8 }, L_BOTH, de.QUES),

    combo.Combo_Tap(.{ 1, 2 }, L_ARROWS, de.EXLM),
    combo.Combo_Tap(.{ 1, 2 }, L_NUM, de.EXLM),
    combo.Combo_Tap(.{ 1, 2 }, L_BOTH, de.EXLM),

    // combo.Combo_Tap_HoldMod(.{ 17, 18 }, L_BASE, de.MINS, .{ .left_ctrl = true, .left_alt = true }),
    combo.Combo_Tap(.{ 17, 18 }, L_ARROWS, de.PLUS),
    combo.Combo_Tap(.{ 16, 17 }, L_ARROWS, de.PIPE),

    combo.Combo_Tap(.{ 21, 22 }, L_ARROWS, de.BSLS),

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
                output_queue.tap_key(de.COLN) catch {};
                output_queue.tap_key(de.EQL) catch {};
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
