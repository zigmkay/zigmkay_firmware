//! Inspector drafts never mutate the document until one validated batch commit.
const std = @import("std");
const p = @import("project");
const types = @import("layout-model");
const Model = @import("model.zig").Model;
pub const Mode = enum { tap, hold, tap_hold, repeat };
pub const ModifierTarget = enum { tap, hold, one_shot };
pub const MixedBool = enum { off, on, mixed };

pub const Operation = union(enum) {
    tap_key: ?types.KeyCodeFire,
    tap_usage: u8,
    tap_dead: bool,
    tap_one_shot: ?p.Hold,
    one_shot_layer: ?p.LayerId,
    one_shot_custom: ?u8,
    tap_custom: ?u8,
    tap_media: ?types.MediaCode,
    tap_mouse: ?types.MouseAction,
    hold_layer: ?p.LayerId,
    hold_custom: ?u8,
    hold_modifiers: types.Modifiers,
    tap_modifiers: types.Modifiers,
    clear_tap,
    clear_hold,
    unassign,
    inherit,
    replace: ?p.Action,
    mode: Mode,
    tapping_term: u16,
    retro_tapping: bool,
    initial_delay: u16,
    repeat_interval: u16,
};

pub fn tapPart(action: ?p.Action) p.Tap {
    return if (action) |a| switch (a) {
        .tap_only => |t| t,
        .tap_hold => |t| t.tap,
        .tap_with_autofire => |t| t.tap,
        else => .{},
    } else .{};
}

pub fn holdPart(action: ?p.Action) p.Hold {
    return if (action) |a| switch (a) {
        .hold_only => |h| h,
        .tap_hold => |t| t.hold,
        else => .{},
    } else .{};
}

pub fn tapEmpty(t: p.Tap) bool {
    return t.key_press == null and
        t.one_shot == null and
        t.custom == null and
        t.media_key == null and
        t.mouse_action == null;
}

pub fn holdEmpty(h: p.Hold) bool {
    return h.hold_modifiers.toByte() == 0 and h.layer_id == null and h.custom == null;
}

fn equal(a: ?p.Action, b: ?p.Action) bool {
    return std.meta.eql(a, b);
}

const TapHold = @FieldType(p.Action, "tap_hold");
const Autofire = @FieldType(p.Action, "tap_with_autofire");
const TimeSpan = @FieldType(TapHold, "tapping_term");
const default_tapping_term: TimeSpan = .{ .ms = 180 };
const default_initial_delay: TimeSpan = .{ .ms = 180 };
const default_repeat_interval: TimeSpan = .{ .ms = 50 };

fn asTapHold(action: ?p.Action) ?TapHold {
    const value = action orelse return null;
    return if (value == .tap_hold) value.tap_hold else null;
}

fn asAutofire(action: ?p.Action) ?Autofire {
    const value = action orelse return null;
    return if (value == .tap_with_autofire) value.tap_with_autofire else null;
}

/// Builds the action for the edited parts, keeping the timing of `original`.
fn compose(original: ?p.Action, tap: p.Tap, hold: p.Hold) p.Action {
    if (tapEmpty(tap)) return if (holdEmpty(hold)) .none else .{ .hold_only = hold };
    if (holdEmpty(hold)) {
        if (asAutofire(original)) |autofire| {
            return .{ .tap_with_autofire = .{
                .tap = tap,
                .initial_delay = autofire.initial_delay,
                .repeat_interval = autofire.repeat_interval,
            } };
        }
        return .{ .tap_only = tap };
    }
    return .{ .tap_hold = tapHold(original, tap, hold) };
}

fn tapHold(original: ?p.Action, tap: p.Tap, hold: p.Hold) TapHold {
    const previous = asTapHold(original);
    return .{
        .tap = tap,
        .hold = hold,
        .tapping_term = if (previous) |value| value.tapping_term else default_tapping_term,
        .retro_tapping = if (previous) |value| value.retro_tapping else false,
    };
}

/// Converts `old` to the requested mode, keeping its parts and timing.
fn withMode(old: ?p.Action, mode: Mode) p.Action {
    const tap = tapPart(old);
    const previous = asAutofire(old);
    return switch (mode) {
        .tap => .{ .tap_only = tap },
        .hold => .{ .hold_only = holdPart(old) },
        .tap_hold => .{ .tap_hold = tapHold(old, tap, holdPart(old)) },
        .repeat => .{ .tap_with_autofire = .{
            .tap = tap,
            .initial_delay = if (previous) |value| value.initial_delay else default_initial_delay,
            .repeat_interval = if (previous) |value| value.repeat_interval else default_repeat_interval,
        } },
    };
}

/// Applies a timing operation; actions without that timing stay unchanged.
fn withTiming(action: p.Action, op: Operation) p.Action {
    var result = action;
    switch (op) {
        .tapping_term => |v| if (result == .tap_hold) {
            result.tap_hold.tapping_term = .{ .ms = v };
        },
        .retro_tapping => |v| if (result == .tap_hold) {
            result.tap_hold.retro_tapping = v;
        },
        .initial_delay => |v| if (result == .tap_with_autofire) {
            result.tap_with_autofire.initial_delay = .{ .ms = v };
        },
        .repeat_interval => |v| if (result == .tap_with_autofire) {
            result.tap_with_autofire.repeat_interval = .{ .ms = v };
        },
        else => unreachable,
    }
    return result;
}

/// Applies an operation that edits the tap or hold part of an action.
fn editParts(t: *p.Tap, h: *p.Hold, op: Operation) void {
    switch (op) {
        .tap_key => |v| t.key_press = v,
        .tap_usage => |v| {
            var key = t.key_press orelse types.KeyCodeFire{};
            key.tap_keycode = v;
            t.key_press = key;
        },
        .tap_dead => |v| {
            var key = t.key_press orelse types.KeyCodeFire{};
            key.dead = v;
            t.key_press = key;
        },
        .tap_one_shot => |v| t.one_shot = v,
        .one_shot_layer => |v| {
            var one = t.one_shot orelse p.Hold{};
            one.layer_id = v;
            t.one_shot = if (holdEmpty(one)) null else one;
        },
        .one_shot_custom => |v| {
            var one = t.one_shot orelse p.Hold{};
            one.custom = v;
            t.one_shot = if (holdEmpty(one)) null else one;
        },
        .tap_custom => |v| t.custom = v,
        .tap_media => |v| t.media_key = v,
        .tap_mouse => |v| t.mouse_action = v,
        .hold_layer => |v| h.layer_id = v,
        .hold_custom => |v| h.custom = v,
        .hold_modifiers => |v| h.hold_modifiers = v,
        .tap_modifiers => |v| {
            var key = t.key_press orelse types.KeyCodeFire{};
            key.tap_modifiers = v;
            t.key_press = if (key.tap_keycode == 0 and v.toByte() == 0) null else key;
        },
        .clear_tap => t.* = .{},
        .clear_hold => h.* = .{},
        .unassign,
        .inherit,
        .replace,
        .mode,
        .tapping_term,
        .retro_tapping,
        .initial_delay,
        .repeat_interval,
        => unreachable,
    }
}

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    starting_id: [32]u8,
    layer_id: p.LayerId,
    layer_index: usize,
    selected: []bool,
    primary: usize,
    originals: []?p.Action,
    drafts: []?p.Action,
    resolved: []?p.Action,
    source_layers: []?p.LayerId,
    lower_resolved: []?p.Action,
    lower_sources: []?p.LayerId,
    key_lengths: []usize,
    // Key IDs are copied into bounded storage so document replacement cannot dangle them.
    key_storage: [][]u8,

    pub fn init(model: *const Model) !Session {
        var result: Session = undefined;
        const count = model.document().key_ids.len;
        if (count == 0 or
            count > p.Limits.keys or
            model.primary >= count or
            model.layer >= model.document().layers.len) return error.InvalidDimensions;
        result.arena = std.heap.ArenaAllocator.init(model.gpa);
        errdefer result.arena.deinit();
        const a = result.arena.allocator();
        result.originals = try a.alloc(?p.Action, count);
        result.drafts = try a.alloc(?p.Action, count);
        result.resolved = try a.alloc(?p.Action, count);
        result.source_layers = try a.alloc(?p.LayerId, count);
        result.lower_resolved = try a.alloc(?p.Action, count);
        result.lower_sources = try a.alloc(?p.LayerId, count);
        result.key_lengths = try a.alloc(usize, count);
        result.key_storage = try a.alloc([]u8, count);
        result.starting_id = try model.id();
        result.layer_id = model.document().layers[model.layer].id;
        result.layer_index = model.layer;
        result.selected = try a.dupe(bool, model.selected);
        result.primary = model.primary;
        for (model.document().key_ids, 0..) |id, index| {
            if (id.len > 240) return error.KeyIdTooLong;
            result.key_storage[index] = try a.dupe(u8, id);
            result.key_lengths[index] = id.len;
            const original = model.document().layers[model.layer].actions[index];
            result.originals[index] = original;
            result.drafts[index] = original;
            result.resolved[index] = original;
            result.source_layers[index] = if (original != null) result.layer_id else null;
            result.lower_resolved[index] = null;
            result.lower_sources[index] = null;
            var lower = model.layer;
            while (result.lower_resolved[index] == null and lower > 0) {
                lower -= 1;
                result.lower_resolved[index] = model.document().layers[lower].actions[index];
                if (result.lower_resolved[index] != null)
                    result.lower_sources[index] = model.document().layers[lower].id;
            }
            if (original == null) {
                result.resolved[index] = result.lower_resolved[index];
                result.source_layers[index] = result.lower_sources[index];
            }
        }
        return result;
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn first(self: *const Session) ?p.Action {
        return self.drafts[self.primary];
    }

    pub fn dirty(self: *const Session) bool {
        for (self.selected, self.originals, self.drafts) |selected, a, b| if (selected and !equal(a, b)) return true;
        return false;
    }

    pub fn cancel(self: *Session) void {
        @memcpy(self.drafts, self.originals);
        for (self.originals, 0..) |original, i| {
            self.resolved[i] = original orelse self.lower_resolved[i];
            self.source_layers[i] = if (original != null) self.layer_id else self.lower_sources[i];
        }
    }

    pub fn stale(self: *const Session, model: *const Model) !bool {
        const id = try model.id();
        if (!std.mem.eql(u8, &id, &self.starting_id)) return true;
        if (model.primary != self.primary or
            model.layer != self.layer_index or
            !std.mem.eql(bool, model.selected, self.selected) or
            model.document().key_ids.len != self.key_storage.len) return true;
        for (model.document().key_ids, 0..) |key, i| {
            if (!std.mem.eql(u8, key, self.key_storage[i][0..self.key_lengths[i]])) return true;
        }
        return false;
    }

    pub fn apply(self: *Session, model: *Model) !bool {
        if (try self.stale(model)) return error.StaleSession;
        if (!self.dirty()) return false;
        if (self.layer_index == 0) {
            for (self.selected, self.drafts, self.originals) |selected, draft, original| {
                if (selected and draft == null and original != null) return error.BaseCannotInherit;
            }
        }
        var layers: [p.Limits.layers]p.Layer = undefined;
        const count = model.document().layers.len;
        @memcpy(layers[0..count], model.document().layers);
        const action_count = self.drafts.len;
        var actions: [p.Limits.keys]?p.Action = undefined;
        @memcpy(actions[0..action_count], layers[self.layer_index].actions);
        for (self.selected, self.drafts, actions[0..action_count]) |chosen, draft, *action| if (chosen) {
            action.* = draft;
        };
        layers[self.layer_index].actions = actions[0..action_count];
        var snapshot = model.current.snapshot;
        snapshot.document.layers = layers[0..count];
        const next_id = try p.snapshot.projectDigest(model.gpa, snapshot, model.board);
        try model.applyBatch(self.starting_id, self.layer_id, self.selected, self.drafts);
        self.starting_id = next_id;
        @memcpy(self.originals, model.document().layers[self.layer_index].actions);
        self.cancel();
        return true;
    }

    pub fn validate(self: *const Session, model: *const Model) !void {
        if (try self.stale(model)) return error.StaleSession;
        var layers: [p.Limits.layers]p.Layer = undefined;
        const count = model.document().layers.len;
        @memcpy(layers[0..count], model.document().layers);
        layers[self.layer_index].actions = self.drafts;
        var snapshot = model.current.snapshot;
        snapshot.document.layers = layers[0..count];
        try p.snapshot.validate(snapshot, model.board);
    }

    pub fn mutate(self: *Session, op: Operation) void {
        for (self.selected, 0..) |selected, i| {
            if (selected) self.mutateKey(i, op);
        }
    }

    fn mutateKey(self: *Session, i: usize, op: Operation) void {
        const old = self.drafts[i] orelse self.resolved[i];
        switch (op) {
            .unassign => self.drafts[i] = .none,
            .inherit => if (self.layer_index != 0) {
                self.drafts[i] = null;
                self.resolved[i] = self.lower_resolved[i];
                self.source_layers[i] = self.lower_sources[i];
            },
            .replace => |action| self.drafts[i] = action,
            .mode => |mode| self.drafts[i] = withMode(old, mode),
            .tapping_term, .retro_tapping, .initial_delay, .repeat_interval => {
                if (old) |action| self.drafts[i] = withTiming(action, op);
            },
            else => {
                var tap = tapPart(old);
                var hold = holdPart(old);
                editParts(&tap, &hold, op);
                self.drafts[i] = compose(old, tap, hold);
            },
        }
    }

    fn modifierBits(action: ?p.Action, target: ModifierTarget) u8 {
        return switch (target) {
            .tap => if (tapPart(action).key_press) |key| key.tap_modifiers.toByte() else 0,
            .hold => holdPart(action).hold_modifiers.toByte(),
            .one_shot => if (tapPart(action).one_shot) |h| h.hold_modifiers.toByte() else 0,
        };
    }

    pub fn modifierState(self: *const Session, target: ModifierTarget, bit: u3) MixedBool {
        var yes = false;
        var no = false;
        for (self.selected, 0..) |selected, i| if (selected) {
            if ((modifierBits(self.drafts[i] orelse self.resolved[i], target) & (@as(u8, 1) << bit)) != 0) yes = true else no = true;
        };
        return if (yes and no) .mixed else if (yes) .on else .off;
    }

    pub fn toggleModifier(self: *Session, target: ModifierTarget, bit: u3) void {
        const set = self.modifierState(target, bit) != .on;
        for (self.selected, 0..) |selected, i| {
            if (!selected) continue;
            const old = self.drafts[i] orelse self.resolved[i];
            var t = tapPart(old);
            var h = holdPart(old);
            var bits = modifierBits(old, target);
            const mask = @as(u8, 1) << bit;
            bits = if (set) bits | mask else bits & ~mask;
            switch (target) {
                .tap => {
                    var key = t.key_press orelse types.KeyCodeFire{};
                    key.tap_modifiers = @bitCast(bits);
                    t.key_press = if (key.tap_keycode == 0 and bits == 0) null else key;
                },
                .hold => h.hold_modifiers = @bitCast(bits),
                .one_shot => {
                    var shot = t.one_shot orelse p.Hold{};
                    shot.hold_modifiers = @bitCast(bits);
                    t.one_shot = if (holdEmpty(shot)) null else shot;
                },
            }
            self.drafts[i] = compose(old, t, h);
        }
    }
};

fn fixtureModel() !Model {
    var loaded = try p.profiles.create(std.testing.allocator, .eurkey);
    defer loaded.deinit();
    var model = try Model.init(std.testing.allocator, p.profiles.board, loaded.snapshot);
    model.select(10, false);
    return model;
}

test "inspector applies reserved companion hold signal while preserving tap" {
    var model = try fixtureModel();
    defer model.deinit();
    try model.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 43 } } });
    var session = try Session.init(&model);
    defer session.deinit();
    session.mutate(.{ .hold_custom = 255 });
    try std.testing.expect(try session.apply(&model));
    const action = session.first().?.tap_hold;
    try std.testing.expectEqual(@as(u8, 43), action.tap.key_press.?.tap_keycode);
    try std.testing.expectEqual(@as(?u8, 255), action.hold.custom);
}

test "session preserves compound components and clears each side explicitly" {
    var model = try fixtureModel();
    defer model.deinit();
    try @import("inspector_fixture.zig").setup(&model);
    const compound: p.Action = .{ .tap_hold = .{
        .tap = .{
            .key_press = .{ .tap_keycode = 4, .dead = true },
            .custom = 1,
            .media_key = .VolumeUp,
            .mouse_action = .LeftButton,
            .one_shot = .{ .layer_id = 2, .custom = 1, .hold_modifiers = .{ .right_alt = true } },
        },
        .hold = .{ .hold_modifiers = .{ .left_shift = true }, .layer_id = 2, .custom = 1 },
        .tapping_term = .{ .ms = 231 },
        .retro_tapping = true,
    } };
    try model.apply(compound);
    var session = try Session.init(&model);
    defer session.deinit();
    session.mutate(.{ .tap_media = null });
    try std.testing.expectEqualDeep(compound.tap_hold.hold, session.first().?.tap_hold.hold);
    try std.testing.expectEqualDeep(
        compound.tap_hold.tap.key_press,
        session.first().?.tap_hold.tap.key_press,
    );
    try std.testing.expectEqual(@as(u16, 231), session.first().?.tap_hold.tapping_term.ms);
    try std.testing.expectEqualDeep(compound.tap_hold.tap.one_shot, session.first().?.tap_hold.tap.one_shot);
    try std.testing.expectEqual(compound.tap_hold.tap.custom, session.first().?.tap_hold.tap.custom);
    session.mutate(.clear_hold);
    try std.testing.expect(session.first().? == .tap_only);
    session.cancel();
    session.mutate(.clear_tap);
    try std.testing.expectEqualDeep(compound.tap_hold.hold, session.first().?.hold_only);
    session.mutate(.clear_hold);
    try std.testing.expect(session.first().? == .none);
    session.cancel();
    try std.testing.expect(!session.dirty());
}

test "bulk mixed modifiers preserve independent taps and commit one undo entry" {
    var model = try fixtureModel();
    defer model.deinit();
    try model.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } });
    model.select(11, false);
    try model.apply(.{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = 22 } },
        .hold = .{ .hold_modifiers = .{ .left_gui = true, .right_shift = true } },
        .tapping_term = .{ .ms = 240 },
    } });
    model.select(10, true);
    const original = try model.id();
    const undo_count = model.undo_stack.items.len;
    var session = try Session.init(&model);
    defer session.deinit();
    try std.testing.expectEqual(MixedBool.mixed, session.modifierState(.hold, 3));
    session.toggleModifier(.hold, 3);
    try std.testing.expectEqual(MixedBool.on, session.modifierState(.hold, 3));
    try std.testing.expectEqual(@as(u8, 4), tapPart(session.drafts[10]).key_press.?.tap_keycode);
    try std.testing.expectEqual(@as(u8, 22), tapPart(session.drafts[11]).key_press.?.tap_keycode);
    try std.testing.expect(holdPart(session.drafts[11]).hold_modifiers.right_shift);
    try std.testing.expect(try session.apply(&model));
    try std.testing.expectEqual(undo_count + 1, model.undo_stack.items.len);
    const changed = try model.id();
    try std.testing.expect(!(try session.apply(&model)));
    try model.undo();
    try std.testing.expectEqual(original, try model.id());
    try model.redo();
    try std.testing.expectEqual(changed, try model.id());
}

test "inheritance previews stage local overrides while invalid and stale applies are atomic" {
    var model = try fixtureModel();
    defer model.deinit();
    try model.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } });
    model.layer = 1;
    try model.apply(null);
    var session = try Session.init(&model);
    defer session.deinit();
    try std.testing.expect(session.first() == null);
    try std.testing.expectEqual(@as(u8, 4), tapPart(session.resolved[10]).key_press.?.tap_keycode);
    session.mutate(.{ .hold_layer = 2 });
    try std.testing.expectEqual(@as(u8, 4), session.first().?.tap_hold.tap.key_press.?.tap_keycode);
    session.mutate(.{ .hold_layer = 999999 });
    const original = try model.id();
    const count = model.undo_stack.items.len;
    if (session.apply(&model)) |_| return error.ExpectedValidationFailure else |_| {}
    try std.testing.expectEqual(original, try model.id());
    try std.testing.expectEqual(count, model.undo_stack.items.len);
    session.cancel();
    session.mutate(.unassign);
    try std.testing.expect(session.first().? == .none);
    try std.testing.expect(try session.apply(&model));
    session.mutate(.inherit);
    try std.testing.expect(session.first() == null);
    try std.testing.expect(try session.apply(&model));
    session.mutate(.{ .tap_key = .{ .tap_keycode = 5 } });
    try model.rename("Changed underlying snapshot");
    try std.testing.expectError(error.StaleSession, session.apply(&model));
}

test "repeat conversions preserve tap fields and save reopen export identity" {
    var model = try fixtureModel();
    defer model.deinit();
    try @import("inspector_fixture.zig").setup(&model);
    const callback_bytes = try std.testing.allocator.dupe(u8, model.current.snapshot.sources[0].bytes);
    defer std.testing.allocator.free(callback_bytes);
    try model.apply(.{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = 252 }, .media_key = .VolumeUp },
        .hold = .{ .layer_id = 2 },
        .tapping_term = .{ .ms = 231 },
    } });
    var session = try Session.init(&model);
    defer session.deinit();
    session.mutate(.{ .mode = .repeat });
    try std.testing.expectEqual(
        @as(u8, 252),
        session.first().?.tap_with_autofire.tap.key_press.?.tap_keycode,
    );
    session.mutate(.{ .repeat_interval = 75 });
    try std.testing.expect(try session.apply(&model));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try model.save(std.testing.io, temporary.dir);
    const identity = try model.id();
    try model.apply(.none);
    try model.open(std.testing.io, temporary.dir);
    try std.testing.expectEqual(identity, try model.id());
    try std.testing.expectEqualStrings(callback_bytes, model.current.snapshot.sources[0].bytes);
    try std.testing.expectEqual(@as(u8, 1), model.document().callbacks[0].ids[0]);
    var exported = try temporary.dir.createDirPathOpen(std.testing.io, "export", .{});
    defer exported.close(std.testing.io);
    const manifest = try p.exporter.write(
        std.testing.allocator,
        std.testing.io,
        exported,
        model.current.snapshot,
        p.profiles.board,
    );
    defer p.owned_zon.free(std.testing.allocator, manifest);
    try std.testing.expectEqual(identity, manifest.snapshot_id);
}

test "bulk key and one-shot field edits retain each key's chord and callback" {
    var model = try fixtureModel();
    defer model.deinit();
    try @import("inspector_fixture.zig").setup(&model);
    try model.apply(.{ .tap_only = .{
        .key_press = .{ .tap_keycode = 4, .dead = true, .tap_modifiers = .{ .left_alt = true } },
        .one_shot = .{ .custom = 1, .hold_modifiers = .{ .left_gui = true } },
    } });
    model.select(11, false);
    try model.apply(.{ .tap_only = .{
        .key_press = .{ .tap_keycode = 22, .tap_modifiers = .{ .right_shift = true } },
        .one_shot = .{ .layer_id = 2, .hold_modifiers = .{ .right_alt = true } },
    } });
    model.select(10, true);
    var session = try Session.init(&model);
    defer session.deinit();
    session.mutate(.{ .tap_usage = 5 });
    session.mutate(.{ .one_shot_layer = 3 });
    try session.validate(&model);
    try std.testing.expect(try session.apply(&model));
    const first = model.document().layers[model.layer].actions[10].?.tap_only;
    const second = model.document().layers[model.layer].actions[11].?.tap_only;
    try std.testing.expect(first.key_press.?.dead);
    try std.testing.expect(!second.key_press.?.dead);
    try std.testing.expect(first.key_press.?.tap_modifiers.left_alt);
    try std.testing.expect(second.key_press.?.tap_modifiers.right_shift);
    try std.testing.expectEqual(@as(?u8, 1), first.one_shot.?.custom);
    try std.testing.expectEqual(@as(?u8, null), second.one_shot.?.custom);
    try std.testing.expect(first.one_shot.?.hold_modifiers.left_gui);
    try std.testing.expect(second.one_shot.?.hold_modifiers.right_alt);
    try std.testing.expectEqual(@as(?p.LayerId, 3), first.one_shot.?.layer_id);
    try std.testing.expectEqual(@as(?p.LayerId, 3), second.one_shot.?.layer_id);
}

test "inspector owns variable board keys and preserves independent chords" {
    const t = std.testing;
    var loaded = try p.profiles.create(t.allocator, .eurkey);
    defer loaded.deinit();
    var doc = loaded.snapshot.document;
    const board = p.Board{
        .id = "fixture\x00".*,
        .physical_layout = "explicit-fixture",
        .key_ids = &.{ "left", "right", "thumb" },
        .sides = &.{ .X, .X, .X },
    };
    doc.board_id = board.id;
    doc.physical_layout = board.physical_layout;
    doc.key_ids = board.key_ids;
    doc.combos = &.{};
    var layers: [p.Limits.layers]p.Layer = undefined;
    const count = doc.layers.len;
    for (layers[0..count], doc.layers) |*target, layer| {
        target.* = layer;
        target.actions = layer.actions[0..3];
    }
    doc.layers = layers[0..count];
    var model = try Model.init(t.allocator, board, .{ .document = doc, .sources = loaded.snapshot.sources });
    defer model.deinit();
    model.select(0, false);
    model.select(1, true);
    var session = try Session.init(&model);
    defer session.deinit();
    try t.expectEqual(@as(usize, 3), session.drafts.len);
    const left = tapPart(session.drafts[0]).key_press.?.tap_keycode;
    const right = tapPart(session.drafts[1]).key_press.?.tap_keycode;
    session.toggleModifier(.hold, 3);
    try session.validate(&model);
    try t.expect(try session.apply(&model));
    try t.expectEqual(left, tapPart(model.document().layers[0].actions[0]).key_press.?.tap_keycode);
    try t.expectEqual(right, tapPart(model.document().layers[0].actions[1]).key_press.?.tap_keycode);
    try t.expect(!session.dirty());
    model.select(2, false);
    session.mutate(.{ .tap_usage = 5 });
    try t.expectError(error.StaleSession, session.apply(&model));
    try t.expectEqualStrings("left", session.key_storage[0]);
}
