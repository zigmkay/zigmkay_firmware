const builtin = @import("builtin");
const root = @import("root.zig");
const KeyCodeFire = root.KeyCodeFire;
const isLayoutDependent = root.isLayoutDependent;

const OsKeyMap = if (@import("options").us_fixture) @import("platform/test_us.zig").Fixture else if (!root.native_available) @import("platform/dummy.zig").DummyKeyMap else switch (builtin.target.os.tag) {
    .macos => @import("platform/macos.zig").MacOsKeyMap,
    .windows => @import("platform/windows.zig").WindowsKeyMap,
    .linux => @import("platform/linux.zig").LinuxKeyMap,
    else => @import("platform/dummy.zig").DummyKeyMap,
};

/// Cross-platform keyboard layout context.
///
/// Usage:
///   var km: KeyMap = undefined;
///   KeyMap.init(&km);
///   defer KeyMap.deinit(&km);
///
///   const result = km.keyToText(.{ .tap_keycode = @intFromEnum(ScanCode.KC_A) });
///   // result.slice() → "a"
pub const KeyMap = struct {
    os: ?*OsKeyMap = null,

    /// Initialise the context and load the current OS keyboard layout.
    pub fn init(km: *KeyMap) void {
        km.* = .{ .os = OsKeyMap.init() };
    }

    /// Release OS resources. Must be called exactly once when done.
    pub fn deinit(km: *KeyMap) void {
        if (km.os) |os| os.deinit();
        km.os = null;
    }

    /// Re-fetch the active keyboard layout from the OS.
    /// Call this when the user switches input methods at the system level.
    pub fn refresh(km: *KeyMap) void {
        if (km.os) |os| os.refresh();
    }

    /// Convert a single key event to a UTF-8 text result.
    ///
    /// - Keys with a fixed label (F1–F24, arrows, Escape, Tab, Backspace,
    ///   Enter, Home, End, …) return that label string (e.g. "F11", "TAB",
    ///   "BACKSPACE") regardless of modifiers or the active layout.
    /// - Layout-dependent keys (letters, digits, punctuation, numpad) are
    ///   translated by the OS backend.
    /// - The first press of a dead key returns len=0; the composed character
    ///   is returned on the subsequent call.
    pub fn keyToText(km: *KeyMap, input: KeyCodeFire) root.TextResult {
        if (isLayoutDependent(input.tap_keycode)) {
            return if (km.os) |os| os.keyToText(input) else .{};
        }
        return textResultFromLabel(input);
    }

    pub fn available(km: *const KeyMap) bool {
        return km.os != null;
    }
};

/// Creates a TextResult for fixed-label keys by packing the KeyCodeFire's
/// tap_keycode into the data field. The isLabel() check will return true
/// because len=0 but data contains the packed scancode.
fn textResultFromLabel(kcf: KeyCodeFire) root.TextResult {
    var r = root.TextResult{};
    r.data[0..2].* = @bitCast(@as(u16, kcf.tap_keycode));
    return r;
}
