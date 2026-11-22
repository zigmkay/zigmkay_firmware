const model = @import("layout-model");
const p = @import("root.zig");

fn layerId(layers: []const p.Layer, index: model.LayerIndex) !p.LayerId {
    if (index >= layers.len) return error.InvalidLayer;
    return layers[index].id;
}

pub fn liftHold(layers: []const p.Layer, hold: model.HoldDef) !p.Hold {
    return .{
        .hold_modifiers = hold.hold_modifiers,
        .layer_id = if (hold.hold_layer) |index| try layerId(layers, index) else null,
        .custom = hold.custom,
    };
}

pub fn liftTap(layers: []const p.Layer, tap: model.TapDef) !p.Tap {
    return .{
        .key_press = tap.key_press,
        .one_shot = if (tap.one_shot) |hold| try liftHold(layers, hold) else null,
        .custom = tap.custom,
        .media_key = tap.media_key,
        .mouse_action = tap.mouse_action,
    };
}

/// Typed adapter building block; never parses/evaluates arbitrary Zig source.
pub fn liftAction(layers: []const p.Layer, action: model.KeyDef) !p.Action {
    return switch (action) {
        .none => .none,
        .tap_only => |tap| .{ .tap_only = try liftTap(layers, tap) },
        .hold_only => |hold| .{ .hold_only = try liftHold(layers, hold) },
        .tap_hold => |th| .{ .tap_hold = .{
            .tap = try liftTap(layers, th.tap),
            .hold = try liftHold(layers, th.hold),
            .tapping_term = th.tapping_term,
            .retro_tapping = th.retro_tapping,
        } },
        .tap_with_autofire => |fire| .{ .tap_with_autofire = .{
            .tap = try liftTap(layers, fire.tap),
            .initial_delay = fire.initial_delay,
            .repeat_interval = fire.repeat_interval,
        } },
    };
}

// Model extensions require a deliberate adapter/schema review rather than default-field loss.
comptime {
    if (@typeInfo(model.TapDef).@"struct".field_names.len != 5 or
        @typeInfo(model.HoldDef).@"struct".field_names.len != 3 or
        @typeInfo(model.TapHoldDef).@"struct".field_names.len != 4 or
        @typeInfo(model.AutoFireDef).@"struct".field_names.len != 3 or
        @typeInfo(model.KeyDef).@"union".field_names.len != 5 or
        @typeInfo(model.KeyCodeFire).@"struct".field_names.len != 3 or
        @typeInfo(model.Modifiers).@"struct".field_names.len != 8)
        @compileError("Review project schema and lossless adapters for the changed action model");
}
