const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");
const init_with_config = helpers.init_with_config;

const KC_SPACE = 0x2C;

const a = 0x04;
const b = 0x05;
const c = 0x06;
const d = 0x07;
const e = 0x08;
const f = 0x09;
const g = 0x10;

const A = helpers.TAP(a);
const B = helpers.TAP(b);
const C = helpers.TAP(c);
const D = helpers.TAP(d);
const E = helpers.TAP(e);
const F = helpers.TAP(f);
const G = helpers.TAP(g);
// test stuff
test "Dead keys - ensure space added IFF dead is true - single true case" {
    const tap_with_dead = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = a, .dead = true } } };
    const tap_without_dead = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = b, .dead = false } } };

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ tap_with_dead, tap_without_dead };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 }); // dead
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 }); // dead

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(4, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = KC_SPACE }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = KC_SPACE }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "Dead keys - ensure space added IFF dead is true - single false case" {
    const tap_with_dead = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = a, .dead = true } } };
    const tap_without_dead = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = b, .dead = false } } };

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ tap_with_dead, tap_without_dead };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 }); // non dead
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 }); // non dead

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(2, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "Dead keys - with retrotapping" {
    const dead_with_retro_tapping = core.KeyDef{
        .tap_hold = .{
            .tap = .{ .key_press = .{ .tap_keycode = a, .dead = true } },
            .hold = .{ .hold_modifiers = .{ .left_alt = true } },
            .retro_tapping = true,
            .tapping_term = .{ .ms = 250 },
        },
    };

    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{dead_with_retro_tapping};
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.press_key(0, current_time);
    current_time = current_time.add_ms(1000);
    try o.release_key(0, current_time);

    // press keys
    // wait for tapping term to expire
    // ensure layer has actually switched
    try o.process(current_time);

    try std.testing.expectEqual(6, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = KC_SPACE }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = KC_SPACE }, o.actions_queue.dequeue());
}
