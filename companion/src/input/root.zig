const std = @import("std");
const testing = std.testing;
pub const zkeycodes = @import("zkeycodes");
pub const KeyCodeFire = @typeInfo(@TypeOf(zkeycodes.core.L_CTL)).@"fn".return_type.?;
const keycodes = zkeycodes.layouts.keycodes;
pub const ScanCode = keycodes.kc.basic;
const zkcGetLabel = keycodes.getLabel;

pub const KeyMap = @import("KeyMap.zig").KeyMap;
/// Compile/link capability, not evidence that the desktop's active layout is known.
pub const native_available = @import("options").native_available;
pub const hid_to_platform = @import("hid_to_platform.zig");

pub const TextResult = struct {
    /// UTF-8 encoded bytes, if key-label (e.g. "BACKSPACE", "F11"), we smuggle ScanCode in here
    data: [4]u8 = @splat(0),
    /// Number of valid bytes in 'data' (0 means no text produced)
    len: u8 = 0,

    /// True when 'data' contains a human-readable key label ("F11", "TAB",
    /// "BACKSPACE", …) rather than layout-translated text.  Callers that only
    /// want typed characters should skip results where is_label is true.
    pub fn isLabel(self: *const TextResult) bool {
        return self.len == 0 and @as(u32, @bitCast(self.data)) != 0;
    }

    pub fn getLabel(self: *const TextResult) []const u8 {
        const raw = @as(u16, @bitCast(self.data[0..2].*));
        const kcf = KeyCodeFire{ .tap_keycode = @truncate(raw) };
        return zkcGetLabel(kcf, true) orelse "";
    }

    /// Helper to get a slice of the actual text
    pub fn slice(self: *const TextResult) []const u8 {
        return self.data[0..self.len];
    }
};

/// Returns true if the raw HID scancode is layout-dependent.
///
/// Layout-dependent keys are those whose output depends on the OS keyboard layout:
/// - Letters (A-Z)
/// - Digits (1-0)
/// - Punctuation and special characters
/// - Numpad digits and operators
///
/// Fixed-label keys (function keys, escape, arrows, etc.) return false because
/// their labels are independent of the keyboard layout.
///
/// Takes u16 instead of ScanCode enum because comparing against enum variants
/// requires listing every single variant - ranges are simpler and more maintainable.
pub fn isLayoutDependent(code: u16) bool {
    return switch (code) {
        0x04...0x1D => true, // Letters A-Z
        0x1E...0x27 => true, // Digits 1-0
        0x2C...0x38 => true, // Punctuation including space
        0x54...0x63 => true, // Numpad digits and operators
        else => false, // Fixed-label keys (F1-F24, ESC, arrows, etc.)
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "keyLabel: layout-dependent keys return true" {
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_A)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_Z)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_1)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_0)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_SPACE)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_DOT)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_SLASH)));
}

test "keyLabel: function keys return false (fixed labels)" {
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_F1)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_F11)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_F12)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_F24)));
}

test "keyLabel: navigation keys return false (fixed labels)" {
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_UP)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_DOWN)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_LEFT)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_RIGHT)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_HOME)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_END)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_INSERT)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_DELETE)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_PAGE_UP)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_PAGE_DOWN)));
}

test "keyLabel: system and lock keys return false (fixed labels)" {
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_CAPS_LOCK)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_NUM_LOCK)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_PRINT_SCREEN)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_SCROLL_LOCK)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_PAUSE)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_APPLICATION)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_KB_POWER)));
}

test "keyLabel: control keys return false (fixed labels)" {
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_ESCAPE)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_TAB)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_BACKSPACE)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_ENTER)));
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "TextResult.slice returns correct bytes" {
    var r = TextResult{};
    r.data[0] = 'h';
    r.data[1] = 'i';
    r.len = 2;
    try testing.expectEqualStrings("hi", r.slice());
}

test "TextResult.slice with four-byte UTF-8 sequence" {
    // 4-byte UTF-8 sequence: U+1F600 GRINNING FACE (0xF0 0x9F 0x98 0x80)
    var r = TextResult{};
    r.data[0] = 0xF0;
    r.data[1] = 0x9F;
    r.data[2] = 0x98;
    r.data[3] = 0x80;
    r.len = 4;
    try testing.expectEqualSlices(u8, &.{ 0xF0, 0x9F, 0x98, 0x80 }, r.slice());
}

test "TextResult default is empty and not a label" {
    const r = TextResult{};
    try testing.expectEqual(@as(u8, 0), r.len);
    try testing.expectEqualStrings("", r.slice());
    try testing.expect(!r.isLabel());
}

test "fixed HID label decoding needs no native layout context" {
    const result = TextResult{ .data = .{ 58, 0, 0, 0 } };
    try testing.expect(result.isLabel());
    try testing.expectEqualStrings("F1", result.getLabel());
}

test "unavailable native backend keeps fixed labels and returns empty text" {
    var km: KeyMap = .{};
    try testing.expect(!km.available());
    try testing.expectEqualStrings("", km.keyToText(.{ .tap_keycode = 4 }).slice());
    const label = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_F1) });
    try testing.expectEqualStrings("F1", label.getLabel());
    km.refresh();
    km.deinit();
}
