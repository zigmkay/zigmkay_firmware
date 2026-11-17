//! Versioned typed compiler output. Callbacks are inspected as pointers, never called.
const model = @import("layout-model");
pub const version = 1;
pub const Data = struct {
    version: u32 = version,
    layers: []const []const ?model.KeyDef,
    combos: []const model.Combo2Def = &.{},
    sides: ?[]const model.Side = null,
    encoders: []const model.EncoderAction = &.{},
    layer_names: ?[]const []const u8 = null,
    has_callbacks: bool = false,
};
