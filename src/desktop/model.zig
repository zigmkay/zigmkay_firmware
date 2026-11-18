//! UI-thread document ownership and bounded snapshot history. Each edit commits
//! one validated immutable snapshot; refused edits leave history and dirty state intact.
const std = @import("std");
const p = @import("project");

pub const Model = struct {
    gpa: std.mem.Allocator,
    board_arena: std.heap.ArenaAllocator,
    board: p.Board,
    current: p.snapshot.Loaded,
    undo_stack: std.ArrayList(p.snapshot.Loaded) = .empty,
    redo_stack: std.ArrayList(p.snapshot.Loaded) = .empty,
    saved_id: [32]u8,
    layer: usize = 0,
    selected: []bool,
    primary: usize = 0,
    clipboard: ?p.Action = null,
    clipboard_set: bool = false,
    next_layer_id: p.LayerId = 100,

    pub fn init(gpa: std.mem.Allocator, board: p.Board, initial: p.snapshot.Snapshot) !Model {
        try p.snapshot.validate(initial, board);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var owned_board = board;
        owned_board.physical_layout = try a.dupe(u8, board.physical_layout);
        const ids = try a.alloc([]const u8, board.key_ids.len);
        for (board.key_ids, ids) |src, *dst| dst.* = try a.dupe(u8, src);
        owned_board.key_ids = ids;
        owned_board.sides = try a.dupe(@typeInfo(@TypeOf(board.sides)).pointer.child, board.sides);
        const selected = try a.alloc(bool, ids.len);
        @memset(selected, false);
        var loaded = try p.snapshot.clone(gpa, initial);
        errdefer loaded.deinit();
        var self = Model{
            .gpa = gpa,
            .board_arena = arena,
            .board = owned_board,
            .selected = selected,
            .current = loaded,
            .saved_id = try p.snapshot.projectDigest(gpa, loaded.snapshot, owned_board),
        };
        self.selected[self.primary] = true;
        return self;
    }

    pub fn deinit(self: *Model) void {
        self.current.deinit();
        self.clear(&self.undo_stack);
        self.clear(&self.redo_stack);
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.board_arena.deinit();
    }

    fn clear(_: *Model, stack: *std.ArrayList(p.snapshot.Loaded)) void {
        for (stack.items) |*loaded| loaded.deinit();
        stack.clearRetainingCapacity();
    }

    pub fn id(self: *const Model) ![32]u8 {
        return p.snapshot.projectDigest(self.gpa, self.current.snapshot, self.board);
    }

    pub fn dirty(self: *const Model) bool {
        const actual = self.id() catch return true;
        return !std.mem.eql(u8, &actual, &self.saved_id);
    }

    pub fn document(self: *const Model) p.Document {
        return self.current.snapshot.document;
    }

    pub fn action(self: *const Model) ?p.Action {
        return self.document().layers[self.layer].actions[self.primary];
    }

    pub fn select(self: *Model, index: usize, extend: bool) void {
        if (index >= self.selected.len) return;
        if (!extend) @memset(self.selected, false);
        self.selected[index] = if (extend) !self.selected[index] else true;
        self.primary = index;
    }

    pub fn commit(self: *Model, snapshot: p.snapshot.Snapshot) !void {
        try p.snapshot.validate(snapshot, self.board);
        // Editing preserves opaque historical callbacks; export/build performs
        // executable binding resolution separately from snapshot integrity.
        var next = try p.snapshot.clone(self.gpa, snapshot);
        errdefer next.deinit();
        const old_id = try self.id();
        const new_id = try p.snapshot.projectDigest(self.gpa, next.snapshot, self.board);
        if (std.mem.eql(u8, &old_id, &new_id)) {
            next.deinit();
            return;
        }
        try self.undo_stack.append(self.gpa, self.current);
        if (self.undo_stack.items.len > 32) {
            var removed = self.undo_stack.orderedRemove(0);
            removed.deinit();
        }
        self.current = next;
        self.clear(&self.redo_stack);
        self.layer = @min(self.layer, self.document().layers.len - 1);
    }

    pub fn undo(self: *Model) !void {
        if (self.undo_stack.items.len == 0) return;
        try self.redo_stack.append(self.gpa, self.current);
        self.current = self.undo_stack.pop().?;
        self.layer = @min(self.layer, self.document().layers.len - 1);
    }

    pub fn redo(self: *Model) !void {
        if (self.redo_stack.items.len == 0) return;
        try self.undo_stack.append(self.gpa, self.current);
        self.current = self.redo_stack.pop().?;
        self.layer = @min(self.layer, self.document().layers.len - 1);
    }

    pub fn apply(self: *Model, value: ?p.Action) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var snapshot = self.current.snapshot;
        const layers = try arena.allocator().dupe(p.Layer, self.document().layers);
        const actions = try arena.allocator().dupe(?p.Action, layers[self.layer].actions);
        for (self.selected, actions) |selected, *entry| if (selected) {
            entry.* = value;
        };
        layers[self.layer].actions = actions;
        snapshot.document.layers = layers;
        try self.commit(snapshot);
    }

    /// Commit independently patched assignments as one validated history entry.
    pub fn applyBatch(
        self: *Model,
        starting_id: [32]u8,
        layer_id: p.LayerId,
        selected: []const bool,
        values: []const ?p.Action,
    ) !void {
        const actual = try self.id();
        if (!std.mem.eql(u8, &actual, &starting_id)) return error.StaleSession;
        const doc = self.document();
        if (selected.len != doc.key_ids.len or values.len != selected.len) return error.InvalidDimensions;
        var index: ?usize = null;
        for (doc.layers, 0..) |layer, i| if (layer.id == layer_id) {
            index = i;
            break;
        };
        const layer_index = index orelse return error.InvalidLayer;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var snapshot = self.current.snapshot;
        const layers = try arena.allocator().dupe(p.Layer, doc.layers);
        const actions = try arena.allocator().dupe(?p.Action, layers[layer_index].actions);
        for (selected, values, actions) |chosen, value, *entry| if (chosen) {
            entry.* = value;
        };
        layers[layer_index].actions = actions;
        snapshot.document.layers = layers;
        try self.commit(snapshot);
    }

    pub fn copy(self: *Model) void {
        self.clipboard = self.action();
        self.clipboard_set = true;
    }

    pub fn assignChord(
        self: *Model,
        chord: @import("assignment.zig").Chord,
        held: bool,
        target: ?usize,
    ) !void {
        if (target) |key| {
            if (key >= self.selected.len) {
                return error.InvalidKey;
            }
        }
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var snapshot = self.current.snapshot;
        const layers = try arena.allocator().dupe(p.Layer, self.document().layers);
        const actions = try arena.allocator().dupe(?p.Action, layers[self.layer].actions);
        for (actions, 0..) |*entry, index| {
            if (if (target) |key| index != key else !self.selected[index]) continue;
            var resolved = entry.*;
            var layer_index = self.layer;
            while (resolved == null and layer_index > 0) {
                layer_index -= 1;
                resolved = layers[layer_index].actions[index];
            }
            entry.* = if (held) try @import("assignment.zig").hold(resolved, chord) else @import("assignment.zig").tap(resolved, chord);
        }
        layers[self.layer].actions = actions;
        snapshot.document.layers = layers;
        try self.commit(snapshot);
        if (target) |key| self.select(key, false);
    }

    pub fn paste(self: *Model) !void {
        if (self.clipboard_set) try self.apply(self.clipboard);
    }

    pub fn rename(self: *Model, name: []const u8) !void {
        var layers: [p.Limits.layers]p.Layer = undefined;
        const count = self.document().layers.len;
        @memcpy(layers[0..count], self.document().layers);
        layers[self.layer].name = name;
        var snapshot = self.current.snapshot;
        snapshot.document.layers = layers[0..count];
        try self.commit(snapshot);
    }

    /// Renames the layout itself, as one undoable edit.
    pub fn renameLayout(self: *Model, name: []const u8) !void {
        var snapshot = self.current.snapshot;
        snapshot.document.name = name;
        try self.commit(snapshot);
    }

    pub fn addLayer(self: *Model, duplicate: bool) !void {
        const doc = self.document();
        if (doc.layers.len == p.Limits.layers) return error.InvalidDimensions;
        var layers: [p.Limits.layers]p.Layer = undefined;
        @memcpy(layers[0..doc.layers.len], doc.layers);
        const empty = try self.gpa.alloc(?p.Action, doc.key_ids.len);
        defer self.gpa.free(empty);
        @memset(empty, null);
        var name_buffer: [128]u8 = undefined;
        const name = if (duplicate) try std.fmt.bufPrint(
            &name_buffer,
            "{s} copy",
            .{doc.layers[self.layer].name},
        ) else "New layer";
        while (true) {
            var used = false;
            for (doc.layers) |existing| if (existing.id == self.next_layer_id) {
                used = true;
                break;
            };
            if (!used) break;
            self.next_layer_id = std.math.add(
                p.LayerId,
                self.next_layer_id,
                1,
            ) catch return error.LayerIdExhausted;
        }
        layers[doc.layers.len] = .{
            .id = self.next_layer_id,
            .name = name,
            .actions = if (duplicate) doc.layers[self.layer].actions else empty,
        };
        var snapshot = self.current.snapshot;
        snapshot.document.layers = layers[0 .. doc.layers.len + 1];
        try self.commit(snapshot);
        self.next_layer_id +%= 1;
        self.layer = doc.layers.len;
    }

    pub fn deleteLayer(self: *Model, index: usize) !void {
        const doc = self.document();
        if (index >= doc.layers.len) return error.InvalidLayer;
        try p.canDeleteLayer(doc, doc.layers[index].id);
        var layers: [p.Limits.layers]p.Layer = undefined;
        @memcpy(layers[0..index], doc.layers[0..index]);
        @memcpy(layers[index .. doc.layers.len - 1], doc.layers[index + 1 ..]);
        var snapshot = self.current.snapshot;
        snapshot.document.layers = layers[0 .. doc.layers.len - 1];
        try self.commit(snapshot);
    }

    pub fn setCombos(self: *Model, combos: []const p.Combo) !void {
        var snapshot = self.current.snapshot;
        snapshot.document.combos = combos;
        try self.commit(snapshot);
    }

    pub fn setEncoders(self: *Model, encoders: []const p.Tap) !void {
        var snapshot = self.current.snapshot;
        snapshot.document.encoders = encoders;
        try self.commit(snapshot);
    }

    pub fn save(self: *Model, io: std.Io, dir: std.Io.Dir) !void {
        try p.snapshot.saveChecked(self.gpa, io, dir, self.current.snapshot, self.board, self.saved_id);
        self.saved_id = try self.id();
    }

    pub fn open(self: *Model, io: std.Io, dir: std.Io.Dir) !void {
        var loaded = try p.snapshot.load(self.gpa, io, dir, self.board);
        defer loaded.deinit();
        try self.commit(loaded.snapshot);
        self.saved_id = try self.id();
    }
};

test "bulk edits, metadata, constrained deletion and history survive save/reopen" {
    var initial = try p.profiles.create(std.testing.allocator, .eurkey);
    defer initial.deinit();
    var model = try Model.init(std.testing.allocator, p.profiles.board, initial.snapshot);
    defer model.deinit();
    model.select(10, false);
    const original = try model.id();
    model.select(11, true);
    try model.apply(.{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = 4, .dead = true } },
        .hold = .{ .layer_id = 2 },
        .tapping_term = .{ .ms = 180 },
        .retro_tapping = true,
    } });
    try std.testing.expect(model.dirty());
    try std.testing.expectEqual(
        model.document().layers[0].actions[10],
        model.document().layers[0].actions[11],
    );
    try model.undo();
    try std.testing.expectEqual(original, try model.id());
    try model.redo();
    try std.testing.expectError(error.LayerReferenced, model.deleteLayer(1));
    try model.addLayer(true);
    try model.rename("Copied draft");
    try model.deleteLayer(6);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try model.save(std.testing.io, temporary.dir);
    try std.testing.expect(!model.dirty());
    const saved = try model.id();
    try model.apply(.none);
    try model.open(std.testing.io, temporary.dir);
    try std.testing.expectEqual(saved, try model.id());
    try std.testing.expect(!model.dirty());
    var exported = try temporary.dir.createDirPathOpen(std.testing.io, "export", .{});
    defer exported.close(std.testing.io);
    const manifest = try p.exporter.write(
        std.testing.allocator,
        std.testing.io,
        exported,
        model.current.snapshot,
        p.profiles.board,
    );
    defer p.exporter.freeManifest(std.testing.allocator, manifest);
    try std.testing.expectEqual(saved, manifest.snapshot_id);
    const repeated = try p.exporter.write(
        std.testing.allocator,
        std.testing.io,
        exported,
        model.current.snapshot,
        p.profiles.board,
    );
    defer p.exporter.freeManifest(std.testing.allocator, repeated);
    try std.testing.expectEqualDeep(manifest, repeated);
}

test "imported stable layer IDs cannot collide with new layers" {
    var initial = try p.profiles.create(std.testing.allocator, .eurkey);
    defer initial.deinit();
    var model = try Model.init(std.testing.allocator, p.profiles.board, initial.snapshot);
    defer model.deinit();
    try model.addLayer(false);
    model.next_layer_id = 100;
    try model.addLayer(false);
    try std.testing.expectEqual(@as(p.LayerId, 101), model.document().layers[7].id);
    try model.undo();
    try model.redo();
    try p.validate(model.document(), p.profiles.board);
}

fn smallModel() !Model {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try a.alloc([]const u8, 3);
    for (keys, [_][]const u8{ "first", "middle", "last" }) |*key, text| key.* = try a.dupe(u8, text);
    const board: p.Board = .{
        .id = .{ 't', 'i', 'n', 'y', 0, 0, 0, 0 },
        .physical_layout = try a.dupe(u8, "three-key"),
        .key_ids = keys,
        .sides = &.{ .L, .X, .R },
    };
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = board.id,
        .profile_id = .{ 'f', 'i', 'x', 't', 'u', 'r', 'e', 0 },
        .physical_layout = board.physical_layout,
        .name = "Synthetic board",
        .key_ids = keys,
        .layers = &.{
            .{ .id = 1, .name = "Base", .actions = &.{ null, null, null } },
            .{ .id = 100, .name = "Second", .actions = &.{ null, null, null } },
        },
    };
    return Model.init(std.testing.allocator, board, .{ .document = doc, .sources = &.{} });
}

test "model owns arbitrary board lifetimes and validates bulk edits history and stable IDs" {
    const t = std.testing;
    var model = try smallModel();
    defer model.deinit();
    try t.expectEqual(@as(usize, 3), model.selected.len);
    try t.expectEqualStrings("last", model.board.key_ids[2]);
    try t.expectEqualStrings("three-key", model.board.physical_layout);
    try t.expectEqual(model.board.key_ids.len, model.document().key_ids.len);
    const original = try model.id();
    model.select(2, true);
    try model.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } });
    try t.expectEqual(model.document().layers[0].actions[0], model.document().layers[0].actions[2]);
    try t.expect(model.document().layers[0].actions[1] == null);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    const edited = try model.id();
    try model.apply(model.action());
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try t.expectError(error.InvalidLayer, model.apply(.{ .hold_only = .{ .layer_id = 999 } }));
    try t.expectEqual(edited, try model.id());
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try t.expectError(
        error.StaleSession,
        model.applyBatch(original, 1, &.{ true, false, false }, &.{ null, null, null }),
    );
    try t.expectError(error.InvalidDimensions, model.applyBatch(edited, 1, &.{true}, &.{null}));
    try t.expectError(error.InvalidKey, model.assignChord(.{ .tap_keycode = 4 }, false, 3));
    try model.undo();
    try t.expectEqual(original, try model.id());
    try model.redo();
    try t.expectEqual(edited, try model.id());
    try model.undo();
    try model.rename("A new branch");
    try t.expectEqual(@as(usize, 0), model.redo_stack.items.len);
    try model.addLayer(false);
    try t.expectEqual(@as(p.LayerId, 101), model.document().layers[2].id);
    try t.expectEqual(@as(usize, 3), model.document().layers[2].actions.len);
    for (model.document().layers[2].actions) |action_value| try t.expect(action_value == null);
    try model.apply(.{ .hold_only = .{ .layer_id = 100 } });
    try t.expectError(error.LayerReferenced, model.deleteLayer(1));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try model.save(t.io, tmp.dir);
    try t.expect(!model.dirty());
    const saved = try model.id();
    try model.rename("Changed");
    try model.open(t.io, tmp.dir);
    try t.expectEqual(saved, try model.id());
    try t.expect(!model.dirty());
    for (0..40) |i| {
        var name: [32]u8 = undefined;
        try model.rename(try std.fmt.bufPrint(&name, "History {d}", .{i}));
    }
    try t.expectEqual(@as(usize, 32), model.undo_stack.items.len);
}

test "unknown historical callbacks remain editable and saved byte-exact but cannot export" {
    const t = std.testing;
    var initial = try p.profiles.create(t.allocator, .danish);
    defer initial.deinit();
    const bytes = "// preserved historical callback; compiler unknown\n";
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    var callback = initial.snapshot.document.callbacks[0];
    callback.binding = "rollercole_v1";
    callback.sources = &.{.{ .path = "rollercole.zig", .digest = hash }};
    var doc = initial.snapshot.document;
    doc.callbacks = &.{callback};
    var model = try Model.init(t.allocator, p.profiles.board, .{ .document = doc, .sources = &.{.{
        .callback_index = 0,
        .path = "rollercole.zig",
        .bytes = bytes,
    }} });
    defer model.deinit();
    try model.rename("Historical metadata edit");
    try model.undo();
    try model.redo();
    try t.expectEqualStrings(bytes, try p.snapshot.find(model.current.snapshot, 0, "rollercole.zig"));
    try t.expectError(error.LayerReferenced, model.deleteLayer(1));
    try t.expectError(
        error.UnknownRegisteredCallback,
        p.exporter.generate(t.allocator, model.current.snapshot, model.board),
    );
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try model.save(t.io, tmp.dir);
    try model.rename("Another edit");
    try model.open(t.io, tmp.dir);
    try t.expectEqualStrings(bytes, try p.snapshot.find(model.current.snapshot, 0, "rollercole.zig"));
    try t.expectEqualStrings("rollercole_v1", model.document().callbacks[0].binding);
    try t.expect(!model.dirty());
}
