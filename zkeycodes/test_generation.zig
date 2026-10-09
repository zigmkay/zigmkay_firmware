const std = @import("std");

const keycodes = @import("test_data/keycodes.zig");
const us = @import("test_data/us_international.zig");
const german = @import("test_data/german_mac_iso.zig");

const core = @import("zigmkay").core;
const zkc_core = @import("src/core.zig");

test "basic keycode hex values" {
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 15 }, keycodes.kcf.L);
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 29 }, keycodes.kcf.Z);
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30 }, keycodes.kcf.N1);
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 45 }, keycodes.kcf.MINUS);
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 45 }, keycodes.kcf.MINS); // alias
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 53 }, keycodes.kcf.GRAVE);
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 53 }, keycodes.kcf.GRV); // alias
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 100 }, keycodes.kcf.NONUS_BACKSLASH);
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 100 }, keycodes.kcf.NUBS); // alias
}

test "german mac iso base keycodes" {
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 53, .dead = true }, german.CIRC); // KC_GRV (dead)
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 46, .dead = true }, german.ACUT); // KC_EQL (dead)
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 100 }, german.LABK); // KC_NUBS
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 15 }, german.L); // KC_L
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 45 }, german.SS); // KC_MINS
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30 }, german.N1); // KC_1
}

test "german mac iso shifted keycodes" {
    // S() sets left_shift modifier
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30, .tap_modifiers = .{ .left_shift = true } }, german.EXLM); // S(N1)
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 53, .tap_modifiers = .{ .left_shift = true } }, german.DEG); // S(CIRC)
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 100, .tap_modifiers = .{ .left_shift = true } }, german.RABK); // S(LABK)
    // verify using core.S helper
    try std.testing.expectEqual(zkc_core.L_SFT(german.N1), german.EXLM);
    try std.testing.expectEqual(zkc_core.L_SFT(german.CIRC), german.DEG);
    try std.testing.expectEqual(zkc_core.L_SFT(german.LABK), german.RABK);
}

test "german mac iso alt keycodes" {
    // A() sets left_alt modifier
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30, .tap_modifiers = .{ .left_alt = true } }, german.IEXL); // A(N1)
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 53, .tap_modifiers = .{ .left_alt = true } }, german.DLQU); // A(CIRC)
    try std.testing.expectEqual(zkc_core.L_ALT(german.N1), german.IEXL);
    try std.testing.expectEqual(zkc_core.L_ALT(german.CIRC), german.DLQU);
}

test "german mac iso shift+alt keycodes" {
    // S(A()) sets both left_shift and left_alt
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30, .tap_modifiers = .{ .left_shift = true, .left_alt = true } }, german.NOT); // S(A(N1))
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 45, .tap_modifiers = .{ .left_shift = true, .left_alt = true } }, german.DOTA); // S(A(SS))
    try std.testing.expectEqual(zkc_core.L_SFT(zkc_core.L_ALT(german.N1)), german.NOT);
    try std.testing.expectEqual(zkc_core.L_SFT(zkc_core.L_ALT(german.SS)), german.DOTA);
}

test "us international base keycodes" {
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 53, .dead = true }, us.DGRV); // KC_GRV (dead)
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 48 }, us.RBRC); // KC_RBRC
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30 }, us.N1); // KC_1
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 29 }, us.Z); // KC_Z
}

test "us international shifted keycodes" {
    // S() sets left_shift modifier
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30, .tap_modifiers = .{ .left_shift = true } }, us.EXLM); // S(N1)
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 53, .tap_modifiers = .{ .left_shift = true }, .dead = true }, us.DTIL); // DEAD(S(DGRV))
    try std.testing.expectEqual(zkc_core.L_SFT(us.N1), us.EXLM);
    try std.testing.expectEqual(zkc_core.DEAD(zkc_core.L_SFT(us.DGRV)), us.DTIL);
}

test "us international algr keycodes" {
    // ALGR() sets right_alt modifier
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30, .tap_modifiers = .{ .right_alt = true } }, us.IEXL); // ALGR(N1)
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 29, .tap_modifiers = .{ .right_alt = true } }, us.AE); // ALGR(Z)
    try std.testing.expectEqual(zkc_core.R_ALT(us.N1), us.IEXL);
    try std.testing.expectEqual(zkc_core.R_ALT(us.Z), us.AE);
}

test "us international shift+algr keycodes" {
    // S(ALGR()) sets both left_shift and right_alt
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 30, .tap_modifiers = .{ .left_shift = true, .right_alt = true } }, us.SUP1); // S(ALGR(N1))
    try std.testing.expectEqual(core.KeyCodeFire{ .tap_keycode = 46, .tap_modifiers = .{ .left_shift = true, .right_alt = true } }, us.DIV); // S(ALGR(EQL))
    try std.testing.expectEqual(zkc_core.L_SFT(zkc_core.R_ALT(us.N1)), us.SUP1);
    try std.testing.expectEqual(zkc_core.L_SFT(zkc_core.R_ALT(us.EQL)), us.DIV);
}

test "dead key flag is set correctly" {
    // German: base dead keys
    try std.testing.expect(german.CIRC.dead); // ^ (dead)
    try std.testing.expect(german.ACUT.dead); // ´ (dead)
    // German: shifted dead key
    try std.testing.expect(german.GRV.dead); // ` (dead) = DEAD(L_SFT(ACUT))
    // German: non-dead keys must not be marked dead, even those derived from dead keys
    try std.testing.expect(!german.N1.dead);
    try std.testing.expect(!german.DEG.dead); // ° is NOT dead (L_SFT strips the dead flag)
    try std.testing.expect(!german.EXLM.dead); // ! is NOT dead

    // US: base dead keys
    try std.testing.expect(us.DGRV.dead); // ` (dead)
    try std.testing.expect(us.ACUT.dead); // ´ (dead)
    // US: shifted dead keys
    try std.testing.expect(us.DTIL.dead); // ~ (dead) = DEAD(L_SFT(DGRV))
    try std.testing.expect(us.DIAE.dead); // ¨ (dead) = DEAD(L_SFT(ACUT))
    // US: non-dead keys
    try std.testing.expect(!us.N1.dead);
    try std.testing.expect(!us.EXLM.dead); // ! derived from non-dead N1
}
