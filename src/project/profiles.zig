//! Curated typed imports only; this module never parses arbitrary Zig profiles.
//! The selected official profile and embedded source must come from the same
//! immutable firmware revision. These templates do not upgrade saved projects.
const std = @import("std");
const p = @import("root.zig");
const original = @import("rollercole-profile");
const physical = @import("lk7-physical");
pub const registered_source = @embedFile("rollercole-source");
pub const registered_binding = "official_lk7_e310ab36";
pub const registered_entry = "rollercole.zig";
pub const Profile = enum { danish, qwerty, eurkey, eurmac };
pub const names = [_][]const u8{ "Danish Rollercole", "QWERTY", "EurKEY draft", "EurKEY Next Mac candidate" };

pub const key_ids: [34][]const u8 = blk: {
    var ids: [34][]const u8 = undefined;
    for (physical.keys, 0..) |key, index| ids[index] = std.fmt.comptimePrint("lk7_{x:0>4}", .{key.id});
    break :blk ids;
};

pub const board = p.Board{
    .id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 },
    .physical_layout = "lk7_schematic_v1",
    .key_ids = &key_ids,
    .sides = &original.sides,
};

pub fn create(gpa: std.mem.Allocator, profile: Profile) !p.snapshot.Loaded {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const layer_count: usize = switch (profile) {
        .danish => original.keymap.len,
        .eurmac => 4,
        else => 6,
    };
    const layers = try a.alloc(p.Layer, layer_count);
    const layer_names = [_][]const u8{ "Base", "Navigation", "Numbers", "Symbols", "Gaming", "Media" };
    for (layers, 0..) |*layer, index| layer.* = .{
        .id = @intCast(index + 1),
        .name = layer_names[index],
        .actions = try a.alloc(?p.Action, 34),
    };
    var doc = p.Document{
        .schema_version = 1,
        .board_id = board.id,
        .profile_id = profileId(profile),
        .name = names[@backingInt(profile)],
        .physical_layout = board.physical_layout,
        .key_ids = board.key_ids,
        .layers = layers,
    };
    var sources: []const p.snapshot.SourceBytes = &.{};
    switch (profile) {
        .danish => sources = try populateDanish(a, &doc),
        .eurmac => {
            @import("eurmac.zig").populate(layers);
            doc.combos = &recovery_combo;
        },
        .qwerty, .eurkey => {
            populateQwerty(layers);
            doc.combos = &recovery_combo;
        },
    }
    try p.snapshot.validate(.{ .document = doc, .sources = sources }, board);
    return p.snapshot.clone(gpa, .{ .document = doc, .sources = sources });
}

fn profileId(profile: Profile) [8]u8 {
    const name = @tagName(profile);
    var id: [8]u8 = @splat(0);
    @memcpy(id[0..name.len], name);
    return id;
}

/// Deliberate recovery chord, separate from ordinary letters and thumbs.
const recovery_combo = [_]p.Combo{.{
    .key_ids = .{ key_ids[0], key_ids[4] },
    .layer_id = 1,
    .timeout = .{ .ms = 40 },
    .action = .{ .tap_only = .{ .key_press = .{ .tap_keycode = 252 } } },
}};

/// Lifts the official Rollercole keymap, combos and its registered callback.
fn populateDanish(a: std.mem.Allocator, doc: *p.Document) ![]const p.snapshot.SourceBytes {
    const layers = doc.layers;
    for (original.keymap, layers) |source_layer, layer| {
        const actions = @constCast(layer.actions);
        for (source_layer, actions) |action, *dest| {
            dest.* = if (action) |value| try p.adapter.liftAction(layers, value) else null;
        }
    }
    const combos = try a.alloc(p.Combo, original.combos.len);
    for (original.combos, combos) |combo, *dest| dest.* = .{
        .key_ids = .{ key_ids[combo.key_indexes[0]], key_ids[combo.key_indexes[1]] },
        .layer_id = layers[combo.layer].id,
        .timeout = combo.timeout,
        .action = try p.adapter.liftAction(layers, combo.key_def),
    };
    doc.combos = combos;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(registered_source, &hash, .{});
    const metadata = try a.alloc(p.Source, 1);
    metadata[0] = .{ .path = registered_entry, .digest = hash };
    const callbacks = try a.alloc(p.Callback, 1);
    callbacks[0] = .{
        .kind = .registered,
        .binding = registered_binding,
        .ids = &.{ 1, 2, 3, 4 },
        .required_layers = &.{ 1, 2, 3, 4 },
        .index_constraints = &.{ 1, 2, 3, 4 },
        .sources = metadata,
    };
    doc.callbacks = callbacks;
    const bytes = try a.alloc(p.snapshot.SourceBytes, 1);
    bytes[0] = .{ .callback_index = 0, .path = registered_entry, .bytes = registered_source };
    return bytes;
}

/// QWERTY letters on base, gaming and shifted symbol layers, arrows on
/// navigation, digits on numbers, and layer-tap thumbs for space and enter.
fn populateQwerty(layers: []p.Layer) void {
    const usages = [_]u8{
        20, 26, 8,  21, 23, 28, 24, 12, 18, 19,
        4,  22, 7,  9,  10, 11, 13, 14, 15, 51,
        29, 27, 6,  25, 5,  17, 16, 54, 55, 56,
        44, 40, 42, 43,
    };
    for (layers, 0..) |layer, li| for (@constCast(layer.actions), 0..) |*action, ki| {
        const usage: u8 = switch (li) {
            0, 3, 4 => usages[ki],
            1 => switch (ki) {
                16 => 80,
                17 => 81,
                18 => 82,
                19 => 79,
                else => 0,
            },
            2 => @intCast(30 + ki % 10),
            else => 0,
        };
        action.* = if (usage == 0) null else .{ .tap_only = .{ .key_press = .{
            .tap_keycode = usage,
            .tap_modifiers = if (li == 3) .{ .left_shift = true } else .{},
        } } };
    };
    @constCast(layers[0].actions)[30] = .{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = 44 } },
        .hold = .{ .layer_id = 2 },
        .tapping_term = .{ .ms = 180 },
    } };
    @constCast(layers[0].actions)[31] = .{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = 40 } },
        .hold = .{ .layer_id = 3 },
        .tapping_term = .{ .ms = 180 },
    } };
}

pub fn callbackEntry(snapshot: p.snapshot.Snapshot, index: usize) ![]const u8 {
    const callback = snapshot.document.callbacks[index];
    if (callback.kind == .attached) return callback.binding;
    if (!std.mem.eql(u8, callback.binding, registered_binding) or
        callback.sources.len != 1 or
        !std.mem.eql(u8, callback.sources[0].path, registered_entry)) return error.UnknownRegisteredCallback;
    if (!std.mem.eql(u8, callback.ids, &.{ 1, 2, 3, 4 }) or
        snapshot.document.layers.len < 4 or
        callback.required_layers.len != 4) return error.RegisteredConstraintMismatch;
    const constraints = callback.index_constraints orelse return error.RegisteredConstraintMismatch;
    if (constraints.len != 4) return error.RegisteredConstraintMismatch;
    for (snapshot.document.layers[0..4], callback.required_layers, constraints) |layer, required, constraint| {
        if (layer.id != required or layer.id != constraint) return error.RegisteredConstraintMismatch;
    }
    const bytes = try p.snapshot.find(snapshot, index, registered_entry);
    if (!std.mem.eql(u8, bytes, registered_source)) return error.RegisteredSourceMismatch;
    return registered_entry;
}

test "curated Danish preserves selected official profile actions and callback bytes" {
    var loaded = try create(std.testing.allocator, .danish);
    defer loaded.deinit();
    const doc = loaded.snapshot.document;
    for (original.keymap, doc.layers) |source, layer| for (source, layer.actions) |action, lifted| {
        const restored = if (lifted) |value| try p.lowerAction(doc, value) else null;
        try std.testing.expect(std.meta.eql(action, restored));
    };
    try std.testing.expectEqual(original.combos.len, doc.combos.len);
    try std.testing.expectEqualStrings(registered_source, loaded.snapshot.sources[0].bytes);
    try std.testing.expectEqualStrings(registered_entry, try callbackEntry(loaded.snapshot, 0));
    try std.testing.expectError(error.LayerReferenced, p.canDeleteLayer(doc, 2));
}

test "representative EurKEY and QWERTY projects validate without callbacks" {
    for ([_]Profile{ .qwerty, .eurkey }) |profile| {
        var loaded = try create(std.testing.allocator, profile);
        defer loaded.deinit();
        try p.validate(loaded.snapshot.document, board);
        try std.testing.expectEqual(@as(usize, 6), loaded.snapshot.document.layers.len);
        try std.testing.expectEqual(
            @as(u8, 80),
            (try p.lowerAction(loaded.snapshot.document, loaded.snapshot.document.layers[1].actions[16].?)).tap_only.key_press.?.tap_keycode,
        );
    }
}
