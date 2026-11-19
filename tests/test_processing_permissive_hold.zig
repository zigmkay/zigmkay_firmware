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
const Expectation = enum { Hold, Tap };
const PermissiveHoldParameters = struct {
    target_release_delta_ms: u64,
    other_press_delta_ms: u64,
    other_release_delta_ms: u64,
    expectation: Expectation,
    tapping_terms_ms: u16,
};

fn run_permissive_hold_test(comptime config: PermissiveHoldParameters) !void {
    var current_time = core.TimeSinceBoot.from_absolute_us(100);
    const key_with_permissive_hold = core.KeyDef{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = c } },
        .hold = .{ .hold_modifiers = .{ .left_shift = true } },
        .tapping_term = core.TimeSpan{ .ms = config.tapping_terms_ms },
        .retro_tapping = false,
    } };

    const other_key_def = comptime helpers.TAP(b);
    const base_layer = comptime [_]?core.KeyDef{ key_with_permissive_hold, other_key_def, A };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    const target_key_index = 0;
    const other_key_index = 1;

    // Ensure nothing happens at first press when the key has multiple functions (both tap and hold)
    try o.press_key(target_key_index, current_time);
    current_time = current_time.add_ms(config.other_press_delta_ms);
    try o.press_key(other_key_index, current_time);
    current_time = current_time.add_ms(config.other_release_delta_ms);

    try o.release_key(other_key_index, current_time);

    current_time = current_time.add_ms(config.target_release_delta_ms);

    try o.release_key(target_key_index, current_time);
    try o.process(current_time);

    // expect A pressed as no layer switch is expected
    switch (config.expectation) {
        .Tap => {
            unreachable;
        },
        .Hold => {
            try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
            try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
            try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
            try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
        },
    }
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "MT perm hold - other key is tap, case A" {
    try run_permissive_hold_test(.{ .tapping_terms_ms = 250, .other_press_delta_ms = 1, .other_release_delta_ms = 2, .target_release_delta_ms = 3, .expectation = Expectation.Hold });
}
test "MT perm hold - other key is tap, case B" {
    try run_permissive_hold_test(.{ .tapping_terms_ms = 250, .other_press_delta_ms = 1, .other_release_delta_ms = 2, .target_release_delta_ms = 251, .expectation = Expectation.Hold });
}
test "MT perm hold - other key is tap, case C" {
    try run_permissive_hold_test(.{ .tapping_terms_ms = 250, .other_press_delta_ms = 247, .other_release_delta_ms = 248, .target_release_delta_ms = 249, .expectation = Expectation.Hold });
}
test "MT perm hold - other key is tap, case D" {
    try run_permissive_hold_test(.{ .tapping_terms_ms = 250, .other_press_delta_ms = 248, .other_release_delta_ms = 252, .target_release_delta_ms = 253, .expectation = Expectation.Hold });
}
test "MT perm hold - other key is tap, case E" {
    try run_permissive_hold_test(.{ .tapping_terms_ms = 250, .other_press_delta_ms = 252, .other_release_delta_ms = 500, .target_release_delta_ms = 501, .expectation = Expectation.Hold });
}
test "MT perm hold - other key is tap, case F" {
    try run_permissive_hold_test(.{ .tapping_terms_ms = 250, .other_press_delta_ms = 500, .other_release_delta_ms = 600, .target_release_delta_ms = 650, .expectation = Expectation.Hold });
}
test "MT - multiple holds, release in same order" {
    const current_time = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term = core.TimeSpan{ .ms = 250 };
    const key_a = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = a } }, .{ .left_shift = true }, tapping_term);
    const key_b = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = b } }, .{ .left_alt = true }, tapping_term);
    const key_c = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .left_ctrl = true }, tapping_term);
    const key_d = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = d } }, .{ .left_gui = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ key_a, key_b, key_c, key_d };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    // intexes
    const _a = 0;
    const _b = 1;
    const _c = 2;
    const _d = 3;

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // should be seen as modifiers:
    try o.press_key(_a, current_time);
    try o.press_key(_b, current_time);
    try o.press_key(_c, current_time);
    // should be seen as a tap:
    try o.press_key(_d, current_time);
    try o.release_key(_d, current_time);
    // modifier releases
    try o.release_key(_a, current_time);
    try o.release_key(_b, current_time);
    try o.release_key(_c, current_time);

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true, .left_ctrl = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = d }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = d }, o.actions_queue.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_alt = true, .left_ctrl = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_ctrl = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "MT - multiple holds, release in reverse order" {
    const tapping_term = core.TimeSpan{ .ms = 250 };
    var current_time = core.TimeSinceBoot.from_absolute_us(100);
    const key_a = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = a } }, .{ .left_shift = true }, tapping_term);
    const key_b = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = b } }, .{ .left_alt = true }, tapping_term);
    const key_c = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = c } }, .{ .left_ctrl = true }, tapping_term);
    const key_d = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = d } }, .{ .left_gui = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ key_a, key_b, key_c, key_d };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    // intexes
    const _a = 0;
    const _b = 1;
    const _c = 2;
    const _d = 3;

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // should be seen as modifiers:
    current_time = current_time.add_us(1);
    try o.press_key(_a, current_time);
    current_time = current_time.add_us(1);
    try o.press_key(_b, current_time);
    current_time = current_time.add_us(1);
    try o.press_key(_c, current_time);
    // should be seen as a tap:
    try o.press_key(_d, current_time);
    try o.release_key(_d, current_time);

    // modifier releases
    try o.release_key(_c, current_time);
    try o.release_key(_b, current_time);
    try o.release_key(_a, current_time);

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true, .left_ctrl = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = d }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = d }, o.actions_queue.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

