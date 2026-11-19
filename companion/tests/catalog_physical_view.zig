//! Offline injected geometry: selected firmware boards, no GPIO claim.
const std = @import("std");
const catalog = @import("catalog");
const desktop = @import("desktop-core");

test "all catalog geometries preserve identity and processing-index guidance" {
    const t = std.testing;
    for (catalog.entries) |entry| {
        var labels = try desktop.label_cache.LabelCache.init(
            t.allocator,
            entry.default_dimensions.layer_count,
            entry.default_dimensions.key_count,
        );
        defer labels.deinit();
        const output = try t.allocator.alloc(desktop.physical_view.DrawKey, entry.geometry.len);
        defer t.allocator.free(output);
        const pressed = try t.allocator.alloc(bool, labels.key_count);
        defer t.allocator.free(pressed);
        @memset(pressed, false);
        pressed[labels.key_count - 1] = true;
        for ([_]desktop.physical_view.Rect{
            .{ .x = 10, .y = 80, .w = 700, .h = 240 },
            .{ .w = 340, .h = 160 },
        }) |bounds| {
            const plan = try desktop.physical_view.plan(
                output,
                entry.geometry,
                &labels,
                0,
                .{},
                bounds,
                .{ .pressed = pressed, .targets = pressed },
            );
            try t.expectEqual(entry.geometry.len, plan.len);
            var active_count: usize = 0;
            for (plan, entry.geometry) |placed, physical| {
                try t.expectEqual(physical.id, placed.placed.id);
                try t.expectEqual(physical.key_index, placed.placed.key_index);
                try t.expectEqual(pressed[physical.key_index], placed.target);
                if (placed.pressed) active_count += 1;
                try t.expect(placed.scale > 0);
            }
            try t.expectEqual(@as(usize, 1), active_count);
        }
    }
}
