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
test "activate, key1, key2" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const base_layer = comptime [_]?core.KeyDef{ A, B, C };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 1, 2 }, .layer = 0, .timeout = combo_timeout, .key_def = G }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(1, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());

    current_time = current_time.add_ms(combo_timeout.ms - 1); // pressed within timeout
    try o.press_key(2, current_time);
    current_time = current_time.add_us(1);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = g }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());

    // ensure nothing happens when releasing second key
    current_time = current_time.add_us(1);
    try o.release_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());

    // ensure released when releasing first key
    current_time = current_time.add_us(1);
    try o.release_key(1, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = g }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "different layer from current" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const base_layer = comptime [_]?core.KeyDef{ A, B, C };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 1, 2 }, .layer = 1, .timeout = combo_timeout, .key_def = G }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(1, current_time);
    try o.press_key(0, current_time);
    try o.press_key(2, current_time);

    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    try o.release_key(1, current_time);
    try o.release_key(0, current_time);
    try o.release_key(2, current_time);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "activate, key2, key1" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const base_layer = comptime [_]?core.KeyDef{ A, B, C };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 1, 2 }, .layer = 0, .timeout = combo_timeout, .key_def = G }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_ms(25);
    try o.press_key(1, current_time);
    current_time = current_time.add_us(1);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = g }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());

    // ensure nothing happens when releasing second key
    current_time = current_time.add_us(1);
    try o.release_key(1, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());

    // ensure released when releasing first key
    current_time = current_time.add_us(1);
    try o.release_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = g }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "tap-only: key1 timeout" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const base_layer = comptime [_]?core.KeyDef{ A, B, C };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 1, 2 }, .layer = 0, .timeout = combo_timeout, .key_def = G }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(1, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());

    current_time = current_time.add_ms(combo_timeout.ms + 1);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    try o.release_key(1, current_time);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "key2 timeout" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const base_layer = comptime [_]?core.KeyDef{ A, B, C };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 1, 2 }, .layer = 0, .timeout = combo_timeout, .key_def = G }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());

    current_time = current_time.add_ms(combo_timeout.ms + 1); // pressed within timeout

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    try o.release_key(2, current_time);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "other key inbetween" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const base_layer = comptime [_]?core.KeyDef{ A, B, C };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 1, 2 }, .layer = 0, .timeout = combo_timeout, .key_def = G }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(1, current_time);
    try o.press_key(0, current_time);
    try o.press_key(2, current_time);

    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    current_time = current_time.add_ms(combo_timeout.ms + 1); // this will timeout the press of the last key, c

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());

    try o.release_key(1, current_time);
    try o.release_key(0, current_time);
    try o.release_key(2, current_time);

    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "activate with tap/hold on one of the keys, key1, key2" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const a_shift = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = a } }, .{ .left_shift = true }, .{ .ms = 150 });
    const b_shift = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = b } }, .{ .left_shift = true }, .{ .ms = 150 });
    const c_shift = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .left_shift = true }, .{ .ms = 150 });
    const base_layer = comptime [_]?core.KeyDef{ a_shift, b_shift, c_shift };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 1, 2 }, .layer = 0, .timeout = combo_timeout, .key_def = G }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(1, current_time);
    current_time = current_time.add_us(1);

    try o.process(current_time);

    try std.testing.expectEqual(0, o.actions_queue.Count());

    current_time = current_time.add_ms(combo_timeout.ms - 1); // pressed within timeout
    try o.press_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = g }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());

    // ensure nothing happens when releasing second key
    current_time = current_time.add_us(1);
    try o.release_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());

    // ensure released when releasing first key
    current_time = current_time.add_us(1);
    try o.release_key(1, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = g }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "ensure correct layers combo is chosen" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const layer_1_hold = core.KeyDef{ .hold_only = .{ .hold_layer = 1 } };

    const base_layer = comptime [_]?core.KeyDef{ A, A, layer_1_hold };
    const layer_1 = comptime [_]?core.KeyDef{ B, B, B };
    const layer_2 = comptime [_]?core.KeyDef{ C, C, C };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1, layer_2 };
    const combos = comptime [_]core.Combo2Def{
        .{ .key_indexes = .{ 0, 1 }, .layer = 0, .timeout = combo_timeout, .key_def = D },
        .{ .key_indexes = .{ 0, 1 }, .layer = 1, .timeout = combo_timeout, .key_def = E },
        .{ .key_indexes = .{ 0, 1 }, .layer = 2, .timeout = combo_timeout, .key_def = F },
    };

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};

    try o.press_key(2, current_time); // to switch layer to layer 1
    current_time = current_time.add_ms(1000);
    try o.press_key(0, current_time);
    try o.press_key(1, current_time);

    current_time = current_time.add_us(1);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = e }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    try o.release_key(0, current_time);
    try o.release_key(1, current_time);

    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = e }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "custom code activate another layer - ensure combo works" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const layer1_hold = core.KeyDef{ .hold_only = .{ .hold_layer = 1 } };
    const layer2_hold = core.KeyDef{ .hold_only = .{ .hold_layer = 2 } };

    const MyFunctions = struct {
        var layer3_is_active = false;
        fn on_event(event: core.ProcessorEvent, layers: *core.LayerActivations, output_queue: *core.OutputCommandQueue) void {
            _ = output_queue;
            switch (event) {
                .OnHoldEnterAfter => |data| {
                    _ = data;
                    layer3_is_active = layers.is_layer_active(1) and layers.is_layer_active(2);
                    layers.set_layer_state(3, layer3_is_active);
                },
                .OnHoldExitAfter => |data| {
                    _ = data;
                    layer3_is_active = layers.is_layer_active(1) and layers.is_layer_active(2);
                    layers.set_layer_state(3, layer3_is_active);
                },
                else => {},
            }
        }
    };

    const custom_functions = core.CustomFunctions{
        .on_event = MyFunctions.on_event,
    };
    const base_layer = comptime [_]?core.KeyDef{ A, layer1_hold, layer2_hold, B };
    const layer_1 = comptime [_]?core.KeyDef{ D, layer1_hold, layer2_hold, B };
    const layer_2 = comptime [_]?core.KeyDef{ D, layer1_hold, layer2_hold, B };
    const layer_3 = comptime [_]?core.KeyDef{ E, E, E, E };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1, layer_2, layer_3 };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 0, 3 }, .layer = 3, .timeout = combo_timeout, .key_def = G }};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos, .custom_functions = &custom_functions }){};
    try o.press_key(1, current_time);
    try o.press_key(2, current_time);
    try std.testing.expectEqual(false, MyFunctions.layer3_is_active);

    try o.process(current_time);

    // Now both layers should be active, hence layer 3 should also be active
    try std.testing.expectEqual(true, MyFunctions.layer3_is_active);

    // now fire the combo
    try o.press_key(0, current_time);
    try o.press_key(3, current_time);

    try o.release_key(0, current_time);
    try o.release_key(3, current_time);

    try o.process(current_time);
    try std.testing.expectEqual(true, MyFunctions.layer3_is_active);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = g }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = g }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "combo is hold/tap: combo released slowly => hold" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 30 };

    const combos = comptime [_]core.Combo2Def{.{
        .key_indexes = .{ 1, 2 },
        .layer = 0,
        .timeout = combo_timeout,
        .key_def = helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = h } }, .{ .left_shift = true }, .{ .ms = 150 }),
    }};
    const base_layer = comptime [_]?core.KeyDef{ A, B, C };
    const layer_1 = comptime [_]?core.KeyDef{ D, E, F };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(1, current_time);
    current_time = current_time.add_us(1);
    try o.press_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.process(current_time);
    current_time = current_time.add_ms(160);
    try o.process(current_time);
    try o.release_key(1, current_time);
    try o.release_key(2, current_time);

    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "Ensure waiting on combos" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const combo_timeout = core.TimeSpan{ .ms = 200 };

    const _A = core.KeyDef{ .tap_hold = .{ .tap = .{ .key_press = .{ .tap_keycode = a } }, .hold = .{ .hold_modifiers = .{ .left_ctrl = true } }, .tapping_term = .{ .ms = 150 } } };
    const _B = core.KeyDef{ .tap_hold = .{ .tap = .{ .key_press = .{ .tap_keycode = b } }, .hold = .{ .hold_modifiers = .{ .left_shift = true } }, .tapping_term = .{ .ms = 150 } } };
    const combos = comptime [_]core.Combo2Def{.{
        .key_indexes = .{ 0, 1 },
        .layer = 0,
        .timeout = combo_timeout,
        .key_def = helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .right_alt = true, .right_ctrl = true }, .{ .ms = 250 }),
    }};

    const base_layer = comptime [_]?core.KeyDef{ _A, _B };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};
    try o.press_key(0, current_time);
    try o.process(current_time);
    try o.press_key(1, current_time);

    current_time = current_time.add_ms(500);
    try o.process(current_time);
    try o.release_key(0, current_time);
    try o.process(current_time);
    try o.release_key(1, current_time);
    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .right_ctrl = true, .right_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());
}
