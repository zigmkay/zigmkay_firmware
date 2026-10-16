const zigmkay = @import("zigmkay");
const core = zigmkay.core;
/// helper to add Left Control modifier to a core.KeyCodeFire.
pub fn L_CTL(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = false;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .left_ctrl = true });

    return copy;
}

/// helper to add Right Control modifier to a core.KeyCodeFire.
pub fn R_CTL(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = false;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .right_ctrl = true });

    return copy;
}

/// helper to add Left Shift modifier to a core.KeyCodeFire.
pub fn L_SFT(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = false;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .left_shift = true });
    return copy;
}

/// helper to add Right Shift modifier to a core.KeyCodeFire.
pub fn R_SFT(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = false;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .right_shift = true });

    return copy;
}

/// helper to add Left GUI (Windows/Command) modifier to a core.KeyCodeFire.
pub fn L_GUI(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = false;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .left_gui = true });

    return copy;
}

/// helper to add Right GUI (Windows/Command) modifier to a core.KeyCodeFire.
pub fn R_GUI(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = false;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .right_gui = true });

    return copy;
}

/// helper to add Left Alt modifier to a core.KeyCodeFire.
pub fn L_ALT(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = false;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .left_alt = true });

    return copy;
}

/// helper to add Right Alt modifier to a core.KeyCodeFire.
pub fn R_ALT(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = false;
    copy.tap_modifiers = copy.tap_modifiers.add(.{ .right_alt = true });

    return copy;
}

/// Sets the dead key flag on a core.KeyCodeFire. Dead keys send the keycode followed by a
/// spacebar press to cancel the dead key combination.
pub fn DEAD(fire: core.KeyCodeFire) core.KeyCodeFire {
    var copy = fire;
    copy.dead = true;
    return copy;
}

pub const LabelEntry = struct {
    value: core.KeyCodeFire,
    label: []const u8,
    short_label: []const u8,
};

/// Looks up `keycode` in `table` by matching both `tap_keycode` and `tap_modifiers`.
/// This distinguishes e.g. `S(KC_1)` ("EXLM") from plain `KC_1` ("1").
pub fn getLabel(table: []const LabelEntry, keycode: core.KeyCodeFire, shortest: bool) ?[]const u8 {
    const key_mods = keycode.tap_modifiers.toByte();
    for (table) |entry| {
        const entry_mods = entry.value.tap_modifiers.toByte();
        if (entry.value.tap_keycode == keycode.tap_keycode and entry_mods == key_mods) {
            return if (shortest) entry.short_label else entry.label;
        }
    }
    return null;
}
