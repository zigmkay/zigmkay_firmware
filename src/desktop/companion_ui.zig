//! Passive, identity-checked layout reference. No buttons or pointer interaction.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const layout = @import("layout-model");
const ui = @import("editor-ui");

pub const View = struct { overlay: bool = true, applied_window: ?u32 = null, unavailable: bool = false };

pub const Frame = struct {
    snapshot: [32]u8,
    geometry: []const layout.physical_layout.Key,
    labels: *const desktop.label_cache.LabelCache,
    board_name: []const u8,
    layer: usize,
    modifiers: layout.Modifiers = .{},
    pressed: []const bool,
    practicing: bool = false,
    assistance: desktop.practice_controller.Assistance = .guided,
    live: bool = false,
    active_layers: ?u16 = null,
    targets: ?[]const bool = null,
    holds: ?[]const bool = null,
};

pub fn draw(model: *const desktop.model.Model, frame: Frame, light: bool) !void {
    if (!std.mem.eql(u8, &frame.snapshot, &(try model.id()))) return error.StaleKeyboardLabels;
    const doc = model.document();
    if (frame.labels.key_count != doc.key_ids.len or frame.labels.layer_count != doc.layers.len) return error.InvalidDimensions;
    const arena = dvui.currentWindow().arena();
    const theme = ui.Theme.get(light);
    const rect = dvui.windowRect();
    var background = ui.options(theme, .{ .w = rect.w, .h = rect.h }, 14);
    background.background = false;
    background.padding = .{};
    background.corners = .all(0);
    var panel = dvui.box(@src(), .{}, background);
    defer panel.deinit();
    if (frame.layer >= doc.layers.len) return error.InvalidLayer;
    const source = if (frame.live) "Verified running profile" else "Draft · device offline";
    drawTitle(theme, doc.layers[frame.layer].name, source, frame.layer, rect.w);
    const output = try arena.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const key_y: f32 = 26;
    const bounds: desktop.physical_view.Rect = .{ .x = 20, .y = key_y, .w = @max(0, rect.w - 40), .h = @max(0, rect.h - key_y - 25) };
    if (bounds.w == 0 or bounds.h == 0) return;
    const neutral = try arena.alloc(bool, frame.labels.key_count);
    @memset(neutral, false);
    // Practice without guided assistance shows neither presses nor targets.
    const guided = frame.practicing and frame.assistance == .guided;
    const keys = try desktop.physical_view.plan(output, frame.geometry, frame.labels, frame.layer, frame.modifiers, bounds, .{
        .pressed = if (frame.practicing and frame.assistance != .guided) neutral else frame.pressed,
        .active_layers = frame.active_layers,
        .targets = if (guided) frame.targets else null,
        .holds = if (guided) frame.holds else null,
        .hold_source_layer = frame.layer,
    });
    if (keys.len == 0) ui.label(theme, "Physical geometry unavailable", .{ .x = 20, .y = 100, .w = 600, .h = 30 }, 16);
    for (keys) |key| try drawKey(key, theme, frame.layer);
}

/// Draws one key on an opaque face so the overlay stays readable over any
/// window. The border carries the shown layer's color; pressed keys fill with it.
fn drawKey(key: desktop.physical_view.DrawKey, theme: ui.Theme, layer: usize) !void {
    const bounds = ui.rect(key.placed.rect);
    const layer_color = ui.layerColor(theme, layer);
    var face = theme.keycap;
    face.a = 238;
    var options = ui.options(theme, bounds, 17);
    options.id_extra = key.placed.id;
    options.background = true;
    options.corners = .all(@max(4, bounds.w * 0.12));
    options.border = .all(if (key.pressed or key.target or key.hold) 2.5 else 2);
    options.color_fill = .{ .color = face };
    options.color_border = .{ .color = layer_color };
    if (key.target) {
        options.color_fill = .{ .color = ui.color(0xD6A54D) };
        options.color_border = .{ .color = ui.color(0xFFC953) };
    }
    if (key.hold) {
        options.color_fill = .{ .color = ui.color(0x267FA5) };
        options.color_border = .{ .color = ui.color(0x50D2FF) };
    }
    if (key.pressed) options.color_fill = .{ .color = layer_color };
    // DVUI boxes ignore rotation; a turned key draws its face as a path.
    const turn: ui.Turn = .{ .radians = key.placed.rotation, .pivot = bounds.center() };
    if (turn.radians != 0) {
        const border = options.borderGet().x;
        ui.turnedBox(bounds, turn, .round(@max(4, bounds.w * 0.12)), options.color_fill.?.color, options.color_border.?.color, border);
    } else {
        const box = dvui.box(@src(), .{}, options);
        box.deinit();
    }
    const strong = key.pressed or key.target or key.hold;
    const text_color = if (strong) ui.color(0xFFFFFF) else theme.text;
    const arena = dvui.currentWindow().arena();
    const legend = key.content.caption orelse key.content.label orelse "";
    const text = if (key.hold)
        try std.fmt.allocPrint(arena, "{s}\nHOLD", .{legend})
    else if (key.target)
        try std.fmt.allocPrint(arena, "{s}\nTAP", .{legend})
    else
        legend;
    const inset = @max(3, bounds.w * 0.08);
    ui.caption(text, .{ .x = bounds.x + inset, .y = bounds.y + inset, .w = @max(1, bounds.w - inset * 2), .h = @max(1, bounds.h - inset * 2) }, .{
        .color = text_color,
        .secondary = if (strong) text_color else theme.muted,
        .size = 24 * @min(1, key.scale),
        .id_extra = key.placed.id,
        .layer_colors = !key.pressed,
        .layers = theme.layers,
        .turn = turn,
    });
}

/// The shown layer and the label source on an opaque pill: a dot in the layer
/// color, the layer name, then the source in muted text.
fn drawTitle(theme: ui.Theme, layer_name: []const u8, source: []const u8, layer: usize, width: f32) void {
    const name_size = ui.captionSize(layer_name, .{ .color = theme.text, .secondary = theme.muted, .size = 15 });
    const source_size = ui.captionSize(source, .{ .color = theme.muted, .secondary = theme.muted, .size = 12 });
    const pill_w = @min(@max(0, width - 40), 34 + name_size.w + 12 + source_size.w + 14);
    var face = theme.keycap;
    face.a = 238;
    const pill = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 20, .y = 2, .w = pill_w, .h = 22 },
        .background = true,
        .color_fill = .{ .color = face },
        .color_border = .{ .color = ui.layerColor(theme, layer) },
        .border = .all(1),
        .corners = .all(11),
        .padding = .{},
        .margin = .{},
    });
    pill.deinit();
    const dot = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 30, .y = 8, .w = 10, .h = 10 },
        .background = true,
        .color_fill = .{ .color = ui.layerColor(theme, layer) },
        .corners = .all(5),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();
    ui.caption(layer_name, .{ .x = 48, .y = 2, .w = name_size.w + 2, .h = 22 }, .{
        .color = theme.text,
        .secondary = theme.muted,
        .size = 15,
        .align_x = 0,
        .id_extra = 1,
    });
    ui.caption(source, .{ .x = 48 + name_size.w + 12, .y = 2, .w = @max(1, pill_w - 62 - name_size.w), .h = 22 }, .{
        .color = theme.muted,
        .secondary = theme.muted,
        .size = 12,
        .align_x = 0,
        .id_extra = 2,
    });
}
