//! Offline screenshot layouts; they never alter a saved project or firmware.
const desktop = @import("desktop-core");

/// The generic layout of the rundown fixtures.
pub fn install(model: *desktop.model.Model) !void {
    const previous_layer = model.layer;
    model.layer = 3;
    // Explicit US punctuation actions establish real fixture routes. The
    // ordinary imported QWERTY template does not contain every symbol route.
    for ([_]struct { usize, u8 }{ .{ 0, 52 }, .{ 1, 51 }, .{ 2, 45 }, .{ 3, 38 }, .{ 4, 39 }, .{ 5, 30 } }) |entry| {
        model.select(entry[0], false);
        try model.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = entry[1] } } });
    }
    model.layer = previous_layer;
    try model.rename("QWERTY fixture");
    model.saved_id = try model.id();
}

/// Turns one base-layer key into a tap-hold key, which the help gallery
/// explains.
pub fn installTapHold(model: *desktop.model.Model) !void {
    const previous_layer = model.layer;
    model.layer = 0;
    model.select(16, false);
    try model.apply(.{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = 13 } },
        .hold = .{ .hold_modifiers = .{ .right_shift = true } },
        .tapping_term = .{ .ms = 180 },
    } });
    model.layer = previous_layer;
    model.saved_id = try model.id();
}
