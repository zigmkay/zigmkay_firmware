//! Advisory static reachability. Callback metadata is a declaration, never proof of behavior.
const p = @import("root.zig");

pub const Result = struct {
    reachable: [p.Limits.layers]bool = @splat(false),
    recovery_found: bool = false,
    callbacks_require_review: bool = false,
};

fn visitHold(doc: p.Document, hold: p.Hold, result: *Result) !void {
    if (hold.layer_id) |id| result.reachable[try p.layerIndex(doc, id)] = true;
}

fn visitTap(doc: p.Document, tap: p.Tap, result: *Result) !void {
    if (tap.key_press) |key| {
        if (key.tap_keycode == 252) {
            result.recovery_found = true;
        }
    }
    if (tap.one_shot) |hold| try visitHold(doc, hold, result);
}

fn visit(doc: p.Document, action: p.Action, result: *Result) !void {
    switch (action) {
        .none => {},
        .tap_only => |tap| try visitTap(doc, tap, result),
        .hold_only => |hold| try visitHold(doc, hold, result),
        .tap_hold => |th| {
            try visitTap(doc, th.tap, result);
            try visitHold(doc, th.hold, result);
        },
        .tap_with_autofire => |fire| try visitTap(doc, fire.tap, result),
    }
}

pub fn assess(doc: p.Document) !Result {
    if (doc.layers.len == 0 or doc.layers.len > p.Limits.layers) return error.InvalidDimensions;
    var result = Result{ .callbacks_require_review = doc.callbacks.len != 0 };
    result.reachable[0] = true;
    for (0..doc.layers.len) |_| {
        for (doc.layers, 0..) |layer, index| {
            if (!result.reachable[index]) continue;
            for (layer.actions) |action| if (action) |value| {
                try visit(doc, value, &result);
            };
        }
        for (doc.combos) |combo| if (result.reachable[try p.layerIndex(doc, combo.layer_id)]) {
            try visit(doc, combo.action, &result);
        };
        for (doc.encoders) |tap| try visitTap(doc, tap, &result);
    }
    return result;
}

test "only declaratively reachable layers and recovery are claimed" {
    const std = @import("std");
    var project = try p.profiles.create(std.testing.allocator, .eurkey);
    defer project.deinit();
    const result = try assess(project.snapshot.document);
    try std.testing.expect(result.reachable[0] and result.reachable[1] and result.reachable[2]);
    try std.testing.expect(!result.reachable[4]);
    try std.testing.expect(result.recovery_found);
}
