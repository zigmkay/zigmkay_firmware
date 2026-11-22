//! Renderer consumes the checked, board-driven physical view plan.
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const key = @import("key.zig");
pub const Resources = key.Resources;
pub const log = @import("log.zig");
pub const encoder = @import("encoder.zig");
pub fn drawLayerGrid(layer: usize, count: usize, size: f32, scale: f32) !void {
    try key.drawLayerGrid(layer, count, size, scale);
}
pub fn draw(layer: usize, plan: []const desktop.physical_view.DrawKey, resources: Resources) !void {
    for (plan) |item| {
        const rect = item.placed.rect;
        try key.drawPracticeKey(
            layer,
            item.placed.id,
            .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h },
            item.placed.rotation,
            item.scale,
            item.content,
            item.pressed,
            item.target,
            item.hold,
            resources,
        );
    }
}
