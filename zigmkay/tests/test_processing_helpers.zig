const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const no_combos: [0]core.Combo2Def = [0]core.Combo2Def{};
fn on_event(e: core.ProcessorEvent, layers: *core.LayerActivations, output_queue: *core.OutputCommandQueue) void {
    _ = e;
    _ = layers;
    _ = output_queue;
}

const no_functions: core.CustomFunctions = .{ .on_event = on_event };
pub fn init_with_config(comptime keymap_dimensions: core.KeymapDimensions, comptime config: CreateConfig(keymap_dimensions)) type {
    const ProcessorType = zigmkay.processing.CreateProcessorType(
        &keymap_dimensions,
        config.keymap,
        &config.sides,
        config.combos,
        config.custom_functions,
        config.encoder_actions,
        config.matrix_event_trace,
    );
    return struct {
        const Self = @This();
        matrix_change_queue: zigmkay.core.MatrixStateChangeQueue = zigmkay.core.MatrixStateChangeQueue.Create(),
        encoder_event_queue: zigmkay.core.EncoderEventQueue = zigmkay.core.EncoderEventQueue.Create(),
        actions_queue: zigmkay.core.OutputCommandQueue = zigmkay.core.OutputCommandQueue.Create(),
        _inner_processor: ?ProcessorType = null,
        pub fn press_key(self: *Self, key_index: zigmkay.core.KeyIndex, time: core.TimeSinceBoot) !void {
            ensure_processor(self);
            try self.matrix_change_queue.enqueue(.{ .time = time, .pressed = true, .key_index = key_index });
        }
        pub fn release_key(self: *Self, key_index: zigmkay.core.KeyIndex, time: core.TimeSinceBoot) !void {
            ensure_processor(self);
            try self.matrix_change_queue.enqueue(.{ .time = time, .pressed = false, .key_index = key_index });
        }
        pub fn process(self: *Self, time: core.TimeSinceBoot) !void {
            ensure_processor(self);
            try self._inner_processor.?.Process(time);
        }
        fn ensure_processor(self: *Self) void {
            if (self._inner_processor == null)
                self._inner_processor = ProcessorType{
                    .input_matrix_changes = &self.matrix_change_queue,
                    .output_usb_commands = &self.actions_queue,
                    .encoder_event_changes = &self.encoder_event_queue,
                };
        }
    };
}

pub fn CreateConfig(keymap_dimensions: core.KeymapDimensions) type {
    return struct {
        keymap: *const [keymap_dimensions.layer_count][keymap_dimensions.key_count]?core.KeyDef,
        combos: []const core.Combo2Def = &.{},
        custom_functions: *const core.CustomFunctions = &no_functions,
        sides: [keymap_dimensions.key_count]core.Side = @splat(.X),
        encoder_actions: []const core.EncoderAction = &.{},
        matrix_event_trace: ?core.MatrixEventTrace = null,
    };
}

pub fn ONE_SHOT_LAYER(layer: u8) core.TapDef {
    return core.TapDef{ .one_shot = .{ .layer = layer } };
}
pub fn ONE_SHOT_MOD(mod: core.Modifiers) core.KeyDef {
    return core.KeyDef{ .tap_only = .{ .one_shot = .{ .hold_modifiers = mod } } };
}
pub fn TAP(keycode: u8) core.KeyDef {
    return core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = keycode } } };
}
pub fn TAP_WITH_MOD(keycode: u8, modifiers: core.Modifiers) core.KeyDef {
    return core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = keycode, .tap_modifiers = modifiers } } };
}
pub fn HOLD_MOD(modifiers: core.Modifiers) core.KeyDef {
    return core.KeyDef{ .hold_only = .{ .hold_modifiers = modifiers } };
}
pub fn MO(layer: core.LayerIndex) core.KeyDef {
    return core.KeyDef{ .hold_only = .{ .hold_layer = layer } };
}
pub fn LT(layer: core.LayerIndex, tap_keycode: u8, tap_modifiers: core.Modifiers, tapping_term: core.TimeSpan) core.KeyDef {
    return core.KeyDef{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = tap_keycode, .tap_modifiers = tap_modifiers } },
        .hold = .{ .hold_layer = layer },
        .tapping_term = tapping_term,
        .retro_tapping = false,
    } };
}
pub fn MT(tap: core.TapDef, hold_mods: core.Modifiers, tapping_term: core.TimeSpan) core.KeyDef {
    return core.KeyDef{ .tap_hold = .{
        .tap = tap,
        .hold = core.HoldDef{ .hold_modifiers = hold_mods },
        .tapping_term = tapping_term,
        .retro_tapping = false,
    } };
}
pub fn NONE() core.KeyDef {
    return core.KeyDef.none;
}
