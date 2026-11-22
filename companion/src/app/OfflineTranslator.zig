//! US-layout key translation for fixtures, which never read the host's
//! keyboard layout.
const zkeymap = @import("zkeymap");

const OfflineTranslator = @This();

/// Translates every letter as upper case, to simulate a host layout change.
alternate: bool = false,

pub fn keyToText(self: *OfflineTranslator, input: zkeymap.KeyCodeFire) zkeymap.TextResult {
    const shifted = input.tap_modifiers.toByte() & shift_mask != 0;
    var result: zkeymap.TextResult = .{};
    if (character(input.tap_keycode, shifted, self.alternate)) |byte| {
        result.data[0] = byte;
        result.len = 1;
    }
    return result;
}

/// Left and right shift in the HID modifier byte.
const shift_mask = 0x22;

fn character(keycode: u8, shifted: bool, alternate: bool) ?u8 {
    return switch (keycode) {
        4...29 => @as(u8, if (alternate or shifted) 'A' else 'a') + keycode - 4,
        30...39 => (if (shifted) "!@#$%^&*()" else "1234567890")[keycode - 30],
        40 => '\n',
        43 => '\t',
        44 => ' ',
        45 => if (shifted) '_' else '-',
        46 => if (shifted) '+' else '=',
        47 => if (shifted) '{' else '[',
        48 => if (shifted) '}' else ']',
        49 => if (shifted) '|' else '\\',
        51 => if (shifted) ':' else ';',
        52 => if (shifted) '"' else '\'',
        53 => if (shifted) '~' else '`',
        54 => if (shifted) '<' else ',',
        55 => if (shifted) '>' else '.',
        56 => if (shifted) '?' else '/',
        else => null,
    };
}
