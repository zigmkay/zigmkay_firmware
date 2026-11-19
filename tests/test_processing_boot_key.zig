const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");

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
test "boot key test" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const boot_key = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = core.special_keycode_BOOT } } };
    const base_layer = comptime [_]?core.KeyDef{ A, B, boot_key, D };

    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 2 });

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand.ActivateBootMode, o.actions_queue.dequeue());

    // Doesnt matter what comes after in the usb command queue when boot mode is entered
}

test "boot key as a combo test" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ A, B, C, D };

    const boot_key = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = core.special_keycode_BOOT } } };
    const combos = comptime [_]core.Combo2Def{.{ .key_indexes = .{ 1, 2 }, .layer = 0, .timeout = .{ .ms = 200 }, .key_def = boot_key }};

    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = helpers.init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .combos = &combos }){};

    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 2 });

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand.ActivateBootMode, o.actions_queue.dequeue());

    // Doesnt matter what comes after in the usb command queue when boot mode is entered
}
