//! Key placement of catalog boards. A board with a schematic layout is drawn
//! from its PCB, made easy to read: finger keys stand upright on a grid with
//! one key between columns and rows and keep the column stagger of the PCB in
//! quarter keys. One thumb key per hand stands upright as a reference; the
//! others fan out from it, each at most 10 degrees further. Revisions that
//! differ by a few millimetres share one layout. Every other board is drawn
//! linearly in key-index order, without invented rows, splits or stagger.
const std = @import("std");
const model = @import("layout-model");
const Key = model.physical_layout.Key;
const KeyId = model.physical_layout.KeyId;

/// One key in key units: top-left corner with y down, rotation in degrees
/// clockwise about the key centre.
pub const Item = struct {
    key_index: u8,
    x: f32,
    y: f32,
    rotation: f32 = 0,
    hand: model.physical_layout.Hand,
    group: model.physical_layout.Group = .finger,
    home_row: bool = false,
};

/// Every key of a board, each firmware key index once.
pub const Layout = []const Item;

const keycaprio_30: Layout = @import("schematic/keycaprio_30.zon");
const keycaprio_34: Layout = @import("schematic/keycaprio_34.zon");
const clacky_chan: Layout = @import("schematic/clacky_chan.zon");

/// Schematic layouts by catalog selector.
const layouts = [_]struct { []const u8, Layout }{
    .{ "lk1", keycaprio_30 },
    .{ "lk2", keycaprio_30 },
    .{ "keycaprio_colemak_0_4", keycaprio_30 },
    .{ "lk6", keycaprio_34 },
    .{ "lk7", keycaprio_34 },
    .{ "lk8", keycaprio_34 },
    .{ "keycaprio_colemak_0_6", keycaprio_34 },
    .{ "keycaprio_colemak_0_7", keycaprio_34 },
    .{ "keycaprio_us_intl_0_7", keycaprio_34 },
    .{ "clacky_chan", clacky_chan },
    .{ "clackychan_colemak", clacky_chan },
    .{ "tuckytwotimes", @import("schematic/tucky_two_times.zon") },
    .{ "molekula", @import("schematic/molekula.zon") },
    .{ "dasbob", @import("schematic/dasbob.zon") },
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

/// The schematic layout of `selector`, if one exists.
pub fn find(comptime selector: []const u8) ?Layout {
    inline for (layouts) |entry| {
        if (comptime std.mem.eql(u8, entry[0], selector)) return entry[1];
    }
    return null;
}

/// The keys of `layout` in key-index order. A key's ID is its index unless
/// `ids` names the IDs of existing projects.
pub fn place(comptime layout: Layout, comptime count: usize, comptime ids: ?*const [count]KeyId) [count]Key {
    if (layout.len != count) @compileError("Schematic layout key count differs from the firmware keymap");
    var result: [count]Key = undefined;
    var seen: [count]bool = @splat(false);
    for (layout) |item| {
        if (item.key_index >= count or seen[item.key_index]) @compileError("Schematic layout repeats or exceeds a key index");
        seen[item.key_index] = true;
        result[item.key_index] = .{
            .id = if (ids) |table| table[item.key_index] else item.key_index,
            .key_index = item.key_index,
            .x = item.x,
            .y = item.y,
            .rotation = item.rotation,
            .hand = item.hand,
            .group = item.group,
            .home_row = item.home_row,
        };
    }
    return result;
}

test "finger keys stand upright, one key apart, on quarter rows" {
    inline for (layouts) |entry| {
        // Columns of one hand lie whole keys apart; only the gap between the
        // hands may be fractional.
        var origin: [2]?f32 = .{ null, null };
        var upright: [2]bool = .{ false, false };
        for (entry[1]) |item| {
            if (item.group == .thumb) {
                // Thumbs turn towards the centre in 10-degree steps: clockwise on the left.
                try std.testing.expectEqual(@round(item.rotation / 10), item.rotation / 10);
                try std.testing.expect(if (item.hand == .left) item.rotation >= 0 else item.rotation <= 0);
                if (item.rotation == 0) upright[if (item.hand == .right) 1 else 0] = true;
                continue;
            }
            try std.testing.expectEqual(@as(f32, 0), item.rotation);
            const hand: usize = if (item.hand == .right) 1 else 0;
            const first = origin[hand] orelse item.x;
            origin[hand] = first;
            try std.testing.expectEqual(@round(item.x - first), item.x - first);
            try std.testing.expectEqual(@round(item.y * 4), item.y * 4);
        }
        // Every hand has an upright thumb key as a reference.
        try std.testing.expect(upright[0] and upright[1]);
    }
}

test "each layout mirrors its hands and starts at the origin" {
    inline for (layouts) |entry| {
        const keys = entry[1];
        var right_edge: f32 = 0;
        var top: f32 = std.math.floatMax(f32);
        var left: f32 = std.math.floatMax(f32);
        for (keys) |item| {
            right_edge = @max(right_edge, item.x + 1);
            top = @min(top, item.y);
            left = @min(left, item.x);
        }
        try std.testing.expectEqual(@as(f32, 0), top);
        try std.testing.expectEqual(@as(f32, 0), left);
        // Every key has a counterpart on the other hand at the mirrored place.
        for (keys) |item| {
            const twin = for (keys) |other| {
                if (other.hand != item.hand and other.group == item.group and
                    @abs(other.x - (right_edge - 1 - item.x)) < 0.02 and
                    @abs(other.y - item.y) < 0.02 and other.rotation == -item.rotation) break other;
            } else return error.TestUnexpectedResult;
            try std.testing.expectEqual(item.home_row, twin.home_row);
        }
    }
}

test "Keycaprio revisions share a layout by key count and keep their key IDs" {
    const ids = @import("lk7-key-ids").ids;
    const lk6 = comptime place(find("lk6").?, 34, null);
    const lk7 = comptime place(find("lk7").?, 34, &ids);
    try std.testing.expectEqual(@as(u16, 0x100), lk7[0].id);
    try std.testing.expectEqual(@as(u16, 0), lk6[0].id);
    for (lk6, lk7) |a, b| {
        try std.testing.expectEqual(a.key_index, b.key_index);
        try std.testing.expectEqual(a.x, b.x);
        try std.testing.expectEqual(a.y, b.y);
    }
    // The 30-key boards have no bottom pinky key: the bottom row starts at the ring finger.
    const lk2 = comptime place(find("lk2").?, 30, null);
    try std.testing.expectEqual(lk2[11].x, lk2[20].x);
    try std.testing.expectEqual(model.physical_layout.Group.thumb, lk2[28].group);
}

test "rows follow the keymap order and the middle finger sits highest" {
    const molekula = comptime place(find("molekula").?, 38, null);
    try std.testing.expect(molekula[2].y < molekula[0].y and molekula[2].y < molekula[4].y);
    // Molekula's outer home-row keys lie left and right of the letter columns.
    try std.testing.expect(molekula[10].x < molekula[11].x and molekula[21].x > molekula[20].x);
    for (molekula[0..10]) |key| try std.testing.expect(!key.home_row);
    for (molekula[10..22]) |key| try std.testing.expect(key.home_row);
    const dasbob = comptime place(find("dasbob").?, 36, null);
    for (0..3) |row| for (0..9) |column| {
        const index = row * 10 + column;
        try std.testing.expect(dasbob[index].x < dasbob[index + 1].x);
    };
    try std.testing.expectEqual(model.physical_layout.Hand.right, dasbob[33].hand);
}

test "boards without a schematic layout are drawn linearly" {
    try std.testing.expect(find("yak") == null);
    const placed = comptime linear(12, &.{ .L, .L, .L, .L, .L, .L, .R, .R, .R, .R, .R, .R });
    try std.testing.expectEqual(@as(f32, 9), placed[9].x);
    try std.testing.expectEqual(@as(f32, 0), placed[10].x);
    try std.testing.expectEqual(@as(f32, 1), placed[11].y);
    try std.testing.expectEqual(model.physical_layout.Hand.right, placed[11].hand);
    try std.testing.expectEqual(model.physical_layout.Hand.neutral, linear(2, &.{})[0].hand);
}
