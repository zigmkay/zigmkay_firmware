//! Selection captures processing index against immutable document and selection.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
const chord = @import("chord_action.zig");

pub const Action = struct {
    snapshot: [32]u8,
    layer: p.LayerId,
    selected: [32]u8,
    index: usize,
    extend: bool,

    pub fn capture(model: *const Model, index: usize, extend: bool) !Action {
        if (index >= model.document().key_ids.len) return error.InvalidKey;
        return .{
            .snapshot = try model.id(),
            .layer = model.document().layers[model.layer].id,
            .selected = chord.selectionDigest(model),
            .index = index,
            .extend = extend,
        };
    }

    pub fn validate(self: Action, model: *const Model) !void {
        if (!std.mem.eql(u8, &self.snapshot, &(try model.id())) or
            self.layer != model.document().layers[model.layer].id or
            !std.mem.eql(u8, &self.selected, &chord.selectionDigest(model))) return error.StaleKeySelection;
        if (self.index >= model.document().key_ids.len) return error.InvalidKey;
    }

    pub fn dispatch(self: Action, model: *Model) !void {
        try self.validate(model);
        model.select(self.index, self.extend);
    }
};
