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

test "TRANSPARENT case 1" {
    // Transparent key - ensure key on lower active layers used - case A - expect fallback to next active layer

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo1_key = comptime helpers.MO(1);
    const mo2_key = comptime helpers.MO(2);
    const mo3_key = comptime helpers.MO(3);
    const base_layer = comptime [_]?core.KeyDef{ A, mo1_key, mo2_key, A, A, A };
    const layer_1 = comptime [_]?core.KeyDef{ B, B, B, mo3_key, B, B };
    const layer_2 = comptime [_]?core.KeyDef{ C, C, C, C, C, C };
    const layer_3 = comptime [_]?core.KeyDef{ null, helpers.NONE(), D, D, D, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1, layer_2, layer_3 };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Hold for layer switch 1 and 3
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 3 });

    // Tap a transparent key at position 0 which is transparent - expect layer 1's key do be pushed
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    try o.process(current_time);

    // Press B expected
    try std.testing.expectEqual(b, o.actions_queue.dequeue().?.KeyCodePress);
    try std.testing.expectEqual(b, o.actions_queue.dequeue().?.KeyCodeRelease);

    // Expect no more actions
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "TRANSPARENT case 2" {
    // Layers - transparent key - ensure key on lower active layers used - case B - transparent on lower layers as well, expect fallback to base layer

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo1_key = comptime helpers.MO(1);
    const mo2_key = comptime helpers.MO(2);
    const mo3_key = comptime helpers.MO(3);
    const base_layer = comptime [_]?core.KeyDef{ A, mo1_key, mo2_key, A, A, A };
    const layer_1 = comptime [_]?core.KeyDef{ null, B, B, mo3_key, B, B };
    const layer_2 = comptime [_]?core.KeyDef{ C, C, C, C, C, C };
    const layer_3 = comptime [_]?core.KeyDef{ null, helpers.NONE(), D, D, D, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1, layer_2, layer_3 };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Hold for layer switch 1 and 3
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 3 });

    // Tap a transparent key at position 0 which is transparent - expect layer 1's key do be pushed
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    try o.process(current_time);

    // Press A expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());

    // Expect no more actions
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "TRANSPARENT case 3" {
    // Layers - transparent key - ensure transparent key on base layer won't do anything

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo1_key = comptime helpers.MO(1);
    const mo2_key = comptime helpers.MO(2);
    const mo3_key = comptime helpers.MO(3);
    const base_layer = comptime [_]?core.KeyDef{ null, mo1_key, mo2_key, mo3_key, A, A };
    const layer_1 = comptime [_]?core.KeyDef{ null, B, B, B, B, B };
    const layer_2 = comptime [_]?core.KeyDef{ C, C, C, C, C, C };
    const layer_3 = comptime [_]?core.KeyDef{ null, helpers.NONE(), D, D, D, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1, layer_2, layer_3 };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Hold for layer switch 1 and 3
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 3 });

    // Tap a transparent key at position 0 which is transparent - expect layer 1's key do be pushed
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    try o.process(current_time);

    // Expect no more actions
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "NONE key" {
    // Expect nothing to happen

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo1_key = comptime helpers.MO(1);
    const base_layer = comptime [_]?core.KeyDef{ A, A, mo1_key };
    const layer_1 = comptime [_]?core.KeyDef{ helpers.NONE(), D, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Hold for layer switch 1
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 });

    // Tap a transparent key at position 0 which is NONE - expect nothing to happen
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    try o.process(current_time);

    // Expect no more actions
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
