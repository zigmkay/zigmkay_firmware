//! Stable-key/layer combo drafts; explicit bound save/delete owns one commit.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
const Draft = @import("action_form.zig").Draft;
pub const Kind = enum { save, delete };

pub const Action = struct {
    snapshot: [32]u8,
    index: ?usize,
    keys: [2]usize,
    layer: usize,
    timeout: u16,
    draft: Draft,
    kind: Kind,
};

pub const Session = struct {
    snapshot: [32]u8,
    index: ?usize = null,
    keys: [2]usize = .{ 0, 1 },
    layer: usize = 0,
    timeout: u16 = 30,
    draft: Draft = .{ .mode = 2, .tap = .{ .key_press = .{ .tap_keycode = 4 } } },

    pub fn init(model: *const Model) !Session {
        if (model.document().key_ids.len < 2) return error.ComboNeedsTwoKeys;
        return .{ .snapshot = try model.id() };
    }

    pub fn fresh(self: Session, model: *const Model) !bool {
        const actual = try model.id();
        return std.mem.eql(u8, &actual, &self.snapshot);
    }

    pub fn pick(self: *Session, model: *const Model, index: usize) !void {
        if (!try self.fresh(model)) return error.StaleComboAction;
        const doc = model.document();
        if (index >= doc.combos.len) return error.InvalidCombo;
        const combo = doc.combos[index];
        var keys: [2]?usize = .{ null, null };
        for (doc.key_ids, 0..) |id, i| for (combo.key_ids, 0..) |key, slot| {
            if (std.mem.eql(u8, id, key)) keys[slot] = i;
        };
        var layer: ?usize = null;
        for (doc.layers, 0..) |entry, i| if (entry.id == combo.layer_id) {
            layer = i;
            break;
        };
        const first = keys[0] orelse return error.InvalidCombo;
        const second = keys[1] orelse return error.InvalidCombo;
        const layer_index = layer orelse return error.InvalidCombo;
        self.index = index;
        self.keys = .{ first, second };
        self.layer = layer_index;
        self.timeout = combo.timeout.ms;
        self.draft = Draft.from(combo.action);
    }

    pub fn new(self: *Session) void {
        self.index = null;
    }

    pub fn action(self: Session, kind: Kind) Action {
        return .{
            .snapshot = self.snapshot,
            .index = self.index,
            .keys = self.keys,
            .layer = self.layer,
            .timeout = self.timeout,
            .draft = self.draft,
            .kind = kind,
        };
    }

    pub fn dispatch(self: *Session, model: *Model, rendered: Action) !void {
        if (!std.meta.eql(rendered, self.action(rendered.kind)) or
            !try self.fresh(model)) return error.StaleComboAction;
        try self.draft.validate();
        const doc = model.document();
        if (self.index) |index| if (index >= doc.combos.len) return error.InvalidCombo;
        const count = switch (rendered.kind) {
            .save => doc.combos.len + @intFromBool(self.index == null),
            .delete => if (self.index != null) doc.combos.len - 1 else return error.InvalidCombo,
        };
        if (count > p.Limits.combos) return error.InvalidCombo;
        const combos = try model.gpa.alloc(p.Combo, count);
        defer model.gpa.free(combos);
        var next_index: ?usize = null;
        switch (rendered.kind) {
            .save => {
                if (self.layer >= doc.layers.len or
                    self.keys[0] >= doc.key_ids.len or
                    self.keys[1] >= doc.key_ids.len or
                    self.keys[0] == self.keys[1]) return error.InvalidCombo;
                @memcpy(combos[0..doc.combos.len], doc.combos);
                const index = self.index orelse doc.combos.len;
                combos[index] = .{
                    .key_ids = .{ doc.key_ids[self.keys[0]], doc.key_ids[self.keys[1]] },
                    .layer_id = doc.layers[self.layer].id,
                    .timeout = .{ .ms = self.timeout },
                    .action = self.draft.action() orelse return error.ComboCannotBeTransparent,
                };
                next_index = index;
            },
            .delete => {
                const index = self.index.?;
                @memcpy(combos[0..index], doc.combos[0..index]);
                @memcpy(combos[index..], doc.combos[index + 1 ..]);
            },
        }
        var snapshot = model.current.snapshot;
        snapshot.document.combos = combos;
        const next_digest = try p.snapshot.projectDigest(model.gpa, snapshot, model.board);
        try model.setCombos(combos);
        self.snapshot = next_digest;
        self.index = next_index;
    }
};
