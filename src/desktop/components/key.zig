//! Retained keycap rendering: caption, icon, layer and modifier indicators.
const std = @import("std");
const testing = std.testing;
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const zkeymap = @import("zkeymap");
const labels = desktop.labels;
const ui = @import("editor-ui");
const core = @import("layout-model");
const CachedKeyContent = desktop.label_cache.CachedKeyContent;

pub const Resources = struct { gui_icon: ?[]const u8 = null };

/// The shared layer palette of the editor and companion.
pub const layer_colors = blk: {
    var colors: [ui.layer_palette.dark.len]dvui.Color = undefined;
    for (&colors, ui.layer_palette.dark) |*entry, hex| entry.* = ui.color(hex);
    break :blk colors;
};

/// Returns a muted version of a layer color.
pub fn getMutedColor(color: dvui.Color) dvui.Color {
    return .{
        .r = @intCast(@as(u32, color.r) / 2),
        .g = @intCast(@as(u32, color.g) / 2),
        .b = @intCast(@as(u32, color.b) / 2),
        .a = 180,
    };
}

/// Color for layers not present in the keymap.
pub const empty_layer_color = dvui.Color{ .r = 40, .g = 40, .b = 40, .a = 255 };

fn layerColor(layer: usize) dvui.Color {
    return if (layer < layer_colors.len) layer_colors[layer] else dvui.Color.white;
}

/// Renders a 3x3 grid representing layers.
pub fn drawLayerGrid(active_layer: usize, total_layers: usize, size: f32, scale: f32) !void {
    var outer = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = size, .h = size },
        .gravity_x = 0.5,
    });
    defer outer.deinit();

    const cells = @max(9, total_layers);
    const rows: f32 = @floatFromInt((cells + 2) / 3);
    const cell_size = (size - 2 * (rows + 1) * scale) / rows;

    for (0..cells) |i| {
        const row: f32 = @floatFromInt(i / 3);
        const col: f32 = @floatFromInt(i % 3);

        const color = if (i >= total_layers)
            empty_layer_color
        else if (i == active_layer)
            layerColor(i)
        else
            getMutedColor(layerColor(i));

        var cell = dvui.box(@src(), .{}, .{
            .id_extra = i + 9000,
            .rect = .{
                .x = col * (cell_size + 2 * scale),
                .y = row * (cell_size + 2 * scale),
                .w = cell_size,
                .h = cell_size,
            },
            .background = true,
            .color_fill = .{ .color = color },
            .corners = .all(2 * scale),
        });
        cell.deinit();
    }
}

const Palette = struct {
    background: dvui.Color,
    border: dvui.Color,
    text: dvui.Color,
    modifier: dvui.Color,

    fn init(layer: usize, active: bool, target: bool, hold: bool) Palette {
        const layer_color = layerColor(layer);
        const muted = getMutedColor(layer_color);
        const dark = dvui.themeGet().dark;
        const target_fill = if (dark)
            dvui.Color{ .r = 58, .g = 47, .b = 22, .a = 255 }
        else
            dvui.Color{ .r = 255, .g = 240, .b = 192, .a = 255 };
        return .{
            .background = if (active) muted else if (target) target_fill else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .border = if (hold)
                dvui.Color{ .r = 80, .g = 210, .b = 255, .a = 255 }
            else if (target)
                dvui.Color{ .r = 255, .g = 201, .b = 83, .a = 255 }
            else if (active)
                layer_color
            else
                muted,
            .text = if (dark or active) dvui.Color.white else dvui.Color{ .r = 32, .g = 36, .b = 42, .a = 255 },
            .modifier = if (dark)
                dvui.Color{ .r = 0, .g = 255, .b = 255, .a = 255 }
            else
                dvui.Color{ .r = 0, .g = 112, .b = 136, .a = 255 },
        };
    }
};

/// Renders one key. Practice guidance marks the next key to `target` (tap) or
/// `hold`; `active` keys are currently pressed.
pub fn drawPracticeKey(
    current_layer: usize,
    index: usize,
    rect: dvui.Rect,
    rotation: f32,
    scale: f32,
    content: CachedKeyContent,
    active: bool,
    target: bool,
    hold: bool,
    resources: Resources,
) !void {
    const size = @min(rect.w, rect.h);
    const palette: Palette = .init(current_layer, active, target, hold);
    const guided = target or hold;

    const thickness = (if (guided) @as(f32, 3) else 1.5) * scale;
    // Boxes ignore rotation: a turned key draws its face as a path.
    const turned = rotation != 0;
    if (turned) ui.turnedFace(rect, rotation, 8 * scale, if (active or guided) palette.background else dvui.Color.transparent, palette.border, thickness);
    var b = dvui.box(@src(), .{}, .{
        .id_extra = index,
        .rect = rect,
        .background = !turned and (active or guided),
        .color_fill = .{ .color = palette.background },
        .color_border = .{ .color = palette.border },
        .border = if (turned) .{} else dvui.Rect.all(thickness),
        .corners = .all(8 * scale),
        .padding = .{},
    });
    defer b.deinit();
    if (guided) dvui.label(@src(), "{s}", .{if (hold) "HOLD" else "TAP"}, .{
        .gravity_x = 0.5,
        .gravity_y = 1,
        .font = dvui.Font.theme(.body).larger(-3 * scale),
        .color_text = .{ .color = palette.border },
    });

    // A precomputed caption replaces every other indicator.
    if (content.caption) |caption| {
        const reserved: f32 = if (guided) 18 else 8;
        drawCaption(caption, index, rect, scale, reserved, palette.text);
        return;
    }
    if (content.icon) |icon_bytes| {
        dvui.icon(@src(), content.icon_name, icon_bytes, .{}, .{
            .id_extra = index,
            .color_text = .{ .color = palette.text },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = size * 0.4, .h = size * 0.4 },
        });
    } else if (content.label) |l| {
        if (std.unicode.utf8ValidateSlice(l)) {
            dvui.label(@src(), "{s}", .{l}, .{
                .id_extra = index,
                .color_text = .{ .color = palette.text },
                .font = dvui.Font.theme(.body).larger(if (l.len <= 2) 4 * scale else 0),
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
        }
    }
    if (content.hold_layer) |layer| drawLayerIndicator(layer, index, size, scale);
    if (content.hold_mods) |mods| drawModifierIndicators(mods, index, size, scale, palette.modifier, resources);
}

/// Draws a caption scaled down to fit the keycap. Keyboard symbols, including
/// companion signals, are drawn as icons.
fn drawCaption(caption: []const u8, index: usize, rect: dvui.Rect, scale: f32, reserved: f32, color: dvui.Color) void {
    ui.caption(caption, .{
        .x = 4 * scale,
        .y = 4 * scale,
        .w = @max(1, rect.w - 8 * scale),
        .h = @max(1, rect.h - reserved * scale),
    }, .{
        .color = color,
        .secondary = color,
        .size = 24 * scale,
        .id_extra = index,
    });
}

/// A layer icon in the top-right corner, in the color of the held layer.
fn drawLayerIndicator(layer: usize, index: usize, size: f32, scale: f32) void {
    const icon_size = size * 0.3;
    const padding = 4 * scale;
    dvui.icon(@src(), "layer_ind", dvui.entypo.layers, .{}, .{
        .id_extra = index + 1000,
        .color_text = .{ .color = layerColor(layer) },
        .rect = .{ .x = size - icon_size - padding, .y = padding, .w = icon_size, .h = icon_size },
    });
}

/// Held modifiers stacked down the left side: GUI, Ctrl, Alt, then Shift.
fn drawModifierIndicators(mods: core.Modifiers, index: usize, size: f32, scale: f32, color: dvui.Color, resources: Resources) void {
    const column: ModifierColumn = .{ .x = 2 * scale, .w = size * 0.6, .item_h = size * 0.25, .color = color };
    var offset_y: f32 = 2 * scale;
    const step = column.item_h + 1 * scale;
    var buffer: [32]u8 = undefined;
    if (mods.left_gui or mods.right_gui) {
        const icon_size = column.item_h * 0.8;
        if (resources.gui_icon) |icon| dvui.icon(@src(), "gui_ind", icon, .{}, .{
            .id_extra = index + 6000,
            .color_text = .{ .color = color },
            .rect = .{
                .x = column.x + (column.w - icon_size) / 2.0,
                .y = offset_y + (column.item_h - icon_size) / 2.0,
                .w = icon_size,
                .h = icon_size,
            },
        }) else {
            column.label(labels.keycapModifiers(labels.runningHost(), 8, &buffer), index + 6000, offset_y);
        }
        offset_y += step;
    }
    if (mods.left_ctrl or mods.right_ctrl) {
        column.label("ctrl", index + 3000, offset_y);
        offset_y += step;
    }
    if (mods.left_alt or mods.right_alt) {
        column.label(labels.keycapModifiers(labels.runningHost(), 4, &buffer), index + 4000, offset_y);
        offset_y += step;
    }
    if (mods.left_shift or mods.right_shift) column.label("shft", index + 5000, offset_y);
}

const ModifierColumn = struct {
    x: f32,
    w: f32,
    item_h: f32,
    color: dvui.Color,

    fn label(self: ModifierColumn, text: []const u8, id_extra: usize, y: f32) void {
        dvui.label(@src(), "{s}", .{text}, .{
            .id_extra = id_extra,
            .color_text = .{ .color = self.color },
            .font = dvui.Font.theme(.body),
            // A taller rect than the slot prevents clipping; slots still advance by item_h.
            .rect = .{ .x = self.x, .y = y, .w = self.w, .h = self.item_h * 1.5 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
    }
};

/// WCAG relative luminance of an sRGB color.
fn luminance(color: dvui.Color) f64 {
    const linear = struct {
        fn channel(value: u8) f64 {
            const c = @as(f64, @floatFromInt(value)) / 255;
            return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        }
    }.channel;
    return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b);
}

fn contrast(a: dvui.Color, b: dvui.Color) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "layer borders stand out from keycaps and panels in both themes" {
    for ([_]bool{ false, true }) |light| {
        const theme = ui.Theme.get(light);
        for (0..theme.layers.len) |index| {
            const border = ui.layerColor(theme, index);
            errdefer std.debug.print("layer {d} light={} contrast {d:.2}\n", .{ index, light, contrast(border, theme.keycap) });
            // Close to the WCAG 3:1 guideline for non-text UI components.
            try testing.expect(contrast(border, theme.keycap) >= 2.8);
            try testing.expect(contrast(border, theme.panel) >= 2.8);
        }
    }
}

/// CIELAB coordinates of an sRGB color under the D65 white point.
fn lab(color: dvui.Color) [3]f64 {
    const linear = struct {
        fn channel(value: u8) f64 {
            const c = @as(f64, @floatFromInt(value)) / 255;
            return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        }
        fn f(t: f64) f64 {
            return if (t > 0.008856) std.math.cbrt(t) else 7.787 * t + 16.0 / 116.0;
        }
    };
    const r = linear.channel(color.r);
    const g = linear.channel(color.g);
    const b = linear.channel(color.b);
    const x = linear.f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047);
    const y = linear.f(0.2126 * r + 0.7152 * g + 0.0722 * b);
    const z = linear.f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883);
    return .{ 116 * y - 16, 500 * (x - y), 200 * (y - z) };
}

test "layer colors stay distinguishable from each other" {
    for ([_]bool{ false, true }) |light| {
        const theme = ui.Theme.get(light);
        for (0..theme.layers.len) |a| for (a + 1..theme.layers.len) |b| {
            const first = lab(ui.layerColor(theme, a));
            const second = lab(ui.layerColor(theme, b));
            const distance = std.math.sqrt(std.math.pow(f64, first[0] - second[0], 2) +
                std.math.pow(f64, first[1] - second[1], 2) +
                std.math.pow(f64, first[2] - second[2], 2));
            errdefer std.debug.print("layers {d} and {d} light={} differ by ΔE {d:.1}\n", .{ a, b, light, distance });
            // CIE76 ΔE: about 2.3 is just noticeable; 30 reads as a different hue at a glance.
            try testing.expect(distance >= 30);
        };
    }
}

test "keycap text keeps readable contrast on keycaps" {
    for ([_]bool{ false, true }) |light| {
        const theme = ui.Theme.get(light);
        try testing.expect(contrast(theme.text, theme.keycap) >= 7);
        try testing.expect(contrast(theme.muted, theme.keycap) >= 3);
    }
}
