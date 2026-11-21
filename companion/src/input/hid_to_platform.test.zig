const std = @import("std");
const testing = std.testing;
const zkeycodes = @import("zkeycodes");
const hid = @import("hid_to_platform");
const ScanCode = zkeycodes.layouts.keycodes.kc.basic;

test "toPlatformMods: empty value returns 0" {
    try testing.expectEqual(@as(u8, 0), hid.toPlatformMods(.{}));
}

test "toPlatformMods: left_shift sets bit 0" {
    try testing.expectEqual(@as(u8, 0b0001), hid.toPlatformMods(.{ .left_shift = true }));
}

test "toPlatformMods: right_shift sets bit 0" {
    try testing.expectEqual(@as(u8, 0b0001), hid.toPlatformMods(.{ .right_shift = true }));
}

test "toPlatformMods: both shifts collapse to bit 0" {
    try testing.expectEqual(
        @as(u8, 0b0001),
        hid.toPlatformMods(.{ .left_shift = true, .right_shift = true }),
    );
}

test "toPlatformMods: left_ctrl sets bit 1" {
    try testing.expectEqual(@as(u8, 0b0010), hid.toPlatformMods(.{ .left_ctrl = true }));
}

test "toPlatformMods: right_ctrl sets bit 1" {
    try testing.expectEqual(@as(u8, 0b0010), hid.toPlatformMods(.{ .right_ctrl = true }));
}

test "toPlatformMods: left_alt sets bit 2" {
    try testing.expectEqual(@as(u8, 0b0100), hid.toPlatformMods(.{ .left_alt = true }));
}

test "toPlatformMods: right_alt sets bit 2" {
    try testing.expectEqual(@as(u8, 0b0100), hid.toPlatformMods(.{ .right_alt = true }));
}

test "toPlatformMods: left_gui sets bit 3" {
    try testing.expectEqual(@as(u8, 0b1000), hid.toPlatformMods(.{ .left_gui = true }));
}

test "toPlatformMods: right_gui sets bit 3" {
    try testing.expectEqual(@as(u8, 0b1000), hid.toPlatformMods(.{ .right_gui = true }));
}

test "toPlatformMods: all 8 modifiers combined" {
    try testing.expectEqual(@as(u8, 0b1111), hid.toPlatformMods(.{
        .left_shift = true,
        .right_shift = true,
        .left_ctrl = true,
        .right_ctrl = true,
        .left_alt = true,
        .right_alt = true,
        .left_gui = true,
        .right_gui = true,
    }));
}

test "toPlatformMods: no modifiers returns 0" {
    try testing.expectEqual(@as(u8, 0), hid.toPlatformMods(.{}));
}

test "Modifiers roundtrip: all 256 byte values" {
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const mods = hid.Modifiers.fromByte(@intCast(i));
        try testing.expectEqual(@as(u8, @intCast(i)), mods.toByte());
    }
}

test "hidToMacVk: KC_A maps to kVK_ANSI_A" {
    const result = hid.hidToMacVk(@backingInt(ScanCode.KC_A));
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 0x00), result.?);
}

test "hidToMacVk: KC_RETURN maps to kVK_Return" {
    const result = hid.hidToMacVk(@backingInt(ScanCode.KC_ENTER));
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 0x24), result.?);
}

test "hidToMacVk: modifier codes return null" {
    try testing.expect(hid.hidToMacVk(0xE0) == null); // KC_LEFT_CTRL
    try testing.expect(hid.hidToMacVk(0xE1) == null); // KC_LEFT_SHIFT
}

test "hidToMacVk: invalid code returns null" {
    try testing.expect(hid.hidToMacVk(0xFF) == null);
}

test "hidToWinVk: KC_A maps to 'A'" {
    const result = hid.hidToWinVk(@backingInt(ScanCode.KC_A));
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 'A'), result.?);
}

test "hidToWinVk: KC_ENTER maps to VK_RETURN" {
    const result = hid.hidToWinVk(@backingInt(ScanCode.KC_ENTER));
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 0x0D), result.?);
}

test "hidToWinVk: modifier codes return null" {
    try testing.expect(hid.hidToWinVk(0xE0) == null); // KC_LEFT_CTRL
    try testing.expect(hid.hidToWinVk(0xE1) == null); // KC_LEFT_SHIFT
}

test "hidToWinVk: invalid code returns null" {
    try testing.expect(hid.hidToWinVk(0xFF) == null);
}

test "hidToXkbKeycode: KC_A maps to evdev+8 = 38" {
    const result = hid.hidToXkbKeycode(@backingInt(ScanCode.KC_A));
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 38), result.?);
}

test "hidToXkbKeycode: KC_SPACE maps to evdev+8 = 65" {
    const result = hid.hidToXkbKeycode(@backingInt(ScanCode.KC_SPACE));
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 65), result.?);
}

test "hidToXkbKeycode: modifier codes return null" {
    try testing.expect(hid.hidToXkbKeycode(0xE0) == null); // KC_LEFT_CTRL
    try testing.expect(hid.hidToXkbKeycode(0xE1) == null); // KC_LEFT_SHIFT
}

test "hidToXkbKeycode: invalid code returns null" {
    try testing.expect(hid.hidToXkbKeycode(0xFF) == null);
}
