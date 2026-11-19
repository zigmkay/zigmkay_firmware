const types = @import("zigmkay").core;
pub const special_keycode_BOOT = types.special_keycode_BOOT;
pub const special_keycode_PRINT_STATS = types.special_keycode_PRINT_STATS;
pub const special_keycode_COMPANION = types.special_keycode_COMPANION;
pub const special_keycode_SHUTDOWN_COMPANION = types.special_keycode_SHUTDOWN_COMPANION;
pub const CUSTOM_ID_COMPANION_LOG_TOGGLE = types.CUSTOM_ID_COMPANION_LOG_TOGGLE;
pub const CUSTOM_ID_COMPANION_SHUTDOWN = types.CUSTOM_ID_COMPANION_SHUTDOWN;
pub const CUSTOM_ID_COMPANION_TOGGLE = types.CUSTOM_ID_COMPANION_TOGGLE;
pub const KC_BOOT = types.KC_BOOT;
pub const KC_PRINT_STATS = types.KC_PRINT_STATS;
pub const KC_COMPANION = types.KC_COMPANION;
pub const KC_SHUTDOWN_COMPANION = types.KC_SHUTDOWN_COMPANION;
pub const Modifiers = types.Modifiers;
pub const KeymapDimensions = types.KeymapDimensions;
pub const MouseAction = types.MouseAction;
pub const TapDef = types.TapDef;
pub const MediaCode = types.MediaCode;
pub const HoldDef = types.HoldDef;
pub const TapHoldDef = types.TapHoldDef;
pub const KeyDef = types.KeyDef;
pub const Side = types.Side;
pub const Combo2Def = types.Combo2Def;
pub const AutoFireDef = types.AutoFireDef;
pub const TimeSpan = types.TimeSpan;
pub const KeyIndex = types.KeyIndex;
pub const LayerIndex = types.LayerIndex;
pub const EncoderAction = types.EncoderAction;
pub const OutputCommand = types.OutputCommand;
pub const KeyCodeFire = types.KeyCodeFire;
pub const MEDIA_VOLUME_UP = types.MEDIA_VOLUME_UP;
pub const MEDIA_VOLUME_DOWN = types.MEDIA_VOLUME_DOWN;
pub const MEDIA_MUTE = types.MEDIA_MUTE;
pub const MEDIA_PLAY_PAUSE = types.MEDIA_PLAY_PAUSE;
pub const MEDIA_NEXT_TRACK = types.MEDIA_NEXT_TRACK;
pub const MEDIA_PREV_TRACK = types.MEDIA_PREV_TRACK;

pub const physical_layout = @import("physical_layout.zig");

test "portable declarations are available" {
    @import("std").testing.refAllDecls(@This());
}
