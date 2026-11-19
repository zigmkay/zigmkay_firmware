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

const dummy_time = core.TimeStamp{ .time_us_since_boot = 0 };

// test stuff
test "Autofire - case A" {
    // release before start, expect only one
    const auto_fire_a = comptime core.KeyDef{ .tap_with_autofire = .{
        .initial_delay = .{ .ms = 1000 },
        .repeat_interval = .{ .ms = 500 },
        .tap = .{ .key_press = .{ .tap_keycode = a } },
    } };
    const auto_fire_b = comptime core.KeyDef{ .tap_with_autofire = .{
        .initial_delay = .{ .ms = 1000 },
        .repeat_interval = .{ .ms = 500 },
        .tap = .{ .key_press = .{ .tap_keycode = b } },
    } };

    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ auto_fire_a, auto_fire_b, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(
        .{ .key_count = base_layer.len, .layer_count = keymap.len },
        .{ .keymap = &keymap },
    ){};

    const key_a_idx = 0;

    try o.press_key(key_a_idx, current_time);
    current_time = current_time.add_us(1);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_us(50);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_ms(1);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_ms(998);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_ms(999);
    // Now release the key - and expect no autofire
    try o.release_key(key_a_idx, current_time);
    current_time = current_time.add_ms(1001);
    try o.process(current_time);
    current_time = current_time.add_ms(2000);
    try o.process(current_time);

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "Autofire - case B" {
    // holding down and activating autofire
    const auto_fire_a = comptime core.KeyDef{ .tap_with_autofire = .{
        .initial_delay = .{ .ms = 1000 },
        .repeat_interval = .{ .ms = 500 },
        .tap = .{ .key_press = .{ .tap_keycode = a } },
    } };
    const auto_fire_b = comptime core.KeyDef{ .tap_with_autofire = .{
        .initial_delay = .{ .ms = 1000 },
        .repeat_interval = .{ .ms = 500 },
        .tap = .{ .key_press = .{ .tap_keycode = b } },
    } };

    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ auto_fire_a, auto_fire_b, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    const key_a_idx = 0;

    try o.press_key(key_a_idx, current_time);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    current_time = current_time.add_ms(1);
    try o.process(current_time);
    current_time = current_time.add_ms(999);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_ms(2);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    current_time = current_time.add_ms(450);

    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_ms(100);

    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    current_time = current_time.add_ms(1800);

    try o.release_key(key_a_idx, current_time);
    current_time = current_time.add_ms(1801);

    try o.process(current_time);
    current_time = current_time.add_ms(2020);

    try o.process(current_time);
    current_time = current_time.add_ms(5000);

    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "Autofire - case C" {
    // holding down and activating autofire, pressing another autofire key - expect new key to autofire
    const auto_fire_a = comptime core.KeyDef{ .tap_with_autofire = .{
        .initial_delay = .{ .ms = 1000 },
        .repeat_interval = .{ .ms = 500 },
        .tap = .{ .key_press = .{ .tap_keycode = a } },
    } };
    const auto_fire_b = comptime core.KeyDef{ .tap_with_autofire = .{
        .initial_delay = .{ .ms = 1000 },
        .repeat_interval = .{ .ms = 500 },
        .tap = .{ .key_press = .{ .tap_keycode = b } },
    } };

    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ auto_fire_a, auto_fire_b, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    const key_a_idx = 0;
    const key_b_idx = 1;

    try o.press_key(key_a_idx, current_time);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());

    current_time = current_time.add_ms(1);
    try o.process(current_time);
    current_time = current_time.add_ms(999);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_ms(2);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    current_time = current_time.add_us(1950);
    try o.press_key(key_b_idx, current_time);

    current_time = current_time.add_ms(100);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    current_time = current_time.add_ms(1000);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());

    current_time = current_time.add_ms(3202);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    current_time = current_time.add_ms(1800);
    try o.release_key(key_b_idx, current_time);

    current_time = current_time.add_ms(5000);
    try o.release_key(key_a_idx, current_time);

    current_time = current_time.add_ms(5000);
    try o.process(current_time);

    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "Autofire - case D" {
    // press autofire A, then press autofire B => expect B to be autofired
    // then release A, expect still autofiring B,
    // then release b, expect autofire to stop
    const auto_fire_a = comptime core.KeyDef{ .tap_with_autofire = .{
        .initial_delay = .{ .ms = 1000 },
        .repeat_interval = .{ .ms = 500 },
        .tap = .{ .key_press = .{ .tap_keycode = a } },
    } };
    const auto_fire_b = comptime core.KeyDef{ .tap_with_autofire = .{
        .initial_delay = .{ .ms = 1000 },
        .repeat_interval = .{ .ms = 500 },
        .tap = .{ .key_press = .{ .tap_keycode = b } },
    } };

    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ auto_fire_a, auto_fire_b, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    const key_a_idx = 0;
    const key_b_idx = 1;

    // press A
    try o.press_key(key_a_idx, current_time);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    // ensure a is aurofiring
    current_time = current_time.add_ms(1001);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    // press b
    try o.press_key(key_b_idx, current_time);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
    current_time = current_time.add_ms(1001);

    // ensure b is autofiring
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    // release a
    try o.release_key(key_a_idx, current_time);
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());

    // ensure b is still autofiring
    current_time = current_time.add_ms(1001);
    try o.process(current_time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());

    // release b
    try o.release_key(key_b_idx, current_time);

    // ensure no autofiring
    try o.process(current_time);
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
