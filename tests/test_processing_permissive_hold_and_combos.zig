const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");

const a = 4;
const b = 5;
const c = 6;
const d = 7;
const e = 8;
const f = 9;
const g = 10;
const h = 11;
const i = 12;

const A = helpers.TAP(a);
const B = helpers.TAP(b);
const C = helpers.TAP(c);
const D = helpers.TAP(d);
const E = helpers.TAP(e);
const F = helpers.TAP(f);
const G = helpers.TAP(g);
const H = helpers.TAP(h);
const I = helpers.TAP(i);
test "combo hold, single key press" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };
    const base_layer = comptime [_]?core.KeyDef{ A, B, C };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 0, 1 }, .layer = 0, .timeout = combo_timeout, .key_def = core.KeyDef{ .hold_only = .{ .hold_modifiers = .{ .left_shift = true } } } }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};

    try o.press_key(0, current_time);
    try o.press_key(1, current_time);
    try o.press_key(2, current_time);
    try o.release_key(2, current_time);
    try o.release_key(0, current_time);
    try o.release_key(1, current_time);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "single key hold, combo key press" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };
    const key_hold = core.KeyDef{ .hold_only = .{ .hold_modifiers = .{ .left_shift = true } } };
    const base_layer = comptime [_]?core.KeyDef{ key_hold, B, C };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    const combos = comptime [_]core.Combo2Def{
        .{ .key_indexes = .{ 1, 2 }, .layer = 0, .timeout = combo_timeout, .key_def = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = e } } } },
    };

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};

    try o.press_key(0, current_time);
    try o.press_key(1, current_time);
    try o.press_key(2, current_time);
    try o.release_key(2, current_time);
    try o.release_key(1, current_time);
    try o.release_key(0, current_time);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = e }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = e }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "combo hold, combo key press" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };
    const base_layer = comptime [_]?core.KeyDef{ A, B, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    const combos = comptime [_]core.Combo2Def{
        .{ .key_indexes = .{ 0, 1 }, .layer = 0, .timeout = combo_timeout, .key_def = core.KeyDef{ .hold_only = .{ .hold_modifiers = .{ .left_shift = true } } } },
        .{ .key_indexes = .{ 2, 3 }, .layer = 0, .timeout = combo_timeout, .key_def = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = e } } } },
    };

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};

    try o.press_key(0, current_time);
    try o.press_key(1, current_time);
    try o.press_key(2, current_time);
    try o.press_key(3, current_time);
    try o.release_key(2, current_time);
    try o.release_key(3, current_time);
    try o.release_key(0, current_time);
    try o.release_key(1, current_time);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = e }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = e }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());
}

