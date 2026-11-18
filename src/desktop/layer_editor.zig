//! Explicit layer operations bind stable IDs and the rendered document/selection.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
pub const Kind = enum { select, add, duplicate, delete, rename };

pub const Action = struct {
    snapshot: [32]u8,
    selected: p.LayerId,
    target: p.LayerId,
    kind: Kind,
    name: [129]u8 = @splat(0),
};

pub fn capture(model: *const Model, kind: Kind, target: p.LayerId, name: []const u8) !Action {
    if (name.len > 128 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidLayerName;
    var result = Action{
        .snapshot = try model.id(),
        .selected = model.document().layers[model.layer].id,
        .target = target,
        .kind = kind,
    };
    @memcpy(result.name[0..name.len], name);
    return result;
}

pub fn dispatch(model: *Model, action: Action) !void {
    if (!std.mem.eql(u8, &action.snapshot, &(try model.id())) or
        action.selected != model.document().layers[model.layer].id) return error.StaleLayerAction;
    var index: ?usize = null;
    for (model.document().layers, 0..) |layer, i| if (layer.id == action.target) {
        index = i;
        break;
    };
    const target = index orelse return error.InvalidLayer;
    switch (action.kind) {
        .select => model.layer = target,
        .add => try model.addLayer(false),
        .delete => try model.deleteLayer(target),
        .duplicate, .rename => {
            const previous = model.layer;
            model.layer = target;
            errdefer model.layer = previous;
            if (action.kind == .duplicate) try model.addLayer(true) else {
                try model.rename(std.mem.sliceTo(&action.name, 0));
                model.layer = previous;
            }
        },
    }
}
