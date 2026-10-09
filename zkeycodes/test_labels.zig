const std = @import("std");

const keycodes = @import("test_data/keycodes.zig");
const us = @import("test_data/us_international.zig");
const german_mac_iso = @import("test_data/german_mac_iso.zig");

const core2 = @import("src/core.zig");

test "basic keycode labels" {
    try std.testing.expectEqualStrings("L", keycodes.getLabel(keycodes.kcf.L, false).?);
    try std.testing.expectEqualStrings("MINUS", keycodes.getLabel(keycodes.kcf.MINUS, false).?);
    try std.testing.expectEqualStrings("GRAVE", keycodes.getLabel(keycodes.kcf.GRAVE, false).?);
    try std.testing.expectEqualStrings("NONUS_BACKSLASH", keycodes.getLabel(keycodes.kcf.NONUS_BACKSLASH, false).?);
    try std.testing.expectEqualStrings("1", keycodes.getLabel(keycodes.kcf.N1, false).?);
}

test "shortest label option" {
    // MINUS (primary "MINUS") vs alias MINS ("MINS") — "MINS" is shorter
    try std.testing.expectEqualStrings("MINS", keycodes.getLabel(keycodes.kcf.MINUS, true).?);
    try std.testing.expectEqualStrings("MINS", keycodes.getLabel(keycodes.kcf.MINS, true).?);
    // GRAVE (primary "GRAVE") vs alias GRV ("GRV") — "GRV" is shorter
    try std.testing.expectEqualStrings("GRV", keycodes.getLabel(keycodes.kcf.GRAVE, true).?);
    try std.testing.expectEqualStrings("GRV", keycodes.getLabel(keycodes.kcf.GRV, true).?);
    // NONUS_BACKSLASH vs alias NUBS — "NUBS" is shorter
    try std.testing.expectEqualStrings("NUBS", keycodes.getLabel(keycodes.kcf.NONUS_BACKSLASH, true).?);
    // L has no alias, stays "L"
    try std.testing.expectEqualStrings("L", keycodes.getLabel(keycodes.kcf.L, true).?);
}

test "german mac iso base labels" {
    try std.testing.expectEqualStrings("CIRC", german_mac_iso.getLabel(german_mac_iso.CIRC, false).?);
    try std.testing.expectEqualStrings("SS", german_mac_iso.getLabel(german_mac_iso.SS, false).?);
    try std.testing.expectEqualStrings("L", german_mac_iso.getLabel(german_mac_iso.L, false).?);
    try std.testing.expectEqualStrings("ACUT", german_mac_iso.getLabel(german_mac_iso.ACUT, false).?);
    try std.testing.expectEqualStrings("LABK", german_mac_iso.getLabel(german_mac_iso.LABK, false).?);
}

test "german mac iso shifted labels" {
    try std.testing.expectEqualStrings("EXLM", german_mac_iso.getLabel(german_mac_iso.EXLM, false).?);
    try std.testing.expectEqualStrings("DEG", german_mac_iso.getLabel(german_mac_iso.DEG, false).?);
    try std.testing.expectEqualStrings("RABK", german_mac_iso.getLabel(german_mac_iso.RABK, false).?);
}

test "german mac iso alt labels" {
    try std.testing.expectEqualStrings("IEXL", german_mac_iso.getLabel(german_mac_iso.IEXL, false).?);
    try std.testing.expectEqualStrings("DLQU", german_mac_iso.getLabel(german_mac_iso.DLQU, false).?);
    try std.testing.expectEqualStrings("AT", german_mac_iso.getLabel(german_mac_iso.AT, false).?);
}

test "german mac iso shift+alt labels" {
    try std.testing.expectEqualStrings("NOT", german_mac_iso.getLabel(german_mac_iso.NOT, false).?);
    try std.testing.expectEqualStrings("DOTA", german_mac_iso.getLabel(german_mac_iso.DOTA, false).?);
    try std.testing.expectEqualStrings("GTEQ", german_mac_iso.getLabel(german_mac_iso.GTEQ, false).?);
}

test "us international base labels" {
    try std.testing.expectEqualStrings("RBRC", us.getLabel(us.RBRC, false).?);
    try std.testing.expectEqualStrings("DGRV", us.getLabel(us.DGRV, false).?);
    try std.testing.expectEqualStrings("BSLS", us.getLabel(us.BSLS, false).?);
}

test "us international shifted labels" {
    try std.testing.expectEqualStrings("EXLM", us.getLabel(us.EXLM, false).?);
    try std.testing.expectEqualStrings("DTIL", us.getLabel(us.DTIL, false).?);
    try std.testing.expectEqualStrings("COLN", us.getLabel(us.COLN, false).?);
}

test "us international algr labels" {
    try std.testing.expectEqualStrings("IEXL", us.getLabel(us.IEXL, false).?);
    try std.testing.expectEqualStrings("AE", us.getLabel(us.AE, false).?);
    try std.testing.expectEqualStrings("PILC", us.getLabel(us.PILC, false).?);
}

test "us international shift+algr labels" {
    try std.testing.expectEqualStrings("SUP1", us.getLabel(us.SUP1, false).?);
    try std.testing.expectEqualStrings("DIV", us.getLabel(us.DIV, false).?);
}

test "modifier bit logic" {
    // S() sets left_shift modifier
    try std.testing.expectEqual(core2.L_SFT(german_mac_iso.N1), german_mac_iso.EXLM);
    try std.testing.expectEqual(core2.L_SFT(us.N1), us.EXLM);
    // ALGR() sets right_alt modifier
    try std.testing.expectEqual(core2.R_ALT(us.N1), us.IEXL);
    try std.testing.expectEqual(core2.R_ALT(us.Z), us.AE);
    // A() sets left_alt modifier
    try std.testing.expectEqual(core2.L_ALT(german_mac_iso.N1), german_mac_iso.IEXL);
    // S(A()) sets both left_shift and left_alt
    try std.testing.expectEqual(core2.L_SFT(core2.L_ALT(german_mac_iso.N1)), german_mac_iso.NOT);
    // S(ALGR()) sets both left_shift and right_alt
    try std.testing.expectEqual(core2.L_SFT(core2.R_ALT(us.N1)), us.SUP1);
}

test "unknown keycode returns null" {
    // 0xFB (251) is not present in the test tables
    const unknown = @import("zigmkay").core.KeyCodeFire{ .tap_keycode = 0xFB };
    try std.testing.expect(keycodes.getLabel(unknown, false) == null);
    try std.testing.expect(german_mac_iso.getLabel(unknown, false) == null);
    try std.testing.expect(us.getLabel(unknown, false) == null);
}
