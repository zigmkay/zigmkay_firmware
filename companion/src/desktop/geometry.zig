const std = @import("std");
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const Panel = enum { toolbar, sidebar, physical, os, testing, callbacks };

/// Panels on the 1536 × 1056 design canvas; see docs/design/editor.md.
pub const reference = [6]Rect{
    .{ .x = 0, .y = 0, .w = 1536, .h = 100 },
    .{ .x = 16, .y = 112, .w = 240, .h = 744 },
    .{ .x = 268, .y = 112, .w = 1252, .h = 580 },
    .{ .x = 268, .y = 704, .w = 1252, .h = 340 },
    .{ .x = 16, .y = 868, .w = 240, .h = 82 },
    .{ .x = 16, .y = 962, .w = 240, .h = 82 },
};

pub const initial = Rect{ .x = 0, .y = 0, .w = 1152, .h = 768 };
pub const minimum = Rect{ .x = 0, .y = 0, .w = 900, .h = 600 };
pub const status_height: f32 = 32;

/// Preserve panel proportions and scale fonts and input coordinates together.
pub fn fitScale(width: f32, height: f32) f32 {
    return @max(0.01, @min(width / 1536, height / (1024 + status_height)));
}

pub fn panel(which: Panel) Rect {
    return reference[@backingInt(which)];
}

test "resized canvas fits both axes without requiring outer scrolling" {
    for ([_]Rect{
        minimum,
        initial,
        .{ .x = 0, .y = 0, .w = 1400, .h = 800 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1280 },
    }) |bounds| {
        const scale = fitScale(bounds.w, bounds.h);
        try std.testing.expect(1536 * scale <= bounds.w + 0.01);
        try std.testing.expect((1024 + status_height) * scale <= bounds.h + 0.01);
    }
    try std.testing.expectEqual(initial.h / (1024 + status_height), fitScale(initial.w, initial.h));
}

test "reference panels match visual specification and remain disjoint" {
    for (reference[1..], 1..) |a, i| {
        try std.testing.expect(a.x >= 16 and a.y >= 112 and a.x + a.w <= 1520 and a.y + a.h <= 1044);
        for (reference[i + 1 ..]) |b| try std.testing.expect(
            a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y,
        );
    }
}
