const std = @import("std");
const firmware = @import("zigmkay");
const core = firmware.core;
const model = @import("layout-model");

comptime {
    if (model.KeyDef != core.KeyDef or model.Modifiers != core.Modifiers)
        @compileError("Compatibility types must alias the selected firmware types");
}

fn onEvent(_: core.ProcessorEvent, _: *core.LayerActivations, _: *core.OutputCommandQueue) void {}

// A downstream keymap uses firmware-owned action types and the real processor.
test "downstream tap emits press and release through the official processor" {
    const dimensions: core.KeymapDimensions = .{ .key_count = 1, .layer_count = 1 };
    const keymap: [1][1]?core.KeyDef = .{.{.{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } }}};
    const sides: [1]core.Side = .{.X};
    const callbacks: core.CustomFunctions = .{ .on_event = onEvent };
    const Processor = firmware.processing.CreateProcessorType(
        &dimensions,
        &keymap,
        &sides,
        &.{},
        &callbacks,
        &.{},
        null,
    );
    var input = core.MatrixStateChangeQueue.Create();
    var encoders = core.EncoderEventQueue.Create();
    var output = core.OutputCommandQueue.Create();
    var processor: Processor = .{
        .input_matrix_changes = &input,
        .encoder_event_changes = &encoders,
        .output_usb_commands = &output,
    };
    const time = core.TimeSinceBoot.from_absolute_us(1000);
    try input.enqueue(.{ .time = time, .pressed = true, .key_index = 0 });
    try processor.Process(time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 4 }, output.dequeue());
    try std.testing.expectEqual(@as(usize, 0), output.Count());
    try input.enqueue(.{ .time = time, .pressed = false, .key_index = 0 });
    try processor.Process(time);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 4 }, output.dequeue());
    try std.testing.expectEqual(@as(usize, 0), output.Count());
}
