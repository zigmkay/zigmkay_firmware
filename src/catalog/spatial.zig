//! Key placement of catalog boards. A board with a spatial layout (switch
//! positions measured from its PCB) is drawn as built; every other board is
//! drawn linearly in key-index order, without invented rows, splits or stagger.
const std = @import("std");
const model = @import("layout-model");
const Key = model.physical_layout.Key;

/// Spatial layouts by catalog selector. Each file lists every key of the
/// board's firmware key-index order once.
const layouts = [_]struct { []const u8, Layout }{
    .{ "molekula", @import("spatial/molekula.zon") },
};

/// One switch as exported by the PCB tool: centre in millimetres with y up,
/// rotation in degrees counterclockwise.
pub const Switch = struct {
    key_index: u8,
    designator: []const u8,
    x: f32,
    y: f32,
    rotation: f32 = 0,
    hand: model.physical_layout.Hand,
    group: model.physical_layout.Group = .finger,
    home_row: bool = false,
};

pub const Layout = struct {
    /// Hardware the positions were measured on.
    board: []const u8,
    /// Horizontal and vertical switch pitch in millimetres; one key unit is
    /// the horizontal pitch and a key fills one pitch cell.
    pitch: [2]f32,
    keys: []const Switch,
};

/// Keys in index order, ten per row. Hands come from the firmware's
/// processing sides when it declares them, otherwise they stay neutral.
pub fn linear(comptime count: usize, comptime sides: []const model.Side) [count]Key {
    var keys: [count]Key = undefined;
    for (&keys, 0..) |*key, index| key.* = .{
        .id = @intCast(index),
        .key_index = @intCast(index),
        .x = @floatFromInt(index % 10),
        .y = @floatFromInt(index / 10),
        .hand = if (sides.len != count) .neutral else switch (sides[index]) {
            .L => .left,
            .R => .right,
            .X => .neutral,
        },
    };
    return keys;
}

/// The spatial layout of `selector`, if one exists.
pub fn find(comptime selector: []const u8) ?Layout {
    inline for (layouts) |entry| {
        if (comptime std.mem.eql(u8, entry[0], selector)) return entry[1];
    }
    return null;
}

/// Converts PCB coordinates into key units with y down and rotation
/// clockwise, as drawn on screen. Keys keep their index as ID, like every
/// catalog board.
pub fn place(comptime layout: Layout, comptime count: usize) [count]Key {
    if (layout.keys.len != count) @compileError("Spatial layout key count differs from the firmware keymap");
    const unit = layout.pitch[0];
    const height = layout.pitch[1] / unit;
    var result: [count]Key = undefined;
    var seen: [count]bool = @splat(false);
    for (layout.keys) |item| {
        if (item.key_index >= count or seen[item.key_index]) @compileError("Spatial layout repeats or exceeds a key index");
        seen[item.key_index] = true;
        result[item.key_index] = .{
            .id = item.key_index,
            .key_index = item.key_index,
            .x = item.x / unit - 0.5,
            .y = -item.y / unit - height / 2,
            .height = height,
            .rotation = -item.rotation,
            .hand = item.hand,
            .group = item.group,
            .home_row = item.home_row,
        };
    }
    return result;
}

test "the Molekula layout places every firmware key at its PCB position" {
    const molekula = comptime find("molekula").?;
    const placed = comptime place(molekula, 38);
    try model.physical_layout.validateKeys(&placed, .{ .key_count = 38, .layer_count = 1 });
    // SW1 (Q) and SW23 (P) mirror each other; the middle fingers sit highest.
    try std.testing.expectApproxEqAbs(-placed[9].x - 1, placed[0].x, 0.001);
    try std.testing.expect(placed[2].y < placed[0].y and placed[2].y < placed[4].y);
    // The outer home-row keys lie left and right of the letter columns.
    try std.testing.expect(placed[10].x < placed[11].x and placed[21].x > placed[20].x);
    // The innermost thumbs turn towards the centre, clockwise on the left.
    try std.testing.expectEqual(@as(f32, 20), placed[34].rotation);
    try std.testing.expectEqual(@as(f32, -20), placed[35].rotation);
    try std.testing.expectEqual(model.physical_layout.Group.thumb, placed[32].group);
    for (placed[0..10]) |key| try std.testing.expect(!key.home_row);
    for (placed[10..22]) |key| try std.testing.expect(key.home_row);
}

test "boards without a spatial layout are drawn linearly" {
    try std.testing.expect(find("dasbob") == null);
    const placed = comptime linear(12, &.{ .L, .L, .L, .L, .L, .L, .R, .R, .R, .R, .R, .R });
    try std.testing.expectEqual(@as(f32, 9), placed[9].x);
    try std.testing.expectEqual(@as(f32, 0), placed[10].x);
    try std.testing.expectEqual(@as(f32, 1), placed[11].y);
    try std.testing.expectEqual(model.physical_layout.Hand.right, placed[11].hand);
    try std.testing.expectEqual(model.physical_layout.Hand.neutral, linear(2, &.{})[0].hand);
}
