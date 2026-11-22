const std = @import("std");
const firmware = @import("zigmkay");
const core = firmware.core;
const profile = @import("generated-project");

test "exported 34-key project drives the selected official processor" {
    try std.testing.expectEqual(@as(usize, 34), profile.dimensions.key_count);
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
    try input.enqueue(.{ .pressed = true, .key_index = 0, .time = .from_absolute_us(1000) });
    try processor.Process(.from_absolute_us(1000));
    // The template reserves key 0 for a combo; a lone press waits for timeout.
    try std.testing.expectEqual(@as(usize, 0), output.Count());
    try processor.Process(.from_absolute_us(50000));
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 20 }, output.dequeue());
    try input.enqueue(.{ .pressed = false, .key_index = 0, .time = .from_absolute_us(51000) });
    try processor.Process(.from_absolute_us(51000));
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 20 }, output.dequeue());
    try std.testing.expectEqual(@as(usize, 0), output.Count());
}

/// Generated keymaps return the companion-owned identity type; this local
/// shape lets the contract read it without a companion import.
const LocalProtocol = struct {
    pub const Identity = struct {
        board_id: [8]u8,
        profile_id: [8]u8,
        digest: [16]u8,
        dimensions: core.KeymapDimensions,
    };
};

test "exported project reports its identity digest as the companion keymap id" {
    try std.testing.expectEqual(
        profile.identity(LocalProtocol).digest,
        profile.custom_functions.companion_keymap_id,
    );
    try std.testing.expect(!std.mem.allEqual(u8, &profile.custom_functions.companion_keymap_id, 0));
}

test "overlay candidate sends the companion keycode press and release in order" {
    if (!std.mem.eql(u8, &profile.identity(LocalProtocol).profile_id, "ovrtest\x00")) return;
    // Mainline firmware does not intercept KC_COMPANION; hosts map keycode 0xFE
    // to the overlay intent.
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
    try input.enqueue(.{ .pressed = true, .key_index = 1, .time = .from_absolute_us(1000) });
    try processor.Process(.from_absolute_us(1000));
    try input.enqueue(.{ .pressed = false, .key_index = 1, .time = .from_absolute_us(2000) });
    try processor.Process(.from_absolute_us(2000));
    try std.testing.expectEqual(
        core.OutputCommand{ .KeyCodePress = core.special_keycode_COMPANION },
        output.dequeue().?,
    );
    try std.testing.expectEqual(
        core.OutputCommand{ .KeyCodeRelease = core.special_keycode_COMPANION },
        output.dequeue().?,
    );
    try std.testing.expectEqual(@as(usize, 0), output.Count());
}
