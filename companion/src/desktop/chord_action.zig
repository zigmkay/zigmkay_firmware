//! Captured host-palette click/drag assignment. No runner or native input effects.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
const Chord = @import("assignment.zig").Chord;

pub fn selectionDigest(model: *const Model) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (model.selected) |selected| hash.update(&.{@intFromBool(selected)});
    var primary: [8]u8 = undefined;
    std.mem.writeInt(u64, &primary, model.primary, .little);
    hash.update(&primary);
    return hash.finalResult();
}

pub const Action = struct {
    snapshot: [32]u8,
    layer: p.LayerId,
    selected: [32]u8,
    chord: Chord,
    held: bool = false,
    target: ?usize = null,

    pub fn capture(model: *const Model, chord: Chord) !Action {
        return .{
            .snapshot = try model.id(),
            .layer = model.document().layers[model.layer].id,
            .selected = selectionDigest(model),
            .chord = chord,
        };
    }

    pub fn validate(self: Action, model: *const Model) !void {
        if (!std.mem.eql(u8, &self.snapshot, &(try model.id())) or
            self.layer != model.document().layers[model.layer].id or
            !std.mem.eql(u8, &self.selected, &selectionDigest(model))) return error.StaleChordAction;
        if (self.target) |target| if (target >= model.document().key_ids.len) return error.InvalidKey;
    }

    pub fn drop(self: Action, model: *const Model, target: ?usize, held: bool) !Action {
        var result = self;
        result.target = target;
        result.held = held;
        try result.validate(model);
        return result;
    }

    pub fn dispatch(self: Action, model: *Model) !void {
        try self.validate(model);
        try model.assignChord(self.chord, self.held, self.target);
    }
};
