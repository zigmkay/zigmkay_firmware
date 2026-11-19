//! Static keyboard drawings for My Keyboards, New layout and the import
//! comparison: board geometry fitted into a rectangle, optionally with one
//! layer's keycap captions. Nothing here is interactive.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");

pub const Geometry = @FieldType(desktop.library.catalog.Entry, "geometry");

pub const Style = struct {
    /// Keycap captions in key-index order, or none for a bare outline.
    captions: ?[]const []const u8 = null,
    /// Keys drawn with a dashed danger outline, in key-index order.
    missing: ?[]const bool = null,
    /// The layer whose color outlines the keys.
    layer: usize = 0,
    /// Unique per drawing on a frame.
    id: usize = 0,
};

/// Draws `geometry` fitted and centered in `bounds` (canvas units of the parent).
pub fn draw(theme: ui.Theme, geometry: Geometry, bounds: dvui.Rect, style: Style) void {
    const fitted = desktop.physical_view.fit(geometry, .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h });
    if (!std.math.isFinite(fitted.scale) or fitted.scale <= 0) return;
    const layer_color = ui.layerColor(theme, style.layer);
    for (geometry, 0..) |item, order| {
        const placed = fitted.place(item);
        const gap = @max(0.75, @min(3, fitted.scale * 0.06));
        const rect: dvui.Rect = .{
            .x = placed.rect.x + gap,
            .y = placed.rect.y + gap,
            .w = @max(1, placed.rect.w - gap * 2),
            .h = @max(1, placed.rect.h - gap * 2),
        };
        const index = placed.key_index;
        const missing = if (style.missing) |keys| index < keys.len and keys[index] else false;
        const id = style.id *% 4099 +% order;
        const danger = theme.danger;
        const fill = if (missing) ui.mix(theme.keycap, danger, 0.12) else theme.keycap;
        const border = @max(0.75, @min(1.5, rect.w / 24));
        const corner = @max(2, rect.w * 0.12);
        if (placed.rotation != 0) {
            // A turned key has no dashed outline; its border carries the danger color.
            ui.turnedFace(rect, placed.rotation, corner, fill, if (missing) danger else ui.mix(theme.keycap, layer_color, 0.65), border);
        } else {
            const face = dvui.box(@src(), .{}, .{
                .id_extra = id,
                .rect = rect,
                .background = true,
                .color_fill = .{ .color = fill },
                .color_border = .{ .color = ui.mix(theme.keycap, layer_color, 0.65) },
                .border = if (missing) .{} else .all(border),
                .corners = .all(corner),
                .padding = .{},
                .margin = .{},
            });
            face.deinit();
            if (missing) dashed(rect, danger, id);
        }
        const captions = style.captions orelse continue;
        if (index >= captions.len or captions[index].len == 0) continue;
        const inset = @max(1.5, rect.w * 0.1);
        ui.caption(captions[index], .{ .x = rect.x + inset, .y = rect.y + inset, .w = rect.w - inset * 2, .h = rect.h - inset * 2 }, .{
            .color = if (missing) danger else theme.text,
            .secondary = theme.muted,
            .size = rect.w * 0.42,
            .id_extra = id,
            .layers = theme.layers,
            .turn = .{ .radians = placed.rotation, .pivot = rect.center() },
        });
    }
}

/// A dashed outline: short segments along each edge.
fn dashed(rect: dvui.Rect, color: dvui.Color, id: usize) void {
    const dash: f32 = @max(2.5, rect.w / 10);
    const thickness: f32 = @max(1, @min(1.5, rect.w / 24));
    var segment: usize = 0;
    inline for (.{ false, true }) |vertical| {
        const length = if (vertical) rect.h else rect.w;
        const count: usize = @intFromFloat(@max(1, @floor(length / (dash * 2))));
        const step = length / @as(f32, @floatFromInt(count));
        for (0..count) |index| {
            const offset = @as(f32, @floatFromInt(index)) * step + (step - dash) / 2;
            inline for (.{ false, true }) |far| {
                const edge: dvui.Rect = if (vertical)
                    .{ .x = if (far) rect.x + rect.w - thickness else rect.x, .y = rect.y + offset, .w = thickness, .h = dash }
                else
                    .{ .x = rect.x + offset, .y = if (far) rect.y + rect.h - thickness else rect.y, .w = dash, .h = thickness };
                const piece = dvui.box(@src(), .{}, .{
                    .id_extra = id *% 131 +% segment,
                    .rect = edge,
                    .background = true,
                    .color_fill = .{ .color = color },
                    .padding = .{},
                    .margin = .{},
                });
                piece.deinit();
                segment += 1;
            }
        }
    }
}
