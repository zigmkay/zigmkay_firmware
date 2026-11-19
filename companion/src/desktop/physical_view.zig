//! Reference physical fitting and practice guidance over injected board geometry.
//! Plan entries borrow label-cache bytes until the caller finishes drawing.
const std = @import("std");
const model = @import("layout-model");
const cache = @import("label_cache.zig");
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
pub const Placement = struct { id: u16, key_index: model.KeyIndex, rect: Rect, rotation: f32 };

pub const Fit = struct {
    scale: f32,
    offset_x: f32,
    offset_y: f32,

    pub fn place(self: Fit, item: model.physical_layout.Key) Placement {
        return .{ .id = item.id, .key_index = item.key_index, .rotation = item.rotation * std.math.pi / 180, .rect = .{
            .x = self.offset_x + item.x * self.scale,
            .y = self.offset_y + item.y * self.scale,
            .w = item.width * self.scale,
            .h = item.height * self.scale,
        } };
    }
};

/// Caller supplies validated geometry. Rotation contributes to fitted bounds.
pub fn fit(items: []const model.physical_layout.Key, bounds: Rect) Fit {
    var min_x: f32 = std.math.inf(f32);
    var min_y = min_x;
    var max_x: f32 = -min_x;
    var max_y = max_x;
    for (items) |item| {
        const angle = item.rotation * std.math.pi / 180;
        const half_w = (@abs(@cos(angle)) * item.width + @abs(@sin(angle)) * item.height) / 2;
        const half_h = (@abs(@sin(angle)) * item.width + @abs(@cos(angle)) * item.height) / 2;
        const cx = item.x + item.width / 2;
        const cy = item.y + item.height / 2;
        min_x = @min(min_x, cx - half_w);
        max_x = @max(max_x, cx + half_w);
        min_y = @min(min_y, cy - half_h);
        max_y = @max(max_y, cy + half_h);
    }
    if (items.len == 0) return .{ .scale = 0, .offset_x = bounds.x, .offset_y = bounds.y };
    const scale = @max(0, @min(bounds.w / (max_x - min_x), bounds.h / (max_y - min_y)));
    return .{
        .scale = scale,
        .offset_x = bounds.x + (bounds.w - (max_x - min_x) * scale) / 2 - min_x * scale,
        .offset_y = bounds.y + (bounds.h - (max_y - min_y) * scale) / 2 - min_y * scale,
    };
}

pub const Guidance = struct {
    pressed: []const bool,
    targets: ?[]const bool = null,
    holds: ?[]const bool = null,
    hold_source_layer: usize = 0,
    active_layers: ?u16 = null,
    stale: bool = false,
};

pub const DrawKey = struct {
    placed: Placement,
    scale: f32,
    content: cache.CachedKeyContent,
    pressed: bool,
    target: bool,
    hold: bool,
};

/// Output order follows geometry; event/guidance lookup follows processing index.
/// Validation precedes writes, so refused input leaves caller storage unchanged.
pub fn plan(
    output: []DrawKey,
    items: []const model.physical_layout.Key,
    labels: *const cache.LabelCache,
    layer: usize,
    mods: model.Modifiers,
    bounds: Rect,
    guidance: Guidance,
) ![]DrawKey {
    if (!std.math.isFinite(bounds.x) or
        !std.math.isFinite(bounds.y) or
        !std.math.isFinite(bounds.w) or
        !std.math.isFinite(bounds.h) or
        !std.math.isFinite(bounds.x + bounds.w) or
        !std.math.isFinite(bounds.y + bounds.h) or
        bounds.w < 0 or
        bounds.h < 0) return error.InvalidBounds;
    if (layer >= labels.layer_count or guidance.hold_source_layer >= labels.layer_count) return error.InvalidLayer;
    if (output.len < items.len or guidance.pressed.len != labels.key_count) return error.InvalidDimensions;
    if (guidance.targets) |targets| if (targets.len != labels.key_count) return error.InvalidDimensions;
    if (guidance.holds) |holds| if (holds.len != labels.key_count) return error.InvalidDimensions;
    if (guidance.active_layers) |active| {
        const valid = (@as(u16, 1) << @intCast(labels.layer_count)) - 1;
        if (active & ~valid != 0) return error.InvalidActiveLayers;
    }
    if (items.len == 0) return output[0..0];
    try model.physical_layout.validateKeys(items, .{
        .key_count = @intCast(labels.key_count),
        .layer_count = @intCast(labels.layer_count),
    });
    const fitted = fit(items, bounds);
    if (!std.math.isFinite(fitted.scale) or
        !std.math.isFinite(fitted.offset_x) or
        !std.math.isFinite(fitted.offset_y)) return error.InvalidGeometry;
    if (fitted.scale <= 0) return output[0..0];
    for (items, output[0..items.len]) |item, *entry| {
        var placed = fitted.place(item);
        const padding = @min(3, fitted.scale * 0.06);
        placed.rect.x += padding;
        placed.rect.y += padding;
        placed.rect.w = @max(0, placed.rect.w - padding * 2);
        placed.rect.h = @max(0, placed.rect.h - padding * 2);
        const index = placed.key_index;
        const held = if (guidance.holds) |holds| holds[index] else false;
        const content = if (held) labels.lookup(
            guidance.hold_source_layer,
            index,
            .{},
        ) else if (guidance.active_layers) |active| labels.lookupActive(layer, index, mods, active) else labels.lookup(layer, index, mods);
        entry.* = .{
            .placed = placed,
            .scale = fitted.scale / 45,
            .content = content.*,
            .pressed = !guidance.stale and guidance.pressed[index],
            .target = if (guidance.targets) |targets| targets[index] else false,
            .hold = held,
        };
    }
    return output[0..items.len];
}

test "rotated non-square geometry uses reference fitting" {
    const item = model.physical_layout.Key{
        .id = 123,
        .key_index = 0,
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 1,
        .rotation = 90,
        .hand = .neutral,
    };
    const fitted = fit(&.{item}, .{ .w = 100, .h = 100 });
    try std.testing.expectApproxEqAbs(@as(f32, 50), fitted.scale, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), fitted.place(item).rotation, 0.001);
}

test "guidance follows processing indices and holds use source layer without modifiers" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 2, 2);
    defer labels.deinit();
    labels.entries[0].label = "source";
    labels.entries[2 * 256].label = "current";
    const geometry = [_]model.physical_layout.Key{
        .{ .id = 500, .key_index = 1, .x = 2, .y = 0, .hand = .neutral },
        .{ .id = 100, .key_index = 0, .x = 0, .y = 0, .hand = .neutral },
    };
    var output: [2]DrawKey = undefined;
    const guidance: Guidance = .{
        .pressed = &.{ true, false },
        .targets = &.{ false, true },
        .holds = &.{ true, false },
        .stale = true,
    };
    const entries = try plan(
        &output,
        &geometry,
        &labels,
        1,
        .{ .left_shift = true },
        .{ .w = 300, .h = 100 },
        guidance,
    );
    try t.expectEqual(@as(u16, 500), entries[0].placed.id);
    try t.expect(entries[0].target);
    try t.expect(entries[1].hold);
    try t.expect(!entries[1].pressed);
    try t.expectEqualStrings("source", entries[1].content.label.?);
    try t.expectError(
        error.InvalidDimensions,
        plan(&output, &geometry, &labels, 1, .{}, .{ .w = 300, .h = 100 }, .{ .pressed = &.{true} }),
    );
    try t.expectEqualStrings("source", output[1].content.label.?);
    try t.expectEqual(
        @as(usize, 0),
        (try plan(&output, &.{}, &labels, 1, .{}, .{ .w = 300, .h = 100 }, guidance)).len,
    );
}
