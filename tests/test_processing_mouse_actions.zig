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
test "Mouse actions - left button - only press" {
    try run_mouse_action_test_internal(core.MouseAction.LeftButton, false);
}

test "Mouse actions - left button - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.LeftButton, true);
}

test "Mouse actions - right button - only press" {
    try run_mouse_action_test_internal(core.MouseAction.RightButton, false);
}

test "Mouse actions - right button - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.RightButton, true);
}

test "Mouse actions - middle button - only press" {
    try run_mouse_action_test_internal(core.MouseAction.MiddleButton, false);
}

test "Mouse actions - middle button - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.MiddleButton, true);
}

test "Mouse actions - button4 - only press" {
    try run_mouse_action_test_internal(core.MouseAction.Button4, false);
}

test "Mouse actions - button4 - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.Button4, true);
}

test "Mouse actions - button5 - only press" {
    try run_mouse_action_test_internal(core.MouseAction.Button5, false);
}

test "Mouse actions - button5 - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.Button5, true);
}

test "Mouse actions - WheelUp tick - only press" {
    try run_mouse_action_test_internal(core.MouseAction.WheelUp, false);
}

test "Mouse actions - WheelUp tick - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.WheelUp, true);
}

test "Mouse actions - WheelDown tick - only press" {
    try run_mouse_action_test_internal(core.MouseAction.WheelDown, false);
}
test "Mouse actions - WheelDown tick - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.WheelDown, true);
}

test "Mouse actions - WheelLeft tick - only press" {
    try run_mouse_action_test_internal(core.MouseAction.WheelLeft, false);
}
test "Mouse actions - WheelLeft tick - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.WheelLeft, true);
}

test "Mouse actions - WheelRight tick - only press" {
    try run_mouse_action_test_internal(core.MouseAction.WheelRight, false);
}
test "Mouse actions - WheelRight tick - both press and release" {
    try run_mouse_action_test_internal(core.MouseAction.WheelRight, true);
}

fn run_mouse_action_test_internal(comptime action: core.MouseAction, comptime include_release: bool) !void {
    const key_tap = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = a, .dead = true } } };
    const mouse_left_click = core.KeyDef{ .tap_only = .{ .mouse_action = action } };

    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{ key_tap, mouse_left_click };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 }); // mouse action press
    current_time = current_time.add_ms(100);
    if (include_release) {
        try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 }); // mouse action release
    }

    try o.process(current_time);

    // expect B to be fired as press
    if (include_release) {
        try std.testing.expectEqual(2, o.actions_queue.Count());
        try std.testing.expectEqual(core.OutputCommand{ .MouseCommandPressed = action }, o.actions_queue.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .MouseCommandReleased = action }, o.actions_queue.dequeue());
    } else {
        try std.testing.expectEqual(1, o.actions_queue.Count());
        try std.testing.expectEqual(core.OutputCommand{ .MouseCommandPressed = action }, o.actions_queue.dequeue());
    }

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "Mouse actions - in combination with key press and modifier" {
    const mouse_left_click = core.KeyDef{
        .tap_only = .{
            .mouse_action = .Button5,
            .key_press = .{
                .tap_keycode = a,
                .tap_modifiers = .{ .left_ctrl = true },
            },
        },
    };

    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{mouse_left_click};
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.press_key(0, current_time);
    current_time = current_time.add_ms(100);
    try o.process(current_time);

    // expect everything to be fired instantly as there is a modifier on the tap
    try std.testing.expectEqual(5, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_ctrl = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .MouseCommandPressed = .Button5 }, o.actions_queue.dequeue());

    current_time = current_time.add_ms(100);
    try o.release_key(0, current_time);
    try o.process(current_time);

    try std.testing.expectEqual(1, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .MouseCommandReleased = .Button5 }, o.actions_queue.dequeue());
}

test "Mouse actions - in combination with key press with dead key" {
    const mouse_left_click = core.KeyDef{
        .tap_only = .{
            .mouse_action = .Button5,
            .key_press = .{ .tap_keycode = a, .dead = true },
        },
    };

    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const base_layer = comptime [_]?core.KeyDef{mouse_left_click};
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.press_key(0, current_time);
    current_time = current_time.add_ms(100);
    try o.process(current_time);

    // Expect everything to be fired instantly as there is a modifier on the tap
    try std.testing.expectEqual(2, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .MouseCommandPressed = .Button5 }, o.actions_queue.dequeue());

    current_time = current_time.add_ms(100);
    try o.release_key(0, current_time);
    try o.process(current_time);

    try std.testing.expectEqual(4, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = KC_SPACE }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = KC_SPACE }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .MouseCommandReleased = .Button5 }, o.actions_queue.dequeue());
}
