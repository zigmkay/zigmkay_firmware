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
test "TAP - single key press" {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);

    const media_key_code: core.MediaCode = .VolumeUp;
    const media_key = core.KeyDef{ .tap_only = .{ .media_key = media_key_code } };
    const base_layer = comptime [_]?core.KeyDef{ A, B, media_key, D };

    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    try o.press_key(2, current_time);
    current_time = current_time.add_ms(20);

    try o.process(current_time);

    try std.testing.expectEqual(1, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .ConsumerKeyPressed = media_key_code }, o.actions_queue.dequeue());

    try o.release_key(2, current_time);
    current_time = current_time.add_ms(20);

    try o.process(current_time);

    try std.testing.expectEqual(1, o.actions_queue.Count());
    try std.testing.expectEqual(core.OutputCommand{ .ConsumerKeyReleased = media_key_code }, o.actions_queue.dequeue());
}
