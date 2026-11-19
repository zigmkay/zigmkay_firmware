const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");

const a = 0x04;
const b = 0x05;
const c = 0x06;
const d = 0x07;
const e = 0x08;
const f = 0x09;
const g = 0x10;

const A = helpers.TAP(a);
const B = helpers.TAP(b);
const C = helpers.TAP(c);
const D = helpers.TAP(d);
const E = helpers.TAP(e);
const F = helpers.TAP(f);
const G = helpers.TAP(g);
// These tests exist to ensure that it will be an intentional change,
// when the sizes and alignments change of the types that are part of the keymap
// as this is a type that may exist in copies in the hundreds when a big keyboard has lots of layers
test "Struct size: KeyDef" {
    try std.testing.expectEqual(28, @sizeOf(core.KeyDef));
}
test "Struct size: TapDef" {
    try std.testing.expectEqual(18, @sizeOf(core.TapDef));
}
test "Struct size: HoldDef" {
    try std.testing.expectEqual(5, @sizeOf(core.HoldDef));
    try std.testing.expectEqual(1, @alignOf(core.HoldDef));
}
test "Struct size: Modifiers" {
    try std.testing.expectEqual(1, @sizeOf(core.Modifiers));
    try std.testing.expectEqual(1, @alignOf(core.Modifiers));
}
test "Struct size: TapHold" {
    try std.testing.expectEqual(26, @sizeOf(core.TapHoldDef));
}
test "Struct size: AutoFireDef" {
    try std.testing.expectEqual(22, @sizeOf(core.AutoFireDef));
}
test "Struct size: KeyCodeFire" {
    try std.testing.expectEqual(3, @sizeOf(core.KeyCodeFire));
    try std.testing.expectEqual(1, @alignOf(core.KeyCodeFire));
}
test "Keymap of 36 keys with 5 layers - sanity checking" {
    // roughly 4kb
    try std.testing.expectEqual(5040, @sizeOf([5][36]core.KeyDef));
}
