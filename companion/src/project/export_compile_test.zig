const std = @import("std");
const profile = @import("generated-profile");
const firmware = @import("zigmkay");
const core = firmware.core;
const protocol = @import("device-protocol");

test "generated Zig compiles and specializes the real firmware processor" {
    try std.testing.expectEqual(@as(u8, 4), profile.keymap[0][0].?.tap_only.key_press.?.tap_keycode);
    try std.testing.expectEqual(@as(?u4, 1), profile.keymap[0][1].?.hold_only.hold_layer);
    try std.testing.expect(profile.keymap[1][1] == null);
    const Processor = firmware.processing.CreateProcessorType(
        &profile.dimensions,
        &profile.keymap,
        &profile.sides,
        &profile.combos,
        &profile.custom_functions,
        &profile.encoder_actions,
        null,
    );
    var matrix = core.MatrixStateChangeQueue.Create();
    var encoders = core.EncoderEventQueue.Create();
    var output = core.OutputCommandQueue.Create();
    var processor = Processor{
        .input_matrix_changes = &matrix,
        .encoder_event_changes = &encoders,
        .output_usb_commands = &output,
    };
    try matrix.enqueue(.{ .time = .from_absolute_us(0), .key_index = 0, .pressed = true });
    try processor.Process(.from_absolute_us(0));
    try matrix.enqueue(.{ .time = .from_absolute_us(100_000), .key_index = 0, .pressed = false });
    try processor.Process(.from_absolute_us(100_000));
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 4 }, output.dequeue().?);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 4 }, output.dequeue().?);
    try std.testing.expect(output.dequeue() == null);
    try matrix.enqueue(.{ .time = .from_absolute_us(200_000), .key_index = 1, .pressed = true });
    try processor.Process(.from_absolute_us(200_000));
    try matrix.enqueue(.{ .time = .from_absolute_us(210_000), .key_index = 0, .pressed = true });
    try processor.Process(.from_absolute_us(210_000));
    try matrix.enqueue(.{ .time = .from_absolute_us(220_000), .key_index = 0, .pressed = false });
    try processor.Process(.from_absolute_us(220_000));
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 80 }, output.dequeue().?);
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 80 }, output.dequeue().?);
    try std.testing.expect(output.dequeue() == null);
    const keys = [_]?core.KeyDef{
        profile.keymap[0][0],
        profile.keymap[0][1],
        profile.keymap[1][0],
        profile.keymap[1][1],
    };
    const actual = try protocol.computeIdentity(.{
        .board_id = profile.identity(protocol).board_id,
        .profile_id = profile.identity(protocol).profile_id,
        .dimensions = profile.dimensions,
        .keys = &keys,
        .sides = &profile.sides,
        .combos = &profile.combos,
        .encoders = &profile.encoder_actions,
        .callbacks = &.{},
    });
    try std.testing.expectEqual(profile.identity(protocol).digest, actual.digest);
    try std.testing.expectEqual(protocol.keymapId(actual), profile.custom_functions.companion_keymap_id);
}
