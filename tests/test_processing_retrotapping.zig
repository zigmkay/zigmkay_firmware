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
const Expectation = enum {
    Hold,
    Tap,
    Hold_and_retro_tap,
};
const RetroTestParameters = struct {
    retro_enabled: bool,
    tapping_term_ms: u16,
    release_delta_time_ms: u64,
    expectation: Expectation,
    press_other_before_release: bool,
};
fn run_retrotest_test(comptime config: RetroTestParameters) !void {
    // retro disabled
    // key pressed
    // same key released within tapping term
    // expect tap (as this is the normal tap condition)
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const key_with_retro_tapping = core.KeyDef{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = c } },
        .hold = .{ .hold_modifiers = .{ .left_shift = true } },
        .tapping_term = core.TimeSpan{ .ms = config.tapping_term_ms },
        .retro_tapping = config.retro_enabled,
    } };

    const base_layer = comptime [_]?core.KeyDef{ key_with_retro_tapping, B, A };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    // Ensure nothing happens at first press when the key has multiple functions (both tap and hold)
    try o.press_key(0, current_time);

    if (config.press_other_before_release) {
        try o.press_key(1, current_time);
    }

    // Now ensure that a tap will happen when releasing within tapping term
    current_time = current_time.add_ms(config.release_delta_time_ms); // within tapping term
    try o.release_key(0, current_time);
    try o.process(current_time);

    // expect A pressed as no layer switch is expected
    switch (config.expectation) {
        .Tap => {
            try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
            if (config.press_other_before_release) {
                try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
            }
            try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
        },
        .Hold => {
            try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
            // if hold is expected, any expected tap is a retro tap and must
            if (config.press_other_before_release) {
                try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
            }
            try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
        },
        .Hold_and_retro_tap => {
            try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
            try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
            try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
            try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
            if (config.press_other_before_release) {
                unreachable; // it makes no sense to expect retro tapping and also instructing other keys to be pressed
            }
        },
    }
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
test "MT retrotapping - press/release case A" {
    // retro disabled, released within tt, expect tap only
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 0, .press_other_before_release = false, .expectation = Expectation.Tap });
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 1, .press_other_before_release = false, .expectation = Expectation.Tap });
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 249, .press_other_before_release = false, .expectation = Expectation.Tap });
}
test "MT retrotapping - press/release case B" {
    // retro true, released within tt, expect tap only
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 0, .press_other_before_release = false, .expectation = Expectation.Tap });
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 1, .press_other_before_release = false, .expectation = Expectation.Tap });
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 249, .press_other_before_release = false, .expectation = Expectation.Tap });
}
test "MT retrotapping - press/release case C" {
    // retro disabled, released after tt, expect hold only
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 251, .press_other_before_release = false, .expectation = Expectation.Hold });
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 350, .press_other_before_release = false, .expectation = Expectation.Hold });
}
test "MT retrotapping - press/release case D" {
    // retro enabled, released after tt, expect hold only
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 251, .press_other_before_release = false, .expectation = Expectation.Hold_and_retro_tap });
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 350, .press_other_before_release = false, .expectation = Expectation.Hold_and_retro_tap });
}
test "MT retrotapping - press/other/release case A" {
    // retro disabled, released within tt, expect tap only
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 0, .press_other_before_release = true, .expectation = Expectation.Tap });
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 1, .press_other_before_release = true, .expectation = Expectation.Tap });
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 249, .press_other_before_release = true, .expectation = Expectation.Tap });
}
test "MT retrotapping - press/other/release case B" {
    // retro true, released within tt, expect tap only
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 0, .press_other_before_release = true, .expectation = Expectation.Tap });
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 1, .press_other_before_release = true, .expectation = Expectation.Tap });
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 249, .press_other_before_release = true, .expectation = Expectation.Tap });
}
test "MT retrotapping - press/other/release case C" {
    // retro disabled, released after tt, expect hold only
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 251, .press_other_before_release = true, .expectation = Expectation.Hold });
    try run_retrotest_test(.{ .retro_enabled = false, .tapping_term_ms = 250, .release_delta_time_ms = 350, .press_other_before_release = true, .expectation = Expectation.Hold });
}
test "MT retrotapping - press/other/release case D" {
    // retro enabled, released after tt, expect hold only
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 251, .press_other_before_release = true, .expectation = Expectation.Hold });
    try run_retrotest_test(.{ .retro_enabled = true, .tapping_term_ms = 250, .release_delta_time_ms = 350, .press_other_before_release = true, .expectation = Expectation.Hold });
}

