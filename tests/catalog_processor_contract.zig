const std = @import("std");
const firmware = @import("zigmkay");
const core = firmware.core;
const profile = @import("generated-profile");

test "synthetic catalog export preserves every indexed press and release" {
    const Processor = firmware.processing.CreateProcessorType(
        &profile.dimensions,
        &profile.keymap,
        &profile.sides,
        &profile.combos,
        &profile.custom_functions,
        &profile.encoder_actions,
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
    for (0..profile.key_count) |index| {
        const now = @as(u64, @intCast(index * 1000));
        try input.enqueue(.{ .pressed = true, .key_index = @intCast(index), .time = .from_absolute_us(now) });
        try processor.Process(.from_absolute_us(now));
        try std.testing.expectEqual(
            core.OutputCommand{ .KeyCodePress = @intCast(4 + index % 26) },
            output.dequeue().?,
        );
        try input.enqueue(.{
            .pressed = false,
            .key_index = @intCast(index),
            .time = .from_absolute_us(now + 1),
        });
        try processor.Process(.from_absolute_us(now + 1));
        try std.testing.expectEqual(
            core.OutputCommand{ .KeyCodeRelease = @intCast(4 + index % 26) },
            output.dequeue().?,
        );
        try std.testing.expect(output.dequeue() == null);
    }
    const protocol = @import("device-protocol");
    const identity = profile.identity(protocol);
    const actual = try protocol.computeIdentity(.{
        .board_id = identity.board_id,
        .profile_id = identity.profile_id,
        .dimensions = profile.dimensions,
        .keys = @as(
            *const [profile.dimensions.key_count * profile.dimensions.layer_count]?core.KeyDef,
            @ptrCast(&profile.keymap),
        ),
        .sides = &profile.sides,
        .combos = &profile.combos,
        .encoders = &profile.encoder_actions,
        .callbacks = &.{},
    });
    try std.testing.expectEqual(identity.digest, actual.digest);
    try std.testing.expectEqual(protocol.keymapId(actual), profile.custom_functions.companion_keymap_id);
}
