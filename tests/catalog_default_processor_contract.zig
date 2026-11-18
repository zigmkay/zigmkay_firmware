//! Differential offline traces through the firmware's actual processor. The
//! reference imports the authoritative default; the candidate imports exported
//! schema-1 actions and the independently captured original callback source.
const std = @import("std");
const firmware = @import("zigmkay");
const core = firmware.core;
const defaults = @import("firmware-defaults");
const index = @import("catalog-options").index;
const original = defaults.profiles[index];
const profile = @import("generated-profile");
const descriptor = defaults.processing_descriptors.find(defaults.boards.entries[index].name).?;
const original_custom = if (@hasDecl(original, "custom_functions")) original.custom_functions else core.CustomFunctions{};
const original_combos = if (@hasDecl(original, "combos")) original.combos else [_]core.Combo2Def{};
const original_encoders: [descriptor.encoder_actions]core.EncoderAction = if (@hasDecl(original, "encoder_actions")) original.encoder_actions else @splat(.{ .tap = .{} });

const Reference = firmware.processing.CreateProcessorType(
    &profile.dimensions,
    &original.keymap,
    descriptor.sides[0..descriptor.key_count],
    &original_combos,
    &original_custom,
    &original_encoders,
    null,
);

const Candidate = firmware.processing.CreateProcessorType(
    &profile.dimensions,
    &profile.keymap,
    &profile.sides,
    &profile.combos,
    &profile.custom_functions,
    &profile.encoder_actions,
    null,
);

const Trace = struct {
    reference_input: core.MatrixStateChangeQueue = .Create(),
    candidate_input: core.MatrixStateChangeQueue = .Create(),
    reference_encoders: core.EncoderEventQueue = .Create(),
    candidate_encoders: core.EncoderEventQueue = .Create(),
    reference_output: core.OutputCommandQueue = .Create(),
    candidate_output: core.OutputCommandQueue = .Create(),
    reference: Reference = undefined,
    candidate: Candidate = undefined,
    now: u64 = 0,
    outputs: usize = 0,

    fn init(self: *Trace) void {
        self.reference = .{
            .input_matrix_changes = &self.reference_input,
            .encoder_event_changes = &self.reference_encoders,
            .output_usb_commands = &self.reference_output,
        };
        self.candidate = .{
            .input_matrix_changes = &self.candidate_input,
            .encoder_event_changes = &self.candidate_encoders,
            .output_usb_commands = &self.candidate_output,
        };
    }

    fn tick(self: *Trace, delta: u64) !void {
        self.now += delta;
        const time: core.TimeSinceBoot = .from_absolute_us(self.now);
        try self.reference.Process(time);
        try self.candidate.Process(time);
        while (self.reference_output.dequeue()) |expected| {
            const actual = self.candidate_output.dequeue() orelse return error.MissingOutput;
            try std.testing.expectEqualDeep(expected, actual);
            self.outputs += 1;
        }
        try std.testing.expect(self.candidate_output.dequeue() == null);
        try std.testing.expectEqualDeep(self.reference.layers_activations, self.candidate.layers_activations);
        try std.testing.expectEqualDeep(
            self.reference_output.current_mods,
            self.candidate_output.current_mods,
        );
    }

    fn key(self: *Trace, key_index: usize, pressed: bool) !void {
        const event: core.MatrixStateChange = .{
            .key_index = @intCast(key_index),
            .pressed = pressed,
            .time = .from_absolute_us(self.now + 1000),
        };
        try self.reference_input.enqueue(event);
        try self.candidate_input.enqueue(event);
        try self.tick(1000);
    }

    fn layer(self: *Trace, selected: usize) void {
        for (1..profile.dimensions.layer_count) |li| {
            self.reference.layers_activations.set_layer_state(@intCast(li), li == selected);
            self.candidate.layers_activations.set_layer_state(@intCast(li), li == selected);
        }
    }
};

test "actual default exports preserve all typed fields and processor tap hold combo encoder traces" {
    try std.testing.expectEqualDeep(original.keymap, profile.keymap);
    try std.testing.expectEqualDeep(original_combos, profile.combos);
    try std.testing.expectEqualDeep(original_encoders, profile.encoder_actions);
    try std.testing.expectEqualSlices(core.Side, descriptor.sides, &profile.sides);
    var trace: Trace = .{};
    trace.init();
    for (0..profile.dimensions.layer_count) |li| {
        for (0..profile.key_count) |ki| {
            // Quick taps and resolved holds cover custom IDs, dead keys, media,
            // one-shots and layer changes without interpreting callback code.
            trace.layer(li);
            try trace.key(ki, true);
            try trace.key(ki, false);
            try trace.tick(500_000);
            trace.layer(li);
            try trace.key(ki, true);
            try trace.tick(500_000);
            try trace.key(ki, false);
            try trace.tick(500_000);
        }
    }
    for (original_combos) |combo| {
        trace.layer(combo.layer);
        try trace.key(combo.key_indexes[0], true);
        try trace.key(combo.key_indexes[1], true);
        try trace.tick(500_000);
        try trace.key(combo.key_indexes[1], false);
        try trace.key(combo.key_indexes[0], false);
        try trace.tick(500_000);
    }
    // Resolve pairs of base-layer holds in both release orders. In particular
    // this exercises Rollercole/Janbeelte's two-thumb derived-layer callbacks.
    for (original.keymap[0], 0..) |left, li| {
        if (left == null or (left.? != .tap_hold and left.? != .hold_only)) continue;
        for (original.keymap[0][li + 1 ..], li + 1..) |right, ri| {
            if (right == null or (right.? != .tap_hold and right.? != .hold_only)) continue;
            for ([_]bool{ false, true }) |reverse| {
                trace.layer(0);
                try trace.key(li, true);
                try trace.tick(500_000);
                try trace.key(ri, true);
                try trace.tick(500_000);
                try trace.key(if (reverse) li else ri, false);
                try trace.key(if (reverse) ri else li, false);
                try trace.tick(500_000);
            }
        }
    }
    for (0..descriptor.encoder_actions) |slot| {
        try trace.reference_encoders.enqueue(.{ .encoder_action_index = @intCast(slot) });
        try trace.candidate_encoders.enqueue(.{ .encoder_action_index = @intCast(slot) });
        try trace.tick(1000);
    }
    try std.testing.expect(trace.outputs > 0);
}
