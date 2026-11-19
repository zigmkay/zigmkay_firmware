const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");

const a = 4;
const b = 5;
const A = helpers.TAP(a);
const B = helpers.TAP(b);

const ExpectedResult = enum {
    Tap,
    Hold,
};
fn run_test(
    comptime tap_hold_side: core.Side,
    comptime tap_side: core.Side,
    comptime expected: ExpectedResult,
) !void {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term: core.TimeSpan = .{ .ms = 250 };

    const A_shift = comptime helpers.MT(core.TapDef{ .key_press = .{ .tap_keycode = a } }, .{ .left_shift = true }, tapping_term);

    const base_layer = comptime [_]?core.KeyDef{ A_shift, B };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    const dim = core.KeymapDimensions{ .key_count = base_layer.len, .layer_count = keymap.len };
    const sides: [dim.key_count]core.Side = .{ tap_hold_side, tap_side };
    var o = helpers.init_with_config(dim, .{ .keymap = &keymap, .sides = sides }){};

    try o.press_key(0, current_time);
    current_time = current_time.add_ms(10); // within tapping term
    try o.press_key(1, current_time);
    current_time = current_time.add_ms(10); // within tapping term
    try o.release_key(1, current_time);
    current_time = current_time.add_ms(10); // within tapping term
    try o.release_key(0, current_time);
    try o.process(current_time);

    // expect A pressed as no layer switch is expected
    if (expected == .Hold) {
        try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    } else {
        try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());
    }

    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
    try std.testing.expectEqual(0, o.actions_queue.Count());
}

test "Sides Permissive hold within timeout - different side situations" {
    try run_test(.L, .L, .Tap);
    try run_test(.R, .R, .Tap);

    try run_test(.L, .R, .Hold);
    try run_test(.R, .L, .Hold);
    try run_test(.X, .R, .Hold);
    try run_test(.X, .L, .Hold);
    try run_test(.R, .X, .Hold);
    try run_test(.L, .X, .Hold);
    try run_test(.X, .X, .Hold);
}
