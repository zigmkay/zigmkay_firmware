const std = @import("std");

const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const gpio = rp2xxx.gpio;
const rollercole_shared_keymap = @import("shared_keymap_28_1.zig");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const keycodes = @import("zkeycodes");
const dk = keycodes.layouts.danish;
const us = keycodes.layouts.keycodes.kcf;

// zig fmt: off
//
pub const key_count = 36;
pub const keymap = [_][key_count]?zigmkay.core.KeyDef{
    .{
         T(dk.Q), T(dk.W), T(dk.E), T(dk.R), T(dk.T),                  T(dk.Y), T(dk.U), T(dk.I),    T(dk.O),  T(dk.P),
         T(dk.A), T(dk.S), T(dk.D), T(dk.F), T(dk.G),                  T(dk.H), T(dk.J), T(dk.K),    T(dk.L),  T(dk.SCLN),
         T(dk.Z), T(dk.X), T(dk.C), T(dk.V), T(dk.B),                  T(dk.N), T(dk.M), T(dk.COMM), T(dk.DOT),T(dk.SLSH),
                           T(dk.A), T(us.ENTER), T(dk.B),           T(dk.T), T(us.SPACE), T(dk.C)
    }, 
};
// zig fmt: on

pub const dimensions = core.KeymapDimensions{
    .key_count = key_count,
    .layer_count = keymap.len,
};

fn T(keycode_fire: core.KeyCodeFire) core.KeyDef {
    return core.KeyDef{
        .tap_only = .{ .key_press = keycode_fire },
    };
}
