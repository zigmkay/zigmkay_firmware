//! Application-owned evaluator. Never imports a repository build script.
const std = @import("std");
const P = @import("selected-keymap");
const wire = @import("data.zig");
// Retain the callback symbol so Zig type-checks/emits its body against the
// pinned native ABI. The evaluator never calls this function or the handler.
export fn zigmkay_import_callback_address() usize {
    if (@hasDecl(P, "custom_functions")) {
        const callbacks: @import("zigmkay").core.CustomFunctions = P.custom_functions;
        if (callbacks.on_event) |handler| return @intFromPtr(handler);
    }
    return 0;
}
pub fn main(init: std.process.Init) !void {
    const layers = comptime blk: {
        if (!@hasDecl(P, "keymap")) @compileError("Select a module exporting keymap");
        if (P.keymap.len == 0 or P.keymap.len > 15) @compileError("Schema 1 supports 1 to 15 layers");
        const key_count = @typeInfo(@typeInfo(@TypeOf(P.keymap)).array.child).array.len;
        if (key_count == 0 or key_count > 127) @compileError("Schema 1 supports 1 to 127 keys");
        if (@hasDecl(P, "key_count") and P.key_count != key_count) @compileError("Declared key_count differs from keymap data");
        if (@hasDecl(P, "dimensions")) if (P.dimensions.key_count != key_count or P.dimensions.layer_count != P.keymap.len) @compileError("Declared dimensions differ from keymap data");
        var slices: [P.keymap.len][]const ?@import("layout-model").KeyDef = undefined;
        for (&P.keymap, 0..) |*layer, i| slices[i] = layer;
        break :blk slices;
    };
    const callbacks = comptime blk: {
        if (!@hasDecl(P, "custom_functions")) break :blk false;
        var found = false;
        for (@typeInfo(@TypeOf(P.custom_functions)).@"struct".field_names) |name|
            if (@field(P.custom_functions, name) != null) {
                found = true;
            };
        break :blk found;
    };
    const data: wire.Data = .{
        .layers = &layers,
        .combos = if (@hasDecl(P, "combos")) &P.combos else &.{},
        .sides = if (@hasDecl(P, "sides")) &P.sides else null,
        .encoders = if (@hasDecl(P, "encoder_actions")) &P.encoder_actions else &.{},
        .layer_names = if (@hasDecl(P, "layer_names")) &P.layer_names else null,
        .has_callbacks = callbacks,
    };
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try std.zon.stringify.serializeMaxDepth(data, .{}, &output.interface, 64);
    try output.interface.flush();
}
