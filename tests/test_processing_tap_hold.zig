const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");
const init_with_config = helpers.init_with_config;

const a = 4;
const b = 5;
const c = 6;
const d = 7;
const e = 8;
const f = 9;
const g = 10;

const A = helpers.TAP(a);
const B = helpers.TAP(b);
const C = helpers.TAP(c);
const D = helpers.TAP(d);
const E = helpers.TAP(e);
const F = helpers.TAP(f);
const G = helpers.TAP(g);
test "MT tap within tapping term - process with both in queue" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term: core.TimeSpan = .{ .ms = 250 };
    const mo_layer1_cWithLeftAlt = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .left_shift = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ mo_layer1_cWithLeftAlt, B, A };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Ensure nothing happens at first press when the key has multiple functions (both tap and hold)
    try o.press_key(0, current_time);

    // Now ensure that a tap will happen when releasing within tapping term
    current_time = current_time.add_us(10); // within tapping term
    try o.release_key(0, current_time);
    try o.process(current_time);

    // expect A pressed as no layer switch is expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "MT tap within tapping term - process with multiple calls" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term: core.TimeSpan = .{ .ms = 250 };
    const mo_layer1_cWithLeftAlt = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .left_shift = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ mo_layer1_cWithLeftAlt, B, A };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Ensure nothing happens at first press when the key has multiple functions (both tap and hold)
    try o.press_key(0, current_time);

    try o.process(current_time);
    try o.process(current_time);
    // Now ensure that a tap will happen when releasing within tapping term
    current_time = current_time.add_us(10); // within tapping term
    try o.release_key(0, current_time);
    try o.process(current_time);

    // expect A pressed as no layer switch is expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "MT hold case: release after tapping term => hold" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term: core.TimeSpan = .{ .ms = 250 };
    const mo_layer1_cWithLeftAlt = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .left_alt = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ mo_layer1_cWithLeftAlt, B, A };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Ensure nothing happens at first press when the key has multiple functions (both tap and hold)
    try o.press_key(0, current_time);

    // Now ensure that a tap will happen when releasing within tapping term
    current_time = current_time.add_ms(tapping_term.ms + 1);
    try o.release_key(0, current_time);

    try o.process(current_time);

    // expect A pressed as no layer switch is expected
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "MT hold case: timeout => hold" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term: core.TimeSpan = .{ .ms = 250 };
    const mo_layer1_cWithLeftAlt = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .left_alt = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ mo_layer1_cWithLeftAlt, B, A };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Ensure nothing happens at first press when the key has multiple functions (both tap and hold)
    try o.press_key(0, current_time);

    // Now ensure that a tap will happen when releasing within tapping term

    current_time = current_time.add_ms(tapping_term.ms + 1); // within tapping term

    try o.process(current_time);

    // expect A pressed as no layer switch is expected
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_alt = true } }, o.actions_queue.dequeue());
    //try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
