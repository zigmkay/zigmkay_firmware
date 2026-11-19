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
test "Encoders - encoder action event raised - expect tap fired" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ A, B, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    const a_tap = core.TapDef{ .key_press = .{ .tap_keycode = a } };
    const b_tap = core.TapDef{ .key_press = .{ .tap_keycode = b } };
    const c_tap = core.TapDef{ .key_press = .{ .tap_keycode = c } };

    const encoder_actions = [_]core.EncoderAction{ .{ .tap = a_tap }, .{ .tap = b_tap }, .{ .tap = c_tap } };
    var o = init_with_config(
        .{ .key_count = base_layer.len, .layer_count = keymap.len },
        .{
            .keymap = &keymap,
            .encoder_actions = &encoder_actions,
        },
    ){};

    try o.encoder_event_queue.enqueue(.{ .encoder_action_index = 1 }); // b fired
    try o.process(current_time);

    try std.testing.expectEqual(2, o.actions_queue.Count());
    try std.testing.expectEqual(b, o.actions_queue.dequeue().?.KeyCodePress);
    //try std.testing.expectEqual(b, o.actions_queue.dequeue().?.KeyCodeRelease);

    try std.testing.expectEqual(0, o.encoder_event_queue.Count());
}

test "Encoders - no encoder actions defined - ensure not breaking when encoder event raised" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ A, B, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.encoder_event_queue.enqueue(.{ .encoder_action_index = 1 });
    try o.process(current_time);

    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.encoder_event_queue.Count());
}

test "Encoders - action index out of bounds - ensure not breaking when encoder event raised" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ A, B, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    const a_tap = core.TapDef{ .key_press = .{ .tap_keycode = a } };
    const b_tap = core.TapDef{ .key_press = .{ .tap_keycode = a } };
    const c_tap = core.TapDef{ .key_press = .{ .tap_keycode = a } };

    const encoder_actions = [_]core.EncoderAction{ .{ .tap = a_tap }, .{ .tap = b_tap }, .{ .tap = c_tap } };
    var o = init_with_config(
        .{ .key_count = base_layer.len, .layer_count = keymap.len },
        .{
            .keymap = &keymap,
            .encoder_actions = &encoder_actions,
        },
    ){};

    try o.encoder_event_queue.enqueue(.{ .encoder_action_index = 3 });
    try o.process(current_time);

    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.encoder_event_queue.Count());
}
