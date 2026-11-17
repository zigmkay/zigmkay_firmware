//! Inventory from the selected firmware, with host-owned display capabilities.
const std = @import("std");
const model = @import("layout-model");
const defaults = @import("firmware-defaults");
const boards = defaults.boards;
pub const version: u16 = 1;
pub const Capability = enum { available, unverified, unavailable };
pub const Fidelity = enum { indexed_schematic, curated_schematic };
pub const presentation = @import("presentation.zig");
pub const Entry = struct {
    selector: []const u8,
    display: presentation.Metadata,
    firmware_source: []const u8,
    default_profile_source: []const u8,
    default_dimensions: model.KeymapDimensions,
    default_profile_sides: ?[]const model.Side,
    default_profile_encoder_slots: ?usize,
    /// Authoritative processing values used by the selected board entrypoint.
    processing_sides: []const model.Side,
    encoder_action_slots: usize,
    /// Logical processing-index digest; does not certify GPIO wiring.
    processing_digest: [32]u8,
    geometry: []const model.physical_layout.Key,
    fidelity: Fidelity,
    source_preservation: Capability = .available,
    project_editing: Capability = .unverified,
    native_processor: Capability = .unverified,
    firmware_compilation: Capability = .unverified,
    live_telemetry: Capability = .unverified,
    /// Index/ID digest excludes coordinates and captions. It does not certify
    /// GPIO wiring, split ownership or a firmware hardware revision.
    index_digest: [32]u8,
};

pub const entries = blk: {
    @setEvalBranchQuota(1_000_000);
    var result: [boards.entries.len]Entry = undefined;
    for (boards.entries, 0..) |board, i| {
        const Profile = defaults.profiles[i];
        const processing = defaults.processing_descriptors.find(board.name).?;
        const dimensions: model.KeymapDimensions = .{
            .key_count = @typeInfo(@typeInfo(@TypeOf(Profile.keymap)).array.child).array.len,
            .layer_count = @typeInfo(@TypeOf(Profile.keymap)).array.len,
        };
        const geometry = if (std.mem.eql(u8, board.name, "lk7")) &@import("lk7-physical").keys else &presentation.geometry(dimensions.key_count);
        if (dimensions.key_count != processing.key_count) @compileError("Default profile dimensions differ from board processing descriptor");
        if (@hasDecl(Profile, "sides")) {
            if (!std.mem.eql(model.Side, &Profile.sides, processing.sides)) @compileError("Default profile sides differ from board processing descriptor");
        }
        if (@hasDecl(Profile, "encoder_actions") and Profile.encoder_actions.len != processing.encoder_actions)
            @compileError("Default profile encoder slots differ from board processing descriptor");
        result[i] = .{
            .selector = board.name,
            .display = presentation.metadata(board.name),
            .firmware_source = board.root_source_file,
            .default_profile_source = board.default_keymap,
            .default_dimensions = dimensions,
            .default_profile_sides = if (@hasDecl(Profile, "sides")) &Profile.sides else null,
            .default_profile_encoder_slots = if (@hasDecl(Profile, "encoder_actions")) Profile.encoder_actions.len else null,
            .processing_sides = processing.sides,
            .encoder_action_slots = processing.encoder_actions,
            .processing_digest = processingDigest(board.name, processing.sides, processing.encoder_actions),
            .geometry = geometry,
            .fidelity = .curated_schematic,
            .index_digest = indexDigest(board.name, geometry),
        };
    }
    break :blk result;
};
pub const unselected_examples = boards.unselected_examples;

/// Borrowed logical defaults in firmware key-index order. Missing profile fields
/// remain unknown; consumers must not derive processing sides from display hands.
/// Callback source bytes are preserved as data, never executed by this adapter.
pub const DefaultData = struct {
    entry: *const Entry,
    layers: []const []const ?model.KeyDef,
    combos: []const model.Combo2Def,
    sides: ?[]const model.Side,
    encoder_actions: ?[]const model.EncoderAction,
    has_callbacks: bool,
    /// Exact source closure for the selected callback module, rooted at keyboards/.
    /// Named std/zigmkay/zkeycodes imports remain selected toolchain dependencies.
    callback_sources: []const SourceFile,
};

pub const SourceFile = struct { path: []const u8, bytes: []const u8 };

pub fn defaultData(selector: []const u8) ?DefaultData {
    inline for (entries, 0..) |entry, i| {
        if (std.mem.eql(u8, selector, entry.selector)) {
            const Profile = defaults.profiles[i];
            const layers = comptime blk: {
                var result: [entry.default_dimensions.layer_count][]const ?model.KeyDef = undefined;
                for (&Profile.keymap, 0..) |*layer, index| result[index] = layer;
                break :blk result;
            };
            const has_callbacks = comptime blk: {
                if (!@hasDecl(Profile, "custom_functions")) break :blk false;
                for (@typeInfo(@TypeOf(Profile.custom_functions)).@"struct".field_names) |field|
                    if (@field(Profile.custom_functions, field) != null) break :blk true;
                break :blk false;
            };
            return .{
                .entry = &entries[i],
                .layers = &layers,
                .combos = if (@hasDecl(Profile, "combos")) &Profile.combos else &.{},
                .sides = entry.default_profile_sides,
                .encoder_actions = if (@hasDecl(Profile, "encoder_actions")) &Profile.encoder_actions else null,
                .has_callbacks = has_callbacks,
                .callback_sources = if (has_callbacks) comptime blk: {
                    const source = SourceFile{ .path = entry.default_profile_source, .bytes = @embedFile(std.fmt.comptimePrint("default-source-{d}", .{i})) };
                    if (std.mem.startsWith(u8, entry.default_profile_source, "my_keyboards/janbeelte/"))
                        break :blk &[_]SourceFile{ source, .{ .path = "my_keyboards/janbeelte/keymap_shared.zig", .bytes = @embedFile("janbeelte-shared-source") } };
                    break :blk &[_]SourceFile{source};
                } else &.{},
            };
        }
    }
    return null;
}

pub const GeometryError = model.physical_layout.ValidationError || error{IndexDigestMismatch};

/// Validate the complete index/ID bijection before passing display geometry to
/// logical consumers. This contract still makes no claim about hardware wiring.
pub fn validateGeometry(entry: Entry) GeometryError!void {
    try model.physical_layout.validateKeys(entry.geometry, entry.default_dimensions);
    if (!std.mem.eql(u8, &entry.index_digest, &indexDigest(entry.selector, entry.geometry)))
        return error.IndexDigestMismatch;
}

/// Return stable numeric IDs in logical key-index order, independent of display
/// ordering. The caller owns the returned allocation.
pub fn keyIds(gpa: std.mem.Allocator, entry: Entry) ![]model.physical_layout.KeyId {
    try validateGeometry(entry);
    const result = try gpa.alloc(model.physical_layout.KeyId, entry.default_dimensions.key_count);
    for (entry.geometry) |key| result[key.key_index] = key.id;
    return result;
}

fn schematic(comptime count: usize) [count]model.physical_layout.Key {
    var keys: [count]model.physical_layout.Key = undefined;
    for (&keys, 0..) |*key, index| key.* = .{
        .id = @intCast(index),
        .key_index = @intCast(index),
        .x = @floatFromInt(index % 10),
        .y = @floatFromInt(index / 10),
        .hand = .neutral,
    };
    return keys;
}

pub fn indexDigest(selector: []const u8, keys: []const model.physical_layout.Key) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-catalog-index-v1\x00");
    hash.update(selector);
    hash.update(&.{0});
    for (keys) |key| {
        var id: [2]u8 = undefined;
        std.mem.writeInt(u16, &id, key.id, .little);
        hash.update(&id);
        hash.update(&.{key.key_index});
    }
    return hash.finalResult();
}

/// Canonical indexed processing contract, independent of display geometry and
/// optional profile declarations. Index order comes from the sides slice.
pub fn processingDigest(selector: []const u8, sides: []const model.Side, encoder_action_slots: usize) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-catalog-processing-v1\x00");
    hash.update(selector);
    hash.update(&.{0});
    var count: [8]u8 = undefined;
    std.mem.writeInt(u64, &count, sides.len, .little);
    hash.update(&count);
    for (sides) |side| hash.update(&.{switch (side) {
        .L => @as(u8, 0),
        .R => @as(u8, 1),
        .X => @as(u8, 2),
    }});
    std.mem.writeInt(u64, &count, encoder_action_slots, .little);
    hash.update(&count);
    return hash.finalResult();
}

pub fn find(selector: []const u8) ?*const Entry {
    for (&entries) |*entry| if (std.mem.eql(u8, selector, entry.selector)) return entry;
    return null;
}

test "selected firmware inventory is complete and all geometry indexes validate" {
    try std.testing.expectEqual(boards.entries.len, entries.len);
    inline for (entries, 0..) |entry, i| {
        const Profile = defaults.profiles[i];
        try std.testing.expectEqualStrings(boards.entries[i].name, find(entry.selector).?.selector);
        try model.physical_layout.validateKeys(entry.geometry, entry.default_dimensions);
        try model.physical_layout.validateLogical(entry.default_dimensions, &Profile.keymap, if (@hasDecl(Profile, "combos")) &Profile.combos else &.{});
        if (entry.default_profile_sides) |sides| try std.testing.expectEqual(entry.default_dimensions.key_count, sides.len);
        try std.testing.expectEqual(.unverified, entry.project_editing);
        try std.testing.expectEqual(entry.default_dimensions.key_count, entry.processing_sides.len);
        try std.testing.expectEqual(entry.processing_digest, processingDigest(entry.selector, entry.processing_sides, entry.encoder_action_slots));
    }
    try std.testing.expect(find("yak") == null);
    try std.testing.expectEqualStrings("examples/yak/main.zig", unselected_examples[0]);
}

test "processing digest detects indexed side and encoder slot changes" {
    const entry = find("tuckytwotimes").?;
    try std.testing.expectEqual(@as(usize, 4), entry.encoder_action_slots);
    try std.testing.expect(entry.default_profile_encoder_slots == null);
    const sides = try std.testing.allocator.dupe(model.Side, entry.processing_sides);
    defer std.testing.allocator.free(sides);
    sides[0] = .R;
    try std.testing.expect(!std.mem.eql(u8, &entry.processing_digest, &processingDigest(entry.selector, sides, entry.encoder_action_slots)));
    try std.testing.expect(!std.mem.eql(u8, &entry.processing_digest, &processingDigest(entry.selector, entry.processing_sides, entry.encoder_action_slots + 1)));
}

test "schematic fallback preserves indexes and geometry edits do not change index digest" {
    const lk7 = find("lk7").?;
    try std.testing.expectEqual(Fidelity.curated_schematic, lk7.fidelity);
    try std.testing.expectEqual(Fidelity.curated_schematic, find("dasbob").?.fidelity);
    var keys = @import("lk7-physical").keys;
    keys[0].x += 3;
    try std.testing.expectEqual(lk7.index_digest, indexDigest(lk7.selector, &keys));
    keys[0].key_index = 1;
    try std.testing.expect(!std.mem.eql(u8, &lk7.index_digest, &indexDigest(lk7.selector, &keys)));
}

test "runtime defaults preserve every selected logical field and absent metadata" {
    inline for (entries, 0..) |entry, i| {
        const Profile = defaults.profiles[i];
        const data = defaultData(entry.selector).?;
        try std.testing.expectEqual(entry.default_dimensions.layer_count, data.layers.len);
        for (data.layers, &Profile.keymap) |layer, expected| try std.testing.expectEqualSlices(?model.KeyDef, &expected, layer);
        try std.testing.expectEqualSlices(model.Combo2Def, if (@hasDecl(Profile, "combos")) &Profile.combos else &.{}, data.combos);
        try std.testing.expectEqual(@hasDecl(Profile, "sides"), data.sides != null);
        try std.testing.expectEqual(@hasDecl(Profile, "encoder_actions"), data.encoder_actions != null);
        const ids = try keyIds(std.testing.allocator, entry);
        defer std.testing.allocator.free(ids);
        for (entry.geometry) |key| try std.testing.expectEqual(key.id, ids[key.key_index]);
    }
    try std.testing.expect(defaultData("yak") == null);
}

test "geometry validation rejects malformed index contracts and tolerates display reordering" {
    const original = find("dasbob").?.*;
    const keys = try std.testing.allocator.dupe(model.physical_layout.Key, original.geometry);
    defer std.testing.allocator.free(keys);
    var entry = original;
    entry.geometry = keys;
    std.mem.swap(model.physical_layout.Key, &keys[0], &keys[1]);
    entry.index_digest = indexDigest(entry.selector, keys);
    const ids = try keyIds(std.testing.allocator, entry);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(original.geometry[0].id, ids[0]);
    keys[0].id = keys[1].id;
    try std.testing.expectError(error.DuplicateId, validateGeometry(entry));
    keys[0] = original.geometry[1];
    keys[0].key_index = keys[1].key_index;
    try std.testing.expectError(error.DuplicateIndex, validateGeometry(entry));
    keys[0] = original.geometry[1];
    keys[0].id += 1000;
    try std.testing.expectError(error.IndexDigestMismatch, validateGeometry(entry));
}
