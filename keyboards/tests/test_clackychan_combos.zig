const std = @import("std");
const zigmkay = @import("zigmkay");
const keymap = @import("clackychan_keymap");

const core = zigmkay.core;
const Processor = zigmkay.processing.CreateProcessorType(
    &keymap.dimensions,
    &keymap.keymap,
    &keymap.sides,
    &keymap.combos,
    &keymap.custom_functions,
    &.{},
    null,
);

test "overlapping punctuation combos allow a deliberate roll" {
    const cases = [_]struct {
        layer: core.LayerIndex,
        first_key: core.KeyIndex,
        second_key: core.KeyIndex,
        output_keycode: u8,
    }{
        .{ .layer = 0, .first_key = 25, .second_key = 26, .output_keycode = 0x33 },
        .{ .layer = 0, .first_key = 26, .second_key = 25, .output_keycode = 0x33 },
        .{ .layer = 1, .first_key = 25, .second_key = 26, .output_keycode = 0x33 },
        .{ .layer = 1, .first_key = 26, .second_key = 25, .output_keycode = 0x33 },
        .{ .layer = 0, .first_key = 26, .second_key = 27, .output_keycode = 0x34 },
        .{ .layer = 0, .first_key = 27, .second_key = 26, .output_keycode = 0x34 },
        .{ .layer = 1, .first_key = 26, .second_key = 27, .output_keycode = 0x34 },
        .{ .layer = 1, .first_key = 27, .second_key = 26, .output_keycode = 0x34 },
    };

    for (cases) |case| {
        var matrix_changes = core.MatrixStateChangeQueue.Create();
        var encoder_events = core.EncoderEventQueue.Create();
        var output_commands = core.OutputCommandQueue.Create();
        var processor = Processor{
            .input_matrix_changes = &matrix_changes,
            .encoder_event_changes = &encoder_events,
            .output_usb_commands = &output_commands,
        };

        var now = core.TimeSinceBoot.from_absolute_us(100_000);
        if (case.layer == 1) {
            try matrix_changes.enqueue(.{ .time = now, .pressed = true, .key_index = 29 });
            try processor.Process(now);
            now = now.add_ms(201);
            try processor.Process(now);
        }

        try matrix_changes.enqueue(.{ .time = now, .pressed = true, .key_index = case.first_key });
        try processor.Process(now);
        try std.testing.expectEqual(0, output_commands.Count());

        now = now.add_ms(1);
        try matrix_changes.enqueue(.{ .time = now, .pressed = true, .key_index = case.second_key });
        try processor.Process(now);

        try std.testing.expectEqual(
            core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } },
            output_commands.dequeue(),
        );
        try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = case.output_keycode }, output_commands.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = case.output_keycode }, output_commands.dequeue());
        try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, output_commands.dequeue());
        try std.testing.expectEqual(0, output_commands.Count());
    }
}
