//! Offline schema-1 catalog consumers. Synthetic fixtures are explicit inputs,
//! never evidence of GPIO wiring, board revisions or live-device compatibility.
const std = @import("std");
const catalog = @import("catalog");
const project = @import("project");
const model = @import("layout-model");

pub const OwnedBoard = struct {
    arena: std.heap.ArenaAllocator,
    board: project.Board,
    entry: *const catalog.Entry,
    /// Kept for callers of the initial adapter. Always false now that selected
    /// firmware entrypoints own portable authoritative processing descriptors.
    uses_schematic_sides: bool,

    pub fn init(gpa: std.mem.Allocator, selector: []const u8) !OwnedBoard {
        const entry = catalog.find(selector) orelse return error.UnknownSelector;
        try catalog.validateGeometry(entry.*);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const numeric_ids = try catalog.keyIds(a, entry.*);
        const ids = try a.alloc([]const u8, numeric_ids.len);
        for (numeric_ids, ids) |id, *text| text.* = try std.fmt.allocPrint(a, "key-{d}", .{id});
        const sides = try a.dupe(model.Side, entry.processing_sides);
        const physical_layout = try std.fmt.allocPrint(a, "catalog-index-v1:{s}", .{selector});
        return .{
            .arena = arena,
            .entry = entry,
            .uses_schematic_sides = false,
            .board = .{
                .id = boardId(selector),
                .physical_layout = physical_layout,
                .key_ids = ids,
                .sides = sides,
                .encoder_actions = entry.encoder_action_slots,
            },
        };
    }

    pub fn deinit(self: *OwnedBoard) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Resolve only established document identities, then validate the complete
    /// contract. Custom boards need an explicitly injected descriptor.
    pub fn fromDocument(gpa: std.mem.Allocator, document: project.Document) !OwnedBoard {
        if (std.mem.eql(u8, &document.board_id, &project.profiles.board.id)) {
            try project.validate(document, project.profiles.board);
            var arena: std.heap.ArenaAllocator = .init(gpa);
            errdefer arena.deinit();
            const a = arena.allocator();
            var board = project.profiles.board;
            board.physical_layout = try a.dupe(u8, board.physical_layout);
            const ids = try a.alloc([]const u8, board.key_ids.len);
            for (board.key_ids, ids) |id, *copy| copy.* = try a.dupe(u8, id);
            board.key_ids = ids;
            board.sides = try a.dupe(model.Side, board.sides);
            return .{ .arena = arena, .board = board, .entry = catalog.find("lk7").?, .uses_schematic_sides = false };
        }
        for (catalog.entries) |entry| {
            const id = boardId(entry.selector);
            if (std.mem.eql(u8, &document.board_id, &id)) {
                var owned = try init(gpa, entry.selector);
                errdefer owned.deinit();
                try project.validate(document, owned.board);
                return owned;
            }
        }
        return error.UnknownDocumentBoard;
    }
};

test "document board resolution preserves curated identity and validates every catalog contract" {
    var curated = try project.profiles.create(std.testing.allocator, .qwerty);
    defer curated.deinit();
    var original = try OwnedBoard.fromDocument(std.testing.allocator, curated.snapshot.document);
    defer original.deinit();
    try std.testing.expectEqualStrings("lk7_schematic_v1", original.board.physical_layout);
    try std.testing.expectEqualStrings(project.profiles.board.key_ids[0], original.board.key_ids[0]);
    for (catalog.entries) |entry| {
        var board = try OwnedBoard.init(std.testing.allocator, entry.selector);
        defer board.deinit();
        var fixture = try createSynthetic(std.testing.allocator, board);
        defer fixture.deinit();
        var resolved = try OwnedBoard.fromDocument(std.testing.allocator, fixture.snapshot.document);
        defer resolved.deinit();
        try std.testing.expectEqualStrings(entry.selector, resolved.entry.selector);
        var malformed = fixture.snapshot.document;
        malformed.physical_layout = "different";
        try std.testing.expectError(error.InvalidBoard, OwnedBoard.fromDocument(std.testing.allocator, malformed));
    }
    var unknown = curated.snapshot.document;
    unknown.board_id = "unknown1".*;
    try std.testing.expectError(error.UnknownDocumentBoard, OwnedBoard.fromDocument(std.testing.allocator, unknown));
}

test "owned board arena remains valid for allocations after handoff" {
    var board = try OwnedBoard.init(std.testing.allocator, "dasbob");
    defer board.deinit();
    const scratch = try board.arena.allocator().alloc(u8, 256);
    @memset(scratch, 0xff);
    try std.testing.expectEqualStrings("catalog-index-v1:dasbob", board.board.physical_layout);
    var fixture = try createSynthetic(std.testing.allocator, board);
    defer fixture.deinit();
    try project.validate(fixture.snapshot.document, board.board);
}

/// Versioned, domain-separated selector identity: eight base32 ASCII characters
/// from 40 digest bits, conforming to schema-1 protocol ID syntax.
/// This identity belongs to offline catalog projects and is not a device ID.
pub fn boardId(selector: []const u8) [8]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-catalog-schema1-board-v1\x00");
    hash.update(selector);
    const digest = hash.finalResult();
    var bits: u64 = 0;
    for (digest[0..5]) |byte| bits = (bits << 8) | byte;
    const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
    var id: [8]u8 = undefined;
    for (&id, 0..) |*char, index| char.* = alphabet[@intCast((bits >> @as(u6, @intCast(35 - index * 5))) & 31)];
    return id;
}

pub const OwnedProject = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: project.snapshot.Snapshot,

    pub fn deinit(self: *OwnedProject) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A one-layer fixture exercises every board key index and encoder slot without
/// importing callbacks or pretending to reproduce the board's default behavior.
/// The returned snapshot owns all its bytes and does not borrow OwnedBoard.
pub fn createSynthetic(gpa: std.mem.Allocator, owned_board: OwnedBoard) !OwnedProject {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const board = owned_board.board;
    const ids = try a.alloc([]const u8, board.key_ids.len);
    for (board.key_ids, ids) |id, *copy| copy.* = try a.dupe(u8, id);
    const actions = try a.alloc(?project.Action, ids.len);
    for (actions, 0..) |*action, i| action.* = .{ .tap_only = .{ .key_press = .{ .tap_keycode = @intCast(4 + i % 26) } } };
    const layers = try a.alloc(project.Layer, 1);
    layers[0] = .{ .id = 1, .name = "Synthetic", .actions = actions };
    const encoders = try a.alloc(project.Tap, board.encoder_actions);
    @memset(encoders, .{ .key_press = .{ .tap_keycode = 4 } });
    const snapshot: project.snapshot.Snapshot = .{ .document = .{
        .schema_version = project.schema_version,
        .board_id = board.id,
        .profile_id = "synth_v1".*,
        .physical_layout = try a.dupe(u8, board.physical_layout),
        .name = try std.fmt.allocPrint(a, "{s} offline synthetic", .{owned_board.entry.selector}),
        .key_ids = ids,
        .layers = layers,
        .encoders = encoders,
    }, .sources = &.{} };
    try project.snapshot.validate(snapshot, board);
    return .{ .arena = arena, .snapshot = snapshot };
}

/// Lift actual typed defaults and preserve their byte-exact callback closure.
/// Attached schema-1 bindings deliberately remain distinct from curated/historical
/// registered bindings. No callback is executed while constructing the project.
pub fn createDefault(gpa: std.mem.Allocator, owned_board: OwnedBoard) !OwnedProject {
    const data = catalog.defaultData(owned_board.entry.selector) orelse return error.UnknownSelector;
    return createData(gpa, owned_board, data);
}

/// Shared lossless typed conversion for catalog templates and captured imports.
pub fn createData(gpa: std.mem.Allocator, owned_board: OwnedBoard, data: catalog.DefaultData) !OwnedProject {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const board = owned_board.board;
    const ids = try a.alloc([]const u8, board.key_ids.len);
    for (board.key_ids, ids) |id, *copy| copy.* = try a.dupe(u8, id);
    const layers = try a.alloc(project.Layer, data.layers.len);
    for (layers, 0..) |*layer, index| layer.* = .{
        .id = @intCast(index + 1),
        .name = try std.fmt.allocPrint(a, "Layer {d}", .{index + 1}),
        .actions = try a.alloc(?project.Action, ids.len),
    };
    for (data.layers, layers) |source, layer| {
        if (source.len != ids.len) return error.InvalidDimensions;
        for (source, @constCast(layer.actions)) |action, *dest|
            dest.* = if (action) |value| try project.adapter.liftAction(layers, value) else null;
    }
    const combos = try a.alloc(project.Combo, data.combos.len);
    for (data.combos, combos) |combo, *dest| {
        if (combo.layer >= layers.len or combo.key_indexes[0] >= ids.len or combo.key_indexes[1] >= ids.len) return error.InvalidCombo;
        dest.* = .{ .key_ids = .{ ids[combo.key_indexes[0]], ids[combo.key_indexes[1]] }, .layer_id = layers[combo.layer].id, .timeout = combo.timeout, .action = try project.adapter.liftAction(layers, combo.key_def) };
    }
    const encoders = try a.alloc(project.Tap, board.encoder_actions);
    @memset(encoders, .{});
    if (data.encoder_actions) |source| {
        if (source.len != encoders.len) return error.InvalidDimensions;
        for (source, encoders) |encoder, *dest| dest.* = try project.adapter.liftTap(layers, encoder.tap);
    }
    const callbacks = try a.alloc(project.Callback, if (data.has_callbacks) 1 else 0);
    const sources = try a.alloc(project.snapshot.SourceBytes, data.callback_sources.len);
    if (data.has_callbacks) {
        if (sources.len == 0) return error.DefaultCallbacksRequireBinding;
        const metadata = try a.alloc(project.Source, sources.len);
        for (data.callback_sources, sources, metadata) |source, *bytes, *meta| {
            const path = try a.dupe(u8, source.path);
            const content = try a.dupe(u8, source.bytes);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
            bytes.* = .{ .callback_index = 0, .path = path, .bytes = content };
            meta.* = .{ .path = path, .digest = digest };
        }
        // Collect the custom IDs actually referenced by typed actions, including
        // hold/one-shot and ordered combos. Reserved processor signals are not
        // callback declarations. A callback-only default without IDs is explicitly
        // unsupported by schema 1 rather than silently discarded.
        var used: [253]bool = @splat(false);
        for (data.layers) |layer| for (layer) |action| if (action) |value| collectAction(&used, value);
        for (data.combos) |combo| collectAction(&used, combo.key_def);
        if (data.encoder_actions) |actions| for (actions) |encoder| collectTap(&used, encoder.tap);
        var count: usize = 0;
        for (used) |present| if (present) {
            count += 1;
        };
        if (count == 0) return error.DefaultCallbackWithoutIds;
        const custom_ids = try a.alloc(u8, count);
        var cursor: usize = 0;
        for (used, 0..) |present, id| if (present) {
            custom_ids[cursor] = @intCast(id);
            cursor += 1;
        };
        const constraints = try a.alloc(project.LayerId, layers.len);
        for (layers, constraints) |layer, *id| id.* = layer.id;
        callbacks[0] = .{ .kind = .attached, .binding = sources[0].path, .ids = custom_ids, .required_layers = constraints, .index_constraints = constraints, .sources = metadata };
    }
    const snapshot: project.snapshot.Snapshot = .{ .document = .{
        .schema_version = project.schema_version,
        .board_id = board.id,
        .profile_id = "default1".*,
        .physical_layout = try a.dupe(u8, board.physical_layout),
        .name = try std.fmt.allocPrint(a, "{s} firmware default", .{owned_board.entry.selector}),
        .key_ids = ids,
        .layers = layers,
        .combos = combos,
        .encoders = encoders,
        .callbacks = callbacks,
    }, .sources = sources };
    try project.snapshot.validate(snapshot, board);
    try project.sources.verify(a, snapshot);
    return .{ .arena = arena, .snapshot = snapshot };
}

fn collectId(used: *[253]bool, id: ?u8) void {
    if (id) |value| if (value > 0 and value < used.len) {
        used[value] = true;
    };
}
fn collectHold(used: *[253]bool, hold: model.HoldDef) void {
    collectId(used, hold.custom);
}
fn collectTap(used: *[253]bool, tap: model.TapDef) void {
    collectId(used, tap.custom);
    if (tap.one_shot) |hold| collectHold(used, hold);
}
fn collectAction(used: *[253]bool, action: model.KeyDef) void {
    switch (action) {
        .none => {},
        .tap_only => |tap| collectTap(used, tap),
        .hold_only => |hold| collectHold(used, hold),
        .tap_hold => |value| {
            collectTap(used, value.tap);
            collectHold(used, value.hold);
        },
        .tap_with_autofire => |value| collectTap(used, value.tap),
    }
}

test "typed defaults retain every action and exact callback closure" {
    for (catalog.entries) |entry| {
        var board = try OwnedBoard.init(std.testing.allocator, entry.selector);
        defer board.deinit();
        const data = catalog.defaultData(entry.selector).?;
        var imported = try createDefault(std.testing.allocator, board);
        defer imported.deinit();
        const doc = imported.snapshot.document;
        try std.testing.expectEqual(@as(usize, if (data.has_callbacks) 1 else 0), doc.callbacks.len);
        try std.testing.expectEqual(data.callback_sources.len, imported.snapshot.sources.len);
        for (data.callback_sources, imported.snapshot.sources) |original, captured| {
            try std.testing.expectEqualStrings(original.path, captured.path);
            try std.testing.expectEqualStrings(original.bytes, captured.bytes);
        }
        if (data.has_callbacks) {
            const callback = doc.callbacks[0];
            try std.testing.expectEqual(.attached, callback.kind);
            try std.testing.expectEqualStrings(entry.default_profile_source, callback.binding);
            try std.testing.expectEqual(doc.layers.len, callback.required_layers.len);
            try std.testing.expectEqual(doc.layers.len, callback.index_constraints.?.len);
            try std.testing.expectError(error.LayerReferenced, project.canDeleteLayer(doc, doc.layers[doc.layers.len - 1].id));
        }
        for (data.layers, doc.layers) |source, layer| for (source, layer.actions) |action, converted| {
            const expected: ?project.Action = if (action) |value| try project.adapter.liftAction(doc.layers, value) else null;
            try std.testing.expectEqualDeep(expected, converted);
        };
        try std.testing.expectEqual(data.combos.len, doc.combos.len);
        for (data.combos, doc.combos) |original, imported_combo| {
            try std.testing.expectEqualStrings(doc.key_ids[original.key_indexes[0]], imported_combo.key_ids[0]);
            try std.testing.expectEqualStrings(doc.key_ids[original.key_indexes[1]], imported_combo.key_ids[1]);
            try std.testing.expectEqual(doc.layers[original.layer].id, imported_combo.layer_id);
            try std.testing.expectEqualDeep(original.timeout, imported_combo.timeout);
            try std.testing.expectEqualDeep(try project.adapter.liftAction(doc.layers, original.key_def), imported_combo.action);
        }
        if (data.encoder_actions) |actions| for (actions, doc.encoders) |original, imported_encoder|
            try std.testing.expectEqualDeep(try project.adapter.liftTap(doc.layers, original.tap), imported_encoder);
        const generated = try project.exporter.generate(std.testing.allocator, imported.snapshot, board.board);
        defer std.testing.allocator.free(generated);
    }
}

test "all fourteen actual defaults save reopen and export deterministically without source loss" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectEqual(@as(usize, 14), catalog.entries.len);
    for (catalog.entries) |entry| {
        var board = try OwnedBoard.init(gpa, entry.selector);
        defer board.deinit();
        var original = try createDefault(gpa, board);
        defer original.deinit();
        var saved = std.testing.tmpDir(.{});
        defer saved.cleanup();
        try project.snapshot.save(gpa, io, saved.dir, original.snapshot, board.board);
        var reopened = try project.snapshot.load(gpa, io, saved.dir, board.board);
        defer reopened.deinit();
        try std.testing.expectEqual(@as(u32, 1), reopened.snapshot.document.schema_version);
        const before = try project.serialize(gpa, original.snapshot.document);
        defer gpa.free(before);
        const after = try project.serialize(gpa, reopened.snapshot.document);
        defer gpa.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        for (original.snapshot.sources, reopened.snapshot.sources) |source, restored| {
            try std.testing.expectEqualStrings(source.path, restored.path);
            try std.testing.expectEqualStrings(source.bytes, restored.bytes);
        }
        var first = std.testing.tmpDir(.{});
        defer first.cleanup();
        var second = std.testing.tmpDir(.{});
        defer second.cleanup();
        const manifest = try project.exporter.write(gpa, io, first.dir, original.snapshot, board.board);
        defer project.exporter.freeManifest(gpa, manifest);
        const repeated = try project.exporter.write(gpa, io, first.dir, reopened.snapshot, board.board);
        defer project.exporter.freeManifest(gpa, repeated);
        const other = try project.exporter.write(gpa, io, second.dir, reopened.snapshot, board.board);
        defer project.exporter.freeManifest(gpa, other);
        try std.testing.expectEqualDeep(manifest, other);
        for (manifest.files) |file| {
            const one = try first.dir.readFileAlloc(io, file.path, gpa, .limited(project.Limits.source_bytes));
            defer gpa.free(one);
            const two = try second.dir.readFileAlloc(io, file.path, gpa, .limited(project.Limits.source_bytes));
            defer gpa.free(two);
            try std.testing.expectEqualSlices(u8, one, two);
        }
        for ([_][]const u8{"manifest.zon"}) |path| {
            const one = try first.dir.readFileAlloc(io, path, gpa, .limited(project.Limits.source_bytes));
            defer gpa.free(one);
            const two = try second.dir.readFileAlloc(io, path, gpa, .limited(project.Limits.source_bytes));
            defer gpa.free(two);
            try std.testing.expectEqualSlices(u8, one, two);
        }
        if (original.snapshot.sources.len > 0) {
            var missing = original.snapshot;
            missing.sources = missing.sources[0 .. missing.sources.len - 1];
            try std.testing.expectError(error.MissingSource, project.snapshot.validate(missing, board.board));
            if (original.snapshot.sources.len > 1)
                try std.testing.expectError(error.UnresolvedImport, project.sources.verify(gpa, missing));
            const exported = try std.fmt.allocPrint(gpa, "callback_0/{s}", .{original.snapshot.sources[0].path});
            defer gpa.free(exported);
            try first.dir.writeFile(io, .{ .sub_path = exported, .data = "different source" });
            try std.testing.expectError(error.ExportOwnershipConflict, project.exporter.write(gpa, io, first.dir, original.snapshot, board.board));
            // Corrupt an owned source without changing its recorded digest.
            @constCast(original.snapshot.sources[0].bytes)[0] ^= 1;
            try std.testing.expectError(error.SourceMismatch, project.snapshot.validate(original.snapshot, board.board));
        }
    }
}

test "callback ID inventory includes simultaneous tap hold one shot autofire and combo fields" {
    var used: [253]bool = @splat(false);
    collectAction(&used, .{ .tap_hold = .{ .tap = .{ .custom = 3, .one_shot = .{ .custom = 7 } }, .hold = .{ .custom = 11 }, .tapping_term = .{ .ms = 200 } } });
    collectAction(&used, .{ .tap_with_autofire = .{ .tap = .{ .custom = 9 }, .initial_delay = .{ .ms = 200 }, .repeat_interval = .{ .ms = 100 } } });
    collectAction(&used, .{ .hold_only = .{ .custom = 13 } });
    collectAction(&used, .{ .tap_only = .{ .custom = 253 } });
    collectTap(&used, .{ .custom = 254, .one_shot = .{ .custom = 255 } });
    for (used, 0..) |present, id| try std.testing.expectEqual(id == 3 or id == 7 or id == 9 or id == 11 or id == 13, present);
}

test "actual default sources outlive their board and independently owned peers" {
    var board = try OwnedBoard.init(std.testing.allocator, "keycaprio_us_intl_0_7");
    var first = createDefault(std.testing.allocator, board) catch |err| {
        board.deinit();
        return err;
    };
    defer first.deinit();
    var second = createDefault(std.testing.allocator, board) catch |err| {
        board.deinit();
        return err;
    };
    defer second.deinit();
    board.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.snapshot.sources.len);
    @constCast(first.snapshot.sources[0].bytes)[0] ^= 1;
    try std.testing.expectEqualStrings(catalog.defaultData("keycaprio_us_intl_0_7").?.callback_sources[0].bytes, second.snapshot.sources[0].bytes);
    try project.sources.verify(std.testing.allocator, second.snapshot);
}

test "all catalog selectors own validated independent synthetic projects" {
    var seen: [catalog.entries.len][8]u8 = undefined;
    for (catalog.entries, 0..) |entry, index| {
        var board = try OwnedBoard.init(std.testing.allocator, entry.selector);
        defer board.deinit();
        for (seen[0..index]) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, &board.board.id));
        seen[index] = board.board.id;
        try std.testing.expect(!board.uses_schematic_sides);
        try std.testing.expectEqualSlices(model.Side, entry.processing_sides, board.board.sides);
        var fixture = try createSynthetic(std.testing.allocator, board);
        defer fixture.deinit();
        const source = try project.exporter.generate(std.testing.allocator, fixture.snapshot, board.board);
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "pub const keymap") != null);
        try std.testing.expectEqual(entry.default_dimensions.key_count, fixture.snapshot.document.key_ids.len);
        try std.testing.expectEqual(entry.encoder_action_slots, fixture.snapshot.document.encoders.len);
        // A schema-1 round trip proves the adapter did not change the project API.
        const bytes = try project.serialize(std.testing.allocator, fixture.snapshot.document);
        defer std.testing.allocator.free(bytes);
        const parsed = try project.parse(std.testing.allocator, bytes, null);
        defer project.deinit(std.testing.allocator, parsed);
        try project.validate(parsed, board.board);
    }
    try std.testing.expectError(error.UnknownSelector, OwnedBoard.init(std.testing.allocator, "yak"));
}

test "synthetic snapshot remains owned after board descriptor is released" {
    var board = try OwnedBoard.init(std.testing.allocator, "dasbob");
    var board_alive = true;
    defer if (board_alive) board.deinit();
    var fixture = try createSynthetic(std.testing.allocator, board);
    defer fixture.deinit();
    const expected_id = board.board.id;
    const expected_key_count = board.board.key_ids.len;
    board.deinit();
    board_alive = false;
    try std.testing.expectEqual(expected_id, fixture.snapshot.document.board_id);
    try std.testing.expectEqual(expected_key_count, fixture.snapshot.document.key_ids.len);
    try std.testing.expectEqualStrings("catalog-index-v1:dasbob", fixture.snapshot.document.physical_layout);
    try std.testing.expectEqualStrings("key-0", fixture.snapshot.document.key_ids[0]);
    try std.testing.expectEqualStrings("Synthetic", fixture.snapshot.document.layers[0].name);
}
