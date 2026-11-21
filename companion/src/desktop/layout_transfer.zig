//! Moves a layout onto another board or PCB revision. Keys match by key ID
//! when both boards share their ID scheme, otherwise by firmware key index.
//! Neither method uses key positions, so neither knows where a key sits; the
//! report says what could not be carried over.
const std = @import("std");
const p = @import("project");

pub const Match = enum { key_id, key_index };

pub const Report = struct {
    match: Match,
    source_keys: usize,
    target_keys: usize,
    matched: usize,
    /// Source keys without a counterpart, in source key-index order.
    missing: []const bool,
    /// The source key each target key takes its actions from.
    origin: []const ?usize,
    layers: usize,
    combos: usize,
    /// Combos that use a key without a counterpart.
    combos_dropped: usize,
    callbacks: usize,
    source_encoders: usize,
    target_encoders: usize,

    /// Whether every key, combo and encoder direction carries over unchanged.
    pub fn exact(self: Report) bool {
        return self.matched == self.source_keys and self.matched == self.target_keys and
            self.combos_dropped == 0 and self.source_encoders == self.target_encoders;
    }

    pub fn missingCount(self: Report) usize {
        return self.source_keys - self.matched;
    }
};

pub const Transferred = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: p.snapshot.Snapshot,
    report: Report,

    pub fn deinit(self: *Transferred) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// For each target key, the source key it corresponds to.
pub fn matchKeys(a: std.mem.Allocator, source: []const []const u8, target: []const []const u8) !struct { Match, []?usize } {
    const origin = try a.alloc(?usize, target.len);
    // Catalog boards name keys "key-<index>", so a shared catalog ID only
    // repeats the key index.
    var shared = false;
    for (target) |id| {
        if (std.mem.startsWith(u8, id, "key-")) continue;
        for (source) |candidate| if (std.mem.eql(u8, id, candidate)) {
            shared = true;
        };
    }
    if (shared) {
        for (target, origin) |id, *slot| {
            slot.* = for (source, 0..) |candidate, index| {
                if (std.mem.eql(u8, id, candidate)) break index;
            } else null;
        }
        return .{ .key_id, origin };
    }
    for (origin, 0..) |*slot, index| slot.* = if (index < source.len) index else null;
    return .{ .key_index, origin };
}

/// Copies `source` onto `target`. Layers, names, callbacks and their source
/// bytes are kept; keys and combos without a counterpart are dropped, new
/// keys stay unassigned and encoder directions are cut or padded.
pub fn transfer(gpa: std.mem.Allocator, source: p.snapshot.Snapshot, target: p.Board) !Transferred {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const doc = source.document;
    const match, const origin = try matchKeys(a, doc.key_ids, target.key_ids);
    const ids = try a.alloc([]const u8, target.key_ids.len);
    for (target.key_ids, ids) |id, *copy| copy.* = try a.dupe(u8, id);
    const missing = try a.alloc(bool, doc.key_ids.len);
    @memset(missing, true);
    var matched: usize = 0;
    for (origin) |slot| if (slot) |index| {
        missing[index] = false;
        matched += 1;
    };
    const layers = try a.alloc(p.Layer, doc.layers.len);
    for (doc.layers, layers) |layer, *copy| {
        const actions = try a.alloc(?p.Action, ids.len);
        for (actions, origin) |*action, slot| action.* = if (slot) |index| layer.actions[index] else null;
        copy.* = .{ .id = layer.id, .name = layer.name, .actions = actions };
    }
    var combos: std.ArrayList(p.Combo) = .empty;
    var dropped: usize = 0;
    for (doc.combos) |combo| {
        const first = targetId(doc.key_ids, ids, origin, combo.key_ids[0]);
        const second = targetId(doc.key_ids, ids, origin, combo.key_ids[1]);
        if (first == null or second == null) {
            dropped += 1;
            continue;
        }
        var copy = combo;
        copy.key_ids = .{ first.?, second.? };
        try combos.append(a, copy);
    }
    const encoders = try a.alloc(p.Tap, target.encoder_actions);
    for (encoders, 0..) |*encoder, index| encoder.* = if (index < doc.encoders.len) doc.encoders[index] else .{};
    var document = doc;
    document.board_id = target.id;
    document.physical_layout = target.physical_layout;
    document.key_ids = ids;
    document.layers = layers;
    document.combos = combos.items;
    document.encoders = encoders;
    // The result owns every byte, so it outlives `source`.
    const snapshot = try p.owned_zon.clone(a, p.snapshot.Snapshot{ .document = document, .sources = source.sources });
    try p.snapshot.validate(snapshot, target);
    return .{ .arena = arena, .snapshot = snapshot, .report = .{
        .match = match,
        .source_keys = doc.key_ids.len,
        .target_keys = ids.len,
        .matched = matched,
        .missing = missing,
        .origin = origin,
        .layers = doc.layers.len,
        .combos = combos.items.len,
        .combos_dropped = dropped,
        .callbacks = doc.callbacks.len,
        .source_encoders = doc.encoders.len,
        .target_encoders = encoders.len,
    } };
}

fn targetId(source: []const []const u8, target: []const []const u8, origin: []const ?usize, id: []const u8) ?[]const u8 {
    const index = for (source, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, id)) break index;
    } else return null;
    for (origin, target) |slot, target_id| if (slot != null and slot.? == index) return target_id;
    return null;
}
