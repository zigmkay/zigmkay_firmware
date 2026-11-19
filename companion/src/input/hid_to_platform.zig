const std = @import("std");

/// Compile-time lookup tables mapping USB HID page-0x07 scan codes to each
/// platform's native keycode space.
///
/// Sources:
///   Linux evdev:  kernel hid-input.c hid_keyboard[] array
///   Windows VK:   winuser.h VK_* constants
///   macOS Carbon: HIToolbox/Events.h kVK_* constants
///   xkbcommon:    evdev keycode + 8  (X11 convention used by xkb_keymap_new_from_names)
const zkeycodes = @import("zkeycodes");
const ScanCode = zkeycodes.layouts.keycodes.kc.basic;

/// Converts zkeycodes.Modifiers (left/right split) to the platform 8-bit format.
///
/// Platform format:
///   bit 0 = shift
///   bit 1 = ctrl
///   bit 2 = alt
///   bit 3 = gui
///   bit 4 = caps_lock
///   bit 5 = num_lock
///
/// zkeycodes.Modifiers uses left/right split for ctrl/shift/alt/gui.
/// This function collapses them: if either left OR right modifier is set,
/// the corresponding platform bit is set.
pub const Modifiers = @FieldType(
    @typeInfo(@TypeOf(zkeycodes.core.L_CTL)).@"fn".return_type.?,
    "tap_modifiers",
);

pub fn toPlatformMods(m: Modifiers) u8 {
    var result: u8 = 0;
    if (m.left_shift or m.right_shift) result |= 1 << 0;
    if (m.left_ctrl or m.right_ctrl) result |= 1 << 1;
    if (m.left_alt or m.right_alt)
        result |= 1 << 2; // TODO: windows handles right alt as ctrl+alt? Do we need to change the translation?
    if (m.left_gui or m.right_gui) result |= 1 << 3;
    return result;
}

// ─── macOS Carbon virtual key codes ──────────────────────────────────────────

pub fn hidToMacVk(code: u8) ?u16 {
    const sc = std.enums.fromInt(ScanCode, code) orelse return null;
    return switch (sc) {
        .KC_A => 0x00, // kVK_ANSI_A
        .KC_S => 0x01, // kVK_ANSI_S
        .KC_D => 0x02, // kVK_ANSI_D
        .KC_F => 0x03, // kVK_ANSI_F
        .KC_H => 0x04, // kVK_ANSI_H
        .KC_G => 0x05, // kVK_ANSI_G
        .KC_Z => 0x06, // kVK_ANSI_Z
        .KC_X => 0x07, // kVK_ANSI_X
        .KC_C => 0x08, // kVK_ANSI_C
        .KC_V => 0x09, // kVK_ANSI_V
        .KC_NONUS_BACKSLASH => 0x0A, // kVK_ISO_Section
        .KC_B => 0x0B, // kVK_ANSI_B
        .KC_Q => 0x0C, // kVK_ANSI_Q
        .KC_W => 0x0D, // kVK_ANSI_W
        .KC_E => 0x0E, // kVK_ANSI_E
        .KC_R => 0x0F, // kVK_ANSI_R
        .KC_Y => 0x10, // kVK_ANSI_Y
        .KC_T => 0x11, // kVK_ANSI_T
        .KC_1 => 0x12, // kVK_ANSI_1
        .KC_2 => 0x13, // kVK_ANSI_2
        .KC_3 => 0x14, // kVK_ANSI_3
        .KC_4 => 0x15, // kVK_ANSI_4
        .KC_6 => 0x16, // kVK_ANSI_6
        .KC_5 => 0x17, // kVK_ANSI_5
        .KC_EQUAL => 0x18, // kVK_ANSI_Equal
        .KC_9 => 0x19, // kVK_ANSI_9
        .KC_7 => 0x1A, // kVK_ANSI_7
        .KC_MINUS => 0x1B, // kVK_ANSI_Minus
        .KC_8 => 0x1C, // kVK_ANSI_8
        .KC_0 => 0x1D, // kVK_ANSI_0
        .KC_RIGHT_BRACKET => 0x1E, // kVK_ANSI_RightBracket
        .KC_O => 0x1F, // kVK_ANSI_O
        .KC_U => 0x20, // kVK_ANSI_U
        .KC_LEFT_BRACKET => 0x21, // kVK_ANSI_LeftBracket
        .KC_I => 0x22, // kVK_ANSI_I
        .KC_P => 0x23, // kVK_ANSI_P
        .KC_ENTER => 0x24, // kVK_Return
        .KC_L => 0x25, // kVK_ANSI_L
        .KC_J => 0x26, // kVK_ANSI_J
        .KC_QUOTE => 0x27, // kVK_ANSI_Quote
        .KC_K => 0x28, // kVK_ANSI_K
        .KC_SEMICOLON => 0x29, // kVK_ANSI_Semicolon
        .KC_BACKSLASH => 0x2A, // kVK_ANSI_Backslash
        .KC_COMMA => 0x2B, // kVK_ANSI_Comma
        .KC_SLASH => 0x2C, // kVK_ANSI_Slash
        .KC_N => 0x2D, // kVK_ANSI_N
        .KC_M => 0x2E, // kVK_ANSI_M
        .KC_DOT => 0x2F, // kVK_ANSI_Period
        .KC_TAB => 0x30, // kVK_Tab
        .KC_SPACE => 0x31, // kVK_Space
        .KC_GRAVE => 0x32, // kVK_ANSI_Grave
        .KC_BACKSPACE => 0x33, // kVK_Delete
        .KC_ESCAPE => 0x35, // kVK_Escape
        .KC_CAPS_LOCK => 0x39, // kVK_CapsLock
        .KC_F17 => 0x40, // kVK_F17 (non-sequential on macOS)
        .KC_KP_DOT => 0x41, // kVK_ANSI_KeypadDecimal
        .KC_KP_ASTERISK => 0x43, // kVK_ANSI_KeypadMultiply
        .KC_KP_PLUS => 0x45, // kVK_ANSI_KeypadPlus
        .KC_NUM_LOCK => 0x47, // kVK_ANSI_KeypadClear (macOS "Clear" = NumLock position)
        .KC_KP_SLASH => 0x4B, // kVK_ANSI_KeypadDivide
        .KC_KP_ENTER => 0x4C, // kVK_ANSI_KeypadEnter
        .KC_KP_MINUS => 0x4E, // kVK_ANSI_KeypadMinus
        .KC_F18 => 0x4F, // kVK_F18
        .KC_F19 => 0x50, // kVK_F19
        .KC_KP_EQUAL => 0x51, // kVK_ANSI_KeypadEquals
        .KC_KP_0 => 0x52, // kVK_ANSI_Keypad0
        .KC_KP_1 => 0x53, // kVK_ANSI_Keypad1
        .KC_KP_2 => 0x54, // kVK_ANSI_Keypad2
        .KC_KP_3 => 0x55, // kVK_ANSI_Keypad3
        .KC_KP_4 => 0x56, // kVK_ANSI_Keypad4
        .KC_KP_5 => 0x57, // kVK_ANSI_Keypad5
        .KC_KP_6 => 0x58, // kVK_ANSI_Keypad6
        .KC_KP_7 => 0x59, // kVK_ANSI_Keypad7
        .KC_F20 => 0x5A, // kVK_F20
        .KC_KP_8 => 0x5B, // kVK_ANSI_Keypad8
        .KC_KP_9 => 0x5C, // kVK_ANSI_Keypad9
        .KC_F5 => 0x60, // kVK_F5
        .KC_F6 => 0x61, // kVK_F6
        .KC_F7 => 0x62, // kVK_F7
        .KC_F3 => 0x63, // kVK_F3
        .KC_F8 => 0x64, // kVK_F8
        .KC_F9 => 0x65, // kVK_F9
        .KC_F11 => 0x67, // kVK_F11
        .KC_F13 => 0x69, // kVK_F13
        .KC_F16 => 0x6A, // kVK_F16
        .KC_F14 => 0x6B, // kVK_F14
        .KC_F10 => 0x6D, // kVK_F10
        .KC_F12 => 0x6F, // kVK_F12
        .KC_F15 => 0x71, // kVK_F15
        .KC_INSERT => 0x72, // kVK_Help (PC Insert → Mac Help)
        .KC_HOME => 0x73, // kVK_Home
        .KC_PAGE_UP => 0x74, // kVK_PageUp
        .KC_DELETE => 0x75, // kVK_ForwardDelete
        .KC_F4 => 0x76, // kVK_F4
        .KC_END => 0x77, // kVK_End
        .KC_F2 => 0x78, // kVK_F2
        .KC_PAGE_DOWN => 0x79, // kVK_PageDown
        .KC_F1 => 0x7A, // kVK_F1
        .KC_LEFT => 0x7B, // kVK_LeftArrow
        .KC_RIGHT => 0x7C, // kVK_RightArrow
        .KC_DOWN => 0x7D, // kVK_DownArrow
        .KC_UP => 0x7E, // kVK_UpArrow
        else => null,
    };
}

// ─── Windows Virtual Key codes ───────────────────────────────────────────────

pub fn hidToWinVk(code: u8) ?u8 {
    const sc = std.enums.fromInt(ScanCode, code) orelse return null;
    return switch (sc) {
        .KC_A => 'A',
        .KC_B => 'B',
        .KC_C => 'C',
        .KC_D => 'D',
        .KC_E => 'E',
        .KC_F => 'F',
        .KC_G => 'G',
        .KC_H => 'H',
        .KC_I => 'I',
        .KC_J => 'J',
        .KC_K => 'K',
        .KC_L => 'L',
        .KC_M => 'M',
        .KC_N => 'N',
        .KC_O => 'O',
        .KC_P => 'P',
        .KC_Q => 'Q',
        .KC_R => 'R',
        .KC_S => 'S',
        .KC_T => 'T',
        .KC_U => 'U',
        .KC_V => 'V',
        .KC_W => 'W',
        .KC_X => 'X',
        .KC_Y => 'Y',
        .KC_Z => 'Z',
        .KC_1 => '1',
        .KC_2 => '2',
        .KC_3 => '3',
        .KC_4 => '4',
        .KC_5 => '5',
        .KC_6 => '6',
        .KC_7 => '7',
        .KC_8 => '8',
        .KC_9 => '9',
        .KC_0 => '0',
        .KC_ENTER => 0x0D, // VK_RETURN
        .KC_ESCAPE => 0x1B, // VK_ESCAPE
        .KC_BACKSPACE => 0x08, // VK_BACK
        .KC_TAB => 0x09, // VK_TAB
        .KC_SPACE => 0x20, // VK_SPACE
        .KC_CAPS_LOCK => 0x14, // VK_CAPITAL
        .KC_MINUS => 0xBD, // VK_OEM_MINUS
        .KC_EQUAL => 0xBB, // VK_OEM_PLUS
        .KC_LEFT_BRACKET => 0xDB, // VK_OEM_4
        .KC_RIGHT_BRACKET => 0xDD, // VK_OEM_6
        .KC_BACKSLASH => 0xDC, // VK_OEM_5
        .KC_SEMICOLON => 0xBA, // VK_OEM_1
        .KC_QUOTE => 0xDE, // VK_OEM_7
        .KC_GRAVE => 0xC0, // VK_OEM_3
        .KC_COMMA => 0xBC, // VK_OEM_COMMA
        .KC_DOT => 0xBE, // VK_OEM_PERIOD
        .KC_SLASH => 0xBF, // VK_OEM_2
        .KC_NONUS_BACKSLASH => 0xE2, // VK_OEM_102
        .KC_F1 => 0x70,
        .KC_F2 => 0x71,
        .KC_F3 => 0x72,
        .KC_F4 => 0x73,
        .KC_F5 => 0x74,
        .KC_F6 => 0x75,
        .KC_F7 => 0x76,
        .KC_F8 => 0x77,
        .KC_F9 => 0x78,
        .KC_F10 => 0x79,
        .KC_F11 => 0x7A,
        .KC_F12 => 0x7B,
        .KC_F13 => 0x7C,
        .KC_F14 => 0x7D,
        .KC_F15 => 0x7E,
        .KC_F16 => 0x7F,
        .KC_F17 => 0x80,
        .KC_F18 => 0x81,
        .KC_F19 => 0x82,
        .KC_F20 => 0x83,
        .KC_F21 => 0x84,
        .KC_F22 => 0x85,
        .KC_F23 => 0x86,
        .KC_F24 => 0x87,
        .KC_PRINT_SCREEN => 0x2C, // VK_SNAPSHOT
        .KC_SCROLL_LOCK => 0x91, // VK_SCROLL
        .KC_PAUSE => 0x13, // VK_PAUSE
        .KC_INSERT => 0x2D, // VK_INSERT
        .KC_HOME => 0x24, // VK_HOME
        .KC_PAGE_UP => 0x21, // VK_PRIOR
        .KC_DELETE => 0x2E, // VK_DELETE
        .KC_END => 0x23, // VK_END
        .KC_PAGE_DOWN => 0x22, // VK_NEXT
        .KC_RIGHT => 0x27, // VK_RIGHT
        .KC_LEFT => 0x25, // VK_LEFT
        .KC_DOWN => 0x28, // VK_DOWN
        .KC_UP => 0x26, // VK_UP
        .KC_NUM_LOCK => 0x90, // VK_NUMLOCK
        .KC_KP_SLASH => 0x6F, // VK_DIVIDE
        .KC_KP_ASTERISK => 0x6A, // VK_MULTIPLY
        .KC_KP_MINUS => 0x6D, // VK_SUBTRACT
        .KC_KP_PLUS => 0x6B, // VK_ADD
        .KC_KP_ENTER => 0x0D, // VK_RETURN (extended)
        .KC_KP_1 => 0x61,
        .KC_KP_2 => 0x62,
        .KC_KP_3 => 0x63,
        .KC_KP_4 => 0x64,
        .KC_KP_5 => 0x65,
        .KC_KP_6 => 0x66,
        .KC_KP_7 => 0x67,
        .KC_KP_8 => 0x68,
        .KC_KP_9 => 0x69,
        .KC_KP_0 => 0x60, // VK_NUMPAD0
        .KC_KP_DOT => 0x6E, // VK_DECIMAL
        .KC_APPLICATION => 0x5D, // VK_APPS
        else => null,
    };
}

// ─── xkbcommon keycodes (evdev + 8, for use with xkb_keymap_new_from_names) ──

pub fn hidToXkbKeycode(code: u8) ?u16 {
    const sc = std.enums.fromInt(ScanCode, code) orelse return null;
    const evdev: u16 = switch (sc) {
        .KC_A => 30,
        .KC_B => 48,
        .KC_C => 46,
        .KC_D => 32,
        .KC_E => 18,
        .KC_F => 33,
        .KC_G => 34,
        .KC_H => 35,
        .KC_I => 23,
        .KC_J => 36,
        .KC_K => 37,
        .KC_L => 38,
        .KC_M => 50,
        .KC_N => 49,
        .KC_O => 24,
        .KC_P => 25,
        .KC_Q => 16,
        .KC_R => 19,
        .KC_S => 31,
        .KC_T => 20,
        .KC_U => 22,
        .KC_V => 47,
        .KC_W => 17,
        .KC_X => 45,
        .KC_Y => 21,
        .KC_Z => 44,
        .KC_1 => 2,
        .KC_2 => 3,
        .KC_3 => 4,
        .KC_4 => 5,
        .KC_5 => 6,
        .KC_6 => 7,
        .KC_7 => 8,
        .KC_8 => 9,
        .KC_9 => 10,
        .KC_0 => 11,
        .KC_ENTER => 28, // KEY_ENTER
        .KC_ESCAPE => 1, // KEY_ESC
        .KC_BACKSPACE => 14, // KEY_BACKSPACE
        .KC_TAB => 15, // KEY_TAB
        .KC_SPACE => 57, // KEY_SPACE
        .KC_MINUS => 12, // KEY_MINUS
        .KC_EQUAL => 13, // KEY_EQUAL
        .KC_LEFT_BRACKET => 26, // KEY_LEFTBRACE
        .KC_RIGHT_BRACKET => 27, // KEY_RIGHTBRACE
        .KC_BACKSLASH => 43, // KEY_BACKSLASH
        .KC_SEMICOLON => 39, // KEY_SEMICOLON
        .KC_QUOTE => 40, // KEY_APOSTROPHE
        .KC_GRAVE => 41, // KEY_GRAVE
        .KC_COMMA => 51, // KEY_COMMA
        .KC_DOT => 52, // KEY_DOT
        .KC_SLASH => 53, // KEY_SLASH
        .KC_CAPS_LOCK => 58, // KEY_CAPSLOCK
        .KC_F1 => 59,
        .KC_F2 => 60,
        .KC_F3 => 61,
        .KC_F4 => 62,
        .KC_F5 => 63,
        .KC_F6 => 64,
        .KC_F7 => 65,
        .KC_F8 => 66,
        .KC_F9 => 67,
        .KC_F10 => 68,
        .KC_F11 => 87,
        .KC_F12 => 88,
        .KC_F13 => 183,
        .KC_F14 => 184,
        .KC_F15 => 185,
        .KC_F16 => 186,
        .KC_F17 => 187,
        .KC_F18 => 188,
        .KC_F19 => 189,
        .KC_F20 => 190,
        .KC_F21 => 191,
        .KC_F22 => 192,
        .KC_F23 => 193,
        .KC_F24 => 194,
        .KC_PRINT_SCREEN => 99, // KEY_SYSRQ
        .KC_SCROLL_LOCK => 70, // KEY_SCROLLLOCK
        .KC_PAUSE => 119, // KEY_PAUSE
        .KC_INSERT => 110, // KEY_INSERT
        .KC_HOME => 102, // KEY_HOME
        .KC_PAGE_UP => 104, // KEY_PAGEUP
        .KC_DELETE => 111, // KEY_DELETE
        .KC_END => 107, // KEY_END
        .KC_PAGE_DOWN => 109, // KEY_PAGEDOWN
        .KC_RIGHT => 106, // KEY_RIGHT
        .KC_LEFT => 105, // KEY_LEFT
        .KC_DOWN => 108, // KEY_DOWN
        .KC_UP => 103, // KEY_UP
        .KC_NUM_LOCK => 69, // KEY_NUMLOCK
        .KC_KP_SLASH => 98, // KEY_KPSLASH
        .KC_KP_ASTERISK => 55, // KEY_KPASTERISK
        .KC_KP_MINUS => 74, // KEY_KPMINUS
        .KC_KP_PLUS => 78, // KEY_KPPLUS
        .KC_KP_ENTER => 96, // KEY_KPENTER
        .KC_KP_1 => 79,
        .KC_KP_2 => 80,
        .KC_KP_3 => 81,
        .KC_KP_4 => 75,
        .KC_KP_5 => 76,
        .KC_KP_6 => 77,
        .KC_KP_7 => 71,
        .KC_KP_8 => 72,
        .KC_KP_9 => 73,
        .KC_KP_0 => 82,
        .KC_KP_DOT => 83, // KEY_KPDOT
        .KC_KP_EQUAL => 117, // KEY_KPEQUAL
        .KC_NONUS_BACKSLASH => 86, // KEY_102ND
        .KC_APPLICATION => 127, // KEY_COMPOSE
        .KC_KB_POWER => 116, // KEY_POWER
        else => return null,
    };
    return evdev + 8;
}
