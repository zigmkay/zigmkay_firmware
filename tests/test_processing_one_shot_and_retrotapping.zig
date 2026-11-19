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
const TestObjects = struct {
    matrix_change_queue: core.MatrixStateChangeQueue,
    actions_queue: core.OutputCommandQueue,
    processor: zigmkay.processing.Processor,
};

test "one-shot + retro tapping" {
    // multiple mod hold presses at the same time

    const hold_mod = core.Modifiers{ .left_ctrl = true };
    const one_shot_mod = core.Modifiers{ .left_shift = true };

    var current_time: core.TimeSinceBoot = .from_absolute_us(100);
    const one_shot_shift = core.KeyDef{
        .tap_hold = .{
            .tap = .{
                .one_shot = .{
                    .hold_modifiers = one_shot_mod,
                },
            },
            .hold = .{ .hold_modifiers = hold_mod },
            .retro_tapping = true,
            .tapping_term = .{ .ms = 250 },
        },
    };

    const base_layer = comptime [_]?core.KeyDef{ A, one_shot_shift, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    // tap A
    try o.press_key(0, current_time);
    try o.release_key(0, current_time);

    // hold one shot
    try o.press_key(1, current_time);

    current_time = current_time.add_ms(1000);

    // release and expect one shot to be fired
    try o.release_key(1, current_time);

    // tap c - expect surrounded by the one shot modifier (shift)
    try o.press_key(2, current_time);
    try o.release_key(2, current_time);

    // tap d - expect one shot mod cancelled before tapping happens
    try o.press_key(3, current_time);
    try o.release_key(3, current_time);

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = hold_mod }, o.actions_queue.dequeue()); // activating mod
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue()); // releasing mod

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = one_shot_mod }, o.actions_queue.dequeue()); // activating mod
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue()); // releasing mod

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = d }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = d }, o.actions_queue.dequeue());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}
