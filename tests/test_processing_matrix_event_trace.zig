const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const helpers = @import("test_processing_helpers.zig");

test "matrix event trace emits companion key log messages and honors its filter" {
    const keymap = comptime [_][2]?core.KeyDef{.{ helpers.TAP(0x04), helpers.TAP(0x05) }};
    var processor = helpers.init_with_config(
        .{ .key_count = 2, .layer_count = 1 },
        .{
            .keymap = &keymap,
            .matrix_event_trace = .{ .key_range = .{ .first = 1, .last = 1 } },
        },
    ){};
    const now = core.TimeSinceBoot.from_absolute_us(1_000);

    try processor.press_key(0, now);
    try processor.process(now);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 0x04 }, processor.actions_queue.dequeue());
    try std.testing.expectEqual(0, processor.actions_queue.Count());

    try processor.press_key(1, now);
    try processor.process(now);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 0x05 }, processor.actions_queue.dequeue());

    const message = core.LogMessage.init(true, 1, 0, .{});
    var data: [8]u8 = @splat(0);
    data[0..4].* = message.toBytes();
    try std.testing.expectEqual(
        core.OutputCommand{ .RawHidSignal = .{
            .signal_id = core.RAWHID_SIGNAL_KEY_EVENT,
            .data = data,
            .len = 4,
        } },
        processor.actions_queue.dequeue(),
    );
    try std.testing.expectEqual(0, processor.actions_queue.Count());
}
