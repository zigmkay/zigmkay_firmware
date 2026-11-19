const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");
const init_with_config = helpers.init_with_config;

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
test "Rolling - only tap keys" {
    var current_time = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ A, B, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.press_key(0, current_time);
    current_time = current_time.add_us(1);
    try o.press_key(1, current_time);
    current_time = current_time.add_us(1);
    try o.release_key(0, current_time);
    current_time = current_time.add_us(1);
    try o.press_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.release_key(1, current_time);
    current_time = current_time.add_us(1);
    try o.press_key(3, current_time);
    current_time = current_time.add_us(1);
    try o.release_key(2, current_time);
    current_time = current_time.add_us(1);
    try o.release_key(3, current_time);
    current_time = current_time.add_us(1);

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = d }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = d }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "Rolling - tap/hold keys" {
    const current_time = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term = core.TimeSpan{ .ms = 250 };
    const _a = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = a } }, .{ .left_shift = true }, tapping_term);
    const _b = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = b } }, .{ .left_shift = true }, tapping_term);
    const _c = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .left_shift = true }, tapping_term);
    const _d = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = d } }, .{ .left_shift = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ _a, _b, _c, _d };

    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    try o.press_key(0, current_time);
    try o.press_key(1, current_time);
    try o.release_key(0, current_time);
    try o.press_key(2, current_time);
    try o.release_key(1, current_time);
    try o.press_key(3, current_time);
    try o.release_key(2, current_time);
    try o.release_key(3, current_time);

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = d }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = d }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "Rolling - with sudden shift usage" {
    // This test is supposed to spell out abCda with rolling behaviour combined with
    var current_time = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term = core.TimeSpan{ .ms = 250 };
    const key_a = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = a } }, .{}, tapping_term);
    const key_b = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = b } }, .{}, tapping_term);
    const key_c = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{}, tapping_term);
    const key_d = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = d } }, .{}, tapping_term);
    const key_e = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = e } }, .{ .left_shift = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ key_a, key_b, key_c, key_d, key_e };

    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    // intexes
    const _a = 0;
    const _b = 1;
    const _c = 2;
    const _d = 3;
    const _e_with_shift = 4;

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    current_time = current_time.add_us(1);
    try o.press_key(_a, current_time);
    current_time = current_time.add_us(2);
    try o.press_key(_b, current_time);
    current_time = current_time.add_us(3);
    try o.release_key(_a, current_time);
    current_time = current_time.add_us(5);
    try o.release_key(_b, current_time);
    current_time = current_time.add_us(4);
    try o.press_key(_e_with_shift, current_time);
    current_time = current_time.add_us(6);
    try o.press_key(_c, current_time);
    current_time = current_time.add_us(7);
    try o.release_key(_c, current_time);
    current_time = current_time.add_us(8);
    try o.release_key(_e_with_shift, current_time);
    current_time = current_time.add_us(9);
    try o.press_key(_d, current_time);
    current_time = current_time.add_us(10);
    try o.press_key(_a, current_time);
    current_time = current_time.add_us(11);
    try o.release_key(_d, current_time);
    current_time = current_time.add_us(12);
    try o.release_key(_a, current_time);

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = d }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = d }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "Rolling - with sudden permanent layer shift" {
    // This test is supposed to spell out abCda with rolling behaviour combined with
    var current_time = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term = core.TimeSpan{ .ms = 250 };

    const layer_hold = comptime helpers.LT(1, b, .{}, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ A, A, A, A, layer_hold };
    const layer_1 = comptime [_]?core.KeyDef{ C, C, C, C, C };

    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };

    // intexes
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    current_time = current_time.add_us(1);
    try o.press_key(1, current_time);
    try o.press_key(4, current_time);
    try o.release_key(1, current_time);
    current_time = current_time.add_ms(1000); // ensure layer hold tapping term expired
    try o.press_key(1, current_time);
    try o.release_key(1, current_time);
    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

