//! Retained lossless typed action form state; opening never simplifies fields.
const std = @import("std");
const p = @import("project");

pub const Draft = struct {
    mode: usize = 0,
    tap: p.Tap = .{},
    hold: p.Hold = .{},
    term: u16 = 180,
    retro: bool = false,
    initial: u16 = 300,
    repeat: u16 = 50,

    pub fn validate(self: Draft) !void {
        if (self.mode > 5) return error.InvalidActionFormMode;
    }

    pub fn from(value: ?p.Action) Draft {
        const a = value orelse return .{};
        return switch (a) {
            .none => .{ .mode = 1 },
            .tap_only => |t| .{ .mode = 2, .tap = t },
            .hold_only => |h| .{ .mode = 3, .hold = h },
            .tap_hold => |th| .{
                .mode = 4,
                .tap = th.tap,
                .hold = th.hold,
                .term = th.tapping_term.ms,
                .retro = th.retro_tapping,
            },
            .tap_with_autofire => |af| .{
                .mode = 5,
                .tap = af.tap,
                .initial = af.initial_delay.ms,
                .repeat = af.repeat_interval.ms,
            },
        };
    }

    pub fn action(self: Draft) ?p.Action {
        return switch (self.mode) {
            0 => null,
            1 => .none,
            2 => .{ .tap_only = self.tap },
            3 => .{ .hold_only = self.hold },
            4 => .{ .tap_hold = .{
                .tap = self.tap,
                .hold = self.hold,
                .tapping_term = .{ .ms = self.term },
                .retro_tapping = self.retro,
            } },
            5 => .{ .tap_with_autofire = .{
                .tap = self.tap,
                .initial_delay = .{ .ms = self.initial },
                .repeat_interval = .{ .ms = self.repeat },
            } },
            else => unreachable,
        };
    }

    pub fn homeRowMod(self: *Draft, bits: u8) void {
        self.mode = 4;
        self.hold.hold_modifiers = @bitCast(bits);
    }
};

/// Owns the selection and captured document identity of one explicit drawer.
/// Model remains caller-owned; field changes are isolated until deliberate Apply.
pub const Session = struct {
    pub const Status = enum { current, applied, stale_document, stale_selection };
    allocator: std.mem.Allocator,
    snapshot: [32]u8,
    layer_id: p.LayerId,
    primary: usize,
    selected: []bool,
    initial: Draft,
    draft: Draft,
    applied: bool = false,

    pub fn begin(allocator: std.mem.Allocator, model: anytype) !Session {
        const doc = model.document();
        if (model.primary >= model.selected.len or
            !model.selected[model.primary] or
            model.layer >= doc.layers.len) return error.NoActionFormSelection;
        const snapshot = try model.id();
        const selected = try allocator.dupe(bool, model.selected);
        const draft = Draft.from(model.action());
        return .{
            .allocator = allocator,
            .snapshot = snapshot,
            .layer_id = doc.layers[model.layer].id,
            .primary = model.primary,
            .selected = selected,
            .initial = draft,
            .draft = draft,
        };
    }

    pub fn apply(self: *Session, model: anytype) !bool {
        if (self.applied) return error.ActionFormAlreadyApplied;
        try self.draft.validate();
        const actual = try model.id();
        if (!std.mem.eql(u8, &actual, &self.snapshot)) return error.StaleSession;
        if (model.primary != self.primary or
            !std.mem.eql(bool, model.selected, self.selected) or
            model.layer >= model.document().layers.len or
            model.document().layers[model.layer].id != self.layer_id) return error.StaleActionFormSelection;
        const action = self.draft.action();
        if (std.meta.eql(action, self.initial.action())) return false;
        if (self.selected.len > p.Limits.keys) return error.InvalidDimensions;
        const values: [p.Limits.keys]?p.Action = @splat(action);
        try model.applyBatch(self.snapshot, self.layer_id, self.selected, values[0..self.selected.len]);
        self.applied = true;
        return true;
    }

    pub fn status(self: *const Session, model: anytype) !Status {
        if (self.applied) return .applied;
        const actual = try model.id();
        if (!std.mem.eql(u8, &actual, &self.snapshot)) return .stale_document;
        if (model.primary != self.primary or
            !std.mem.eql(bool, model.selected, self.selected) or
            model.layer >= model.document().layers.len or
            model.document().layers[model.layer].id != self.layer_id) return .stale_selection;
        return .current;
    }

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.selected);
        self.* = undefined;
    }
};

test "form representation preserves every simultaneous tap and hold field" {
    const action = p.Action{ .tap_hold = .{
        .tap = .{
            .key_press = .{ .tap_keycode = 8, .dead = true, .tap_modifiers = .{ .right_gui = true } },
            .custom = 1,
            .one_shot = .{ .layer_id = 3 },
            .media_key = .VolumeUp,
            .mouse_action = .WheelDown,
        },
        .hold = .{ .layer_id = 2, .custom = 2, .hold_modifiers = .{ .left_ctrl = true } },
        .tapping_term = .{ .ms = 231 },
        .retro_tapping = true,
    } };
    try std.testing.expectEqualDeep(@as(?p.Action, action), Draft.from(action).action());
}

test "home row mod shortcut preserves tap chord and timing" {
    var draft = Draft{ .mode = 2, .tap = .{ .key_press = .{
        .tap_keycode = 4,
        .tap_modifiers = .{ .right_alt = true },
    } }, .term = 231, .retro = true };
    const original = draft.tap;
    draft.homeRowMod(2);
    const action = draft.action().?.tap_hold;
    try std.testing.expectEqualDeep(original, action.tap);
    try std.testing.expect(action.hold.hold_modifiers.left_shift);
    try std.testing.expectEqual(@as(u16, 231), action.tapping_term.ms);
    try std.testing.expect(action.retro_tapping);
}

test "all action modes roundtrip including boundary timing and concurrent fields" {
    const tap = p.Tap{
        .key_press = .{ .tap_keycode = 252, .dead = true },
        .custom = 255,
        .media_key = .VolumeUp,
        .mouse_action = .WheelDown,
        .one_shot = .{ .layer_id = 15, .custom = 2, .hold_modifiers = .{ .right_alt = true } },
    };
    const hold = p.Hold{ .layer_id = 15, .custom = 3, .hold_modifiers = .{ .left_ctrl = true } };
    const actions = [_]?p.Action{
        null,
        .none,
        .{ .tap_only = tap },
        .{ .hold_only = hold },
        .{ .tap_hold = .{
            .tap = tap,
            .hold = hold,
            .tapping_term = .{ .ms = 65535 },
            .retro_tapping = true,
        } },
        .{ .tap_with_autofire = .{
            .tap = tap,
            .initial_delay = .{ .ms = 65535 },
            .repeat_interval = .{ .ms = 1 },
        } },
    };
    for (actions) |action| {
        const draft = Draft.from(action);
        try draft.validate();
        try std.testing.expectEqualDeep(action, draft.action());
    }
    try std.testing.expectError(error.InvalidActionFormMode, (Draft{ .mode = 6 }).validate());
}
