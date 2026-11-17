const std = @import("std");
pub const collection = @import("collection.zig");
const model = @import("layout-model");
const protocol = @import("device-protocol");
pub const snapshot = @import("snapshot.zig");
pub const exporter = @import("export.zig");
pub const export_inventory = @import("export_inventory.zig");
pub const adapter = @import("adapter.zig");
pub const profiles = @import("profiles.zig");
pub const sources = @import("sources.zig");
pub const assessment = @import("assessment.zig");
pub const owned_zon = @import("owned-zon");

pub const schema_version = 1;
pub const Limits = struct {
    pub const document_bytes = 1024 * 1024;
    pub const source_bytes = 1024 * 1024;
    pub const source_files = 64;
    pub const combos = 1024;
    pub const keys = 127;
    pub const layers = 15;
    pub const name_bytes = 128;
    pub const path_bytes = 240;
};
pub const LayerId = u32;
pub const Hold = struct {
    hold_modifiers: model.Modifiers = .{},
    layer_id: ?LayerId = null,
    custom: ?u8 = null,
};
pub const Tap = struct {
    key_press: ?model.KeyCodeFire = null,
    one_shot: ?Hold = null,
    custom: ?u8 = null,
    media_key: ?model.MediaCode = null,
    mouse_action: ?model.MouseAction = null,
};
pub const Action = union(enum) {
    none,
    tap_only: Tap,
    hold_only: Hold,
    tap_hold: struct { tap: Tap, hold: Hold, tapping_term: model.TimeSpan, retro_tapping: bool = false },
    tap_with_autofire: struct { tap: Tap, initial_delay: model.TimeSpan, repeat_interval: model.TimeSpan },
};
pub const Layer = struct { id: LayerId, name: []const u8, actions: []const ?Action };
pub const Combo = struct { key_ids: [2][]const u8, layer_id: LayerId, timeout: model.TimeSpan, action: Action };
pub const Source = struct { path: []const u8, digest: [32]u8 };
pub const Callback = struct {
    kind: enum { registered, attached },
    // Registered IDs resolve through a curated registry; attached IDs name their entry file.
    binding: []const u8,
    abi_version: u16 = 1,
    ids: []const u8,
    required_layers: []const LayerId = &.{},
    // Null means index-sensitive opaque code: every index-changing deletion is locked.
    index_constraints: ?[]const LayerId = null,
    sources: []const Source,
};
pub const Document = struct {
    schema_version: u32,
    board_id: [8]u8,
    profile_id: [8]u8,
    physical_layout: []const u8,
    name: []const u8,
    key_ids: []const []const u8,
    layers: []const Layer,
    combos: []const Combo = &.{},
    encoders: []const Tap = &.{},
    callbacks: []const Callback = &.{},
};
/// Board-owned facts supplied by the catalog, never accepted from an editable document.
pub const Board = struct {
    id: [8]u8,
    physical_layout: []const u8,
    key_ids: []const []const u8,
    sides: []const model.Side,
    encoder_actions: usize = 0,
};
pub const ValidationError = error{
    UnsupportedVersion,
    DocumentTooLarge,
    InvalidBoard,
    InvalidName,
    InvalidKey,
    InvalidLayer,
    DuplicateLayer,
    InvalidDimensions,
    InvalidCombo,
    DuplicateCombo,
    InvalidTiming,
    InvalidCallback,
    InvalidPath,
    SourceLimit,
    DuplicateSource,
    LayerReferenced,
    CallbackIndexLocked,
};

/// Owns the terminated source as long as parser diagnostics borrow it.
pub const Diagnostics = struct {
    parser: std.zon.parse.Diagnostics = .{ .errors = &.{} },
    arena: ?std.heap.ArenaAllocator = null,
    source: ?[:0]u8 = null,
    pub fn deinit(self: *Diagnostics, gpa: std.mem.Allocator) void {
        if (self.arena) |*arena| arena.deinit();
        if (self.source) |source| gpa.free(source);
        self.* = .{};
    }
};
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, diagnostics: ?*Diagnostics) !Document {
    if (bytes.len > Limits.document_bytes) return error.DocumentTooLarge;
    if (diagnostics) |diag| std.debug.assert(diag.source == null);
    const terminated = try gpa.dupeSentinel(u8, bytes, 0);
    defer if (diagnostics == null) gpa.free(terminated);
    var local_arena = std.heap.ArenaAllocator.init(gpa);
    defer local_arena.deinit();
    var local_diagnostics: std.zon.parse.Diagnostics = undefined;
    const parser_diagnostics = if (diagnostics) |diag| blk: {
        diag.source = terminated;
        diag.arena = std.heap.ArenaAllocator.init(gpa);
        break :blk &diag.parser;
    } else &local_diagnostics;
    const arena = if (diagnostics) |diag| diag.arena.?.allocator() else local_arena.allocator();
    const parsed = try std.zon.parse.fromSlice(Document, .{ .gpa = gpa, .arena = arena, .source = terminated, .diagnostics = parser_diagnostics });
    const doc = try owned_zon.clone(gpa, parsed);
    errdefer deinit(gpa, doc);
    if (doc.schema_version != schema_version) return error.UnsupportedVersion;
    return doc;
}
pub fn deinit(gpa: std.mem.Allocator, doc: Document) void {
    owned_zon.free(gpa, doc);
}
pub fn serialize(gpa: std.mem.Allocator, doc: Document) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.zon.stringify.serializeMaxDepth(doc, .{}, &out.writer, 32);
    if (out.written().len > Limits.document_bytes) return error.DocumentTooLarge;
    return out.toOwnedSlice();
}
fn nameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > Limits.name_bytes or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
pub fn pathValid(path: []const u8) bool {
    return @import("portable_path.zig").valid(path, Limits.path_bytes) and std.mem.endsWith(u8, path, ".zig");
}
pub fn layerIndex(doc: Document, id: LayerId) ValidationError!model.LayerIndex {
    if (doc.layers.len > Limits.layers) return error.InvalidDimensions;
    for (doc.layers, 0..) |layer, index| if (layer.id == id) return @intCast(index);
    return error.InvalidLayer;
}
pub fn keyIndex(doc: Document, id: []const u8) ValidationError!model.KeyIndex {
    if (doc.key_ids.len > Limits.keys) return error.InvalidDimensions;
    for (doc.key_ids, 0..) |key, index| if (std.mem.eql(u8, key, id)) return @intCast(index);
    return error.InvalidKey;
}
fn customValid(doc: Document, id: ?u8, reserved: bool) ValidationError!void {
    const value = id orelse return;
    if (value == 0) return error.InvalidCallback;
    if (value >= 253) {
        if (!reserved) return error.InvalidCallback;
        return;
    }
    for (doc.callbacks) |callback| for (callback.ids) |declared| if (value == declared) return;
    return error.InvalidCallback;
}
pub fn lowerHold(doc: Document, value: Hold) ValidationError!model.HoldDef {
    try customValid(doc, value.custom, true);
    return .{ .hold_modifiers = value.hold_modifiers, .hold_layer = if (value.layer_id) |id| try layerIndex(doc, id) else null, .custom = value.custom };
}
pub fn lowerTap(doc: Document, value: Tap) ValidationError!model.TapDef {
    try customValid(doc, value.custom, true);
    return .{ .key_press = value.key_press, .one_shot = if (value.one_shot) |hold| try lowerHold(doc, hold) else null, .custom = value.custom, .media_key = value.media_key, .mouse_action = value.mouse_action };
}
pub fn lowerAction(doc: Document, value: Action) ValidationError!model.KeyDef {
    return switch (value) {
        .none => .none,
        .tap_only => |tap| .{ .tap_only = try lowerTap(doc, tap) },
        .hold_only => |hold| .{ .hold_only = try lowerHold(doc, hold) },
        .tap_hold => |th| blk: {
            if (th.tapping_term.ms == 0) return error.InvalidTiming;
            break :blk .{ .tap_hold = .{ .tap = try lowerTap(doc, th.tap), .hold = try lowerHold(doc, th.hold), .tapping_term = th.tapping_term, .retro_tapping = th.retro_tapping } };
        },
        .tap_with_autofire => |fire| blk: {
            if (fire.repeat_interval.ms == 0) return error.InvalidTiming;
            break :blk .{ .tap_with_autofire = .{ .tap = try lowerTap(doc, fire.tap), .initial_delay = fire.initial_delay, .repeat_interval = fire.repeat_interval } };
        },
    };
}
pub fn validate(doc: Document, board: Board) !void {
    if (doc.schema_version != schema_version) return error.UnsupportedVersion;
    if (!std.mem.eql(u8, &doc.board_id, &board.id) or !std.mem.eql(u8, doc.physical_layout, board.physical_layout)) return error.InvalidBoard;
    try protocol.validateIdentity(.{ .board_id = doc.board_id, .profile_id = doc.profile_id, .digest = @splat(0), .dimensions = .{ .key_count = 1, .layer_count = 1 } });
    if (!nameValid(doc.name)) return error.InvalidName;
    if (doc.key_ids.len == 0 or doc.key_ids.len > Limits.keys or doc.key_ids.len != board.key_ids.len or board.sides.len != doc.key_ids.len or doc.layers.len == 0 or doc.layers.len > Limits.layers or doc.encoders.len != board.encoder_actions) return error.InvalidDimensions;
    for (doc.key_ids, board.key_ids, 0..) |key, expected, index| {
        if (!nameValid(key) or !std.mem.eql(u8, key, expected)) return error.InvalidKey;
        for (doc.key_ids[0..index]) |earlier| if (std.mem.eql(u8, earlier, key)) return error.InvalidKey;
    }
    var source_count: usize = 0;
    var ids: [253]bool = @splat(false);
    if (doc.callbacks.len > 252) return error.InvalidCallback;
    for (doc.callbacks, 0..) |callback, ci| {
        if (callback.abi_version != 1 or callback.ids.len == 0 or callback.sources.len == 0) return error.InvalidCallback;
        switch (callback.kind) {
            .attached => if (!pathValid(callback.binding)) return error.InvalidPath,
            .registered => {
                if (callback.binding.len == 0 or callback.binding.len > Limits.name_bytes) return error.InvalidCallback;
                for (callback.binding) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return error.InvalidCallback;
            },
        }
        for (doc.callbacks[0..ci]) |earlier| if (std.mem.eql(u8, callback.binding, earlier.binding)) return error.InvalidCallback;
        for (callback.ids) |id| {
            if (id == 0 or id >= 253 or ids[id]) return error.InvalidCallback;
            ids[id] = true;
        }
        for (callback.required_layers) |id| _ = try layerIndex(doc, id);
        if (callback.index_constraints) |constraints| for (constraints) |id| {
            _ = try layerIndex(doc, id);
        };
        source_count += callback.sources.len;
        if (source_count > Limits.source_files) return error.SourceLimit;
        var entry_found = false;
        for (callback.sources, 0..) |source, si| {
            if (!pathValid(source.path)) return error.InvalidPath;
            if (std.mem.eql(u8, source.path, callback.binding)) entry_found = true;
            for (callback.sources[0..si]) |earlier| if (std.mem.eql(u8, source.path, earlier.path)) return error.DuplicateSource;
        }
        if (callback.kind == .attached and !entry_found) return error.InvalidCallback;
    }
    for (doc.layers, 0..) |layer, index| {
        if (layer.id == 0) return error.InvalidLayer;
        if (!nameValid(layer.name)) return error.InvalidName;
        if (layer.actions.len != doc.key_ids.len) return error.InvalidDimensions;
        for (doc.layers[0..index]) |earlier| if (earlier.id == layer.id) return error.DuplicateLayer;
    }
    for (doc.layers) |layer| for (layer.actions) |action| if (action) |value| {
        _ = try lowerAction(doc, value);
    };
    if (doc.combos.len > Limits.combos) return error.InvalidCombo;
    for (doc.combos, 0..) |combo, index| {
        const first = try keyIndex(doc, combo.key_ids[0]);
        const second = try keyIndex(doc, combo.key_ids[1]);
        if (first == second or combo.timeout.ms == 0) return error.InvalidCombo;
        _ = try layerIndex(doc, combo.layer_id);
        _ = try lowerAction(doc, combo.action);
        for (doc.combos[0..index]) |earlier| {
            if (earlier.layer_id != combo.layer_id) continue;
            const a = try keyIndex(doc, earlier.key_ids[0]);
            const b = try keyIndex(doc, earlier.key_ids[1]);
            if ((a == first and b == second) or (a == second and b == first)) return error.DuplicateCombo;
        }
    }
    for (doc.encoders) |tap| _ = try lowerTap(doc, tap);
}
fn holdReferences(hold: Hold, id: LayerId) bool {
    return hold.layer_id == id;
}
fn tapReferences(tap: Tap, id: LayerId) bool {
    return if (tap.one_shot) |hold| holdReferences(hold, id) else false;
}
fn actionReferences(action: Action, id: LayerId) bool {
    return switch (action) {
        .none => false,
        .tap_only => |tap| tapReferences(tap, id),
        .hold_only => |hold| holdReferences(hold, id),
        .tap_hold => |th| tapReferences(th.tap, id) or holdReferences(th.hold, id),
        .tap_with_autofire => |fire| tapReferences(fire.tap, id),
    };
}
/// Checks deletion only. The editor applies it as one undoable edit after validation.
pub fn canDeleteLayer(doc: Document, id: LayerId) ValidationError!void {
    const index = try layerIndex(doc, id);
    if (index == 0 or doc.layers.len == 1) return error.LayerReferenced;
    for (doc.layers) |layer| {
        if (layer.id == id) continue;
        for (layer.actions) |action| if (action) |value| {
            if (actionReferences(value, id)) return error.LayerReferenced;
        };
    }
    for (doc.combos) |combo| if (combo.layer_id == id or actionReferences(combo.action, id)) return error.LayerReferenced;
    for (doc.encoders) |tap| if (tapReferences(tap, id)) return error.LayerReferenced;
    for (doc.callbacks) |callback| {
        for (callback.required_layers) |required| if (required == id) return error.LayerReferenced;
        if (callback.index_constraints) |constraints| {
            for (constraints) |required| if (try layerIndex(doc, required) >= index) return error.CallbackIndexLocked;
        } else if (index + 1 < doc.layers.len) return error.CallbackIndexLocked;
    }
}

test {
    _ = collection;
    _ = @import("tests.zig");
    _ = profiles;
    _ = sources;
    _ = assessment;
}
