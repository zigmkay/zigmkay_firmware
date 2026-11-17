const std = @import("std");
const firmware = @import("zigmkay");
const core = firmware.core;
const original = @import("original-profile");
const profile = @import("generated-profile");
const Reference = firmware.processing.CreateProcessorType(&original.dimensions, &original.keymap, &original.sides, &original.combos, &original.custom_functions, &profile.encoder_actions, null);
const Candidate = firmware.processing.CreateProcessorType(&profile.dimensions, &profile.keymap, &profile.sides, &profile.combos, &profile.custom_functions, &profile.encoder_actions, null);

const Trace = struct {
    inputs: [2]core.MatrixStateChangeQueue = .{ .Create(), .Create() },
    encoders: [2]core.EncoderEventQueue = .{ .Create(), .Create() },
    outputs: [2]core.OutputCommandQueue = .{ .Create(), .Create() },
    reference: Reference = undefined,
    candidate: Candidate = undefined,
    now: u64 = 0,
    output_count: usize = 0,
    fn init(self: *Trace) void {
        self.reference = .{ .input_matrix_changes = &self.inputs[0], .encoder_event_changes = &self.encoders[0], .output_usb_commands = &self.outputs[0] };
        self.candidate = .{ .input_matrix_changes = &self.inputs[1], .encoder_event_changes = &self.encoders[1], .output_usb_commands = &self.outputs[1] };
    }
    fn tick(self: *Trace, delta: u64) !void {
        self.now += delta;
        const time: core.TimeSinceBoot = .from_absolute_us(self.now);
        try self.reference.Process(time);
        try self.candidate.Process(time);
        while (self.outputs[0].dequeue()) |expected| {
            try std.testing.expectEqualDeep(expected, self.outputs[1].dequeue() orelse return error.MissingOutput);
            self.output_count += 1;
        }
        try std.testing.expect(self.outputs[1].dequeue() == null);
        try std.testing.expectEqualDeep(self.reference.layers_activations, self.candidate.layers_activations);
        try std.testing.expectEqualDeep(self.outputs[0].current_mods, self.outputs[1].current_mods);
    }
    fn key(self: *Trace, index: usize, down: bool) !void {
        const event: core.MatrixStateChange = .{ .key_index = @intCast(index), .pressed = down, .time = .from_absolute_us(self.now + 1000) };
        for (&self.inputs) |*input| try input.enqueue(event);
        try self.tick(1000);
    }
    fn layer(self: *Trace, index: usize) void {
        for (1..profile.dimensions.layer_count) |i| {
            self.reference.layers_activations.set_layer_state(@intCast(i), index == i);
            self.candidate.layers_activations.set_layer_state(@intCast(i), index == i);
        }
    }
};
test "friend import retains typed actions and real processor behavior including callback combinations" {
    try std.testing.expectEqualDeep(original.keymap, profile.keymap);
    try std.testing.expectEqualDeep(original.combos, profile.combos);
    try std.testing.expectEqualDeep(original.sides, profile.sides);
    var trace: Trace = .{};
    trace.init();
    for (0..profile.dimensions.layer_count) |layer| for (0..profile.key_count) |key| {
        trace.layer(layer);
        try trace.key(key, true);
        try trace.key(key, false);
        try trace.tick(500_000);
        trace.layer(layer);
        try trace.key(key, true);
        try trace.tick(500_000);
        try trace.key(key, false);
        try trace.tick(500_000);
    };
    for (original.combos) |combo| {
        trace.layer(combo.layer);
        try trace.key(combo.key_indexes[0], true);
        try trace.key(combo.key_indexes[1], true);
        try trace.tick(500_000);
        try trace.key(combo.key_indexes[1], false);
        try trace.key(combo.key_indexes[0], false);
        try trace.tick(500_000);
    }
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
    try std.testing.expect(trace.output_count > 0);
}
