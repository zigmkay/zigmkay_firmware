//! Retained physical editor over injected geometry and current owned captions.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const layout = @import("layout-model");
const ui = @import("editor-ui");

pub const View = struct {
    choice: usize = 0,
    extend: bool = false,
    canvas_focus: bool = false,
    drag: ?desktop.chord_action.Action = null,
};

pub const Frame = struct {
    snapshot: [32]u8,
    board_id: [8]u8,
    physical_layout: []const u8,
    geometry: []const layout.physical_layout.Key,
    labels: *const desktop.label_cache.LabelCache,
    board_name: []const u8,
    fidelity: []const u8,
};

pub const Result = union(enum) {
    select: desktop.key_selection.Action,
    combo: desktop.key_selection.Action,
    encoders: desktop.key_selection.Action,
    chord: desktop.chord_action.Action,
};

pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame, theme: ui.Theme) !?Result {
    const actual = try model.id();
    if (!std.mem.eql(u8, &actual, &frame.snapshot)) return error.StaleKeyboardLabels;
    const doc = model.document();
    if (!std.mem.eql(u8, &frame.board_id, &doc.board_id) or !std.mem.eql(u8, frame.physical_layout, doc.physical_layout)) {
        return error.KeyboardBoardMismatch;
    }
    if (frame.labels.key_count != doc.key_ids.len or frame.labels.layer_count != doc.layers.len) return error.InvalidDimensions;
    const a = dvui.currentWindow().arena();
    const output = try a.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const pressed = try a.alloc(bool, doc.key_ids.len);
    @memset(pressed, false);
    // The canvas fills the panel below its header; geometry keeps its aspect.
    const area: desktop.physical_view.Rect = .{ .x = 20, .y = 60, .w = 760, .h = 428 };
    const plan = try desktop.physical_view.plan(output, frame.geometry, frame.labels, model.layer, .{}, area, .{ .pressed = pressed });
    const box = ui.panel(theme, .physical);
    defer box.deinit();
    drawLayerChip(theme, doc.layers[model.layer].name, model.layer);
    var muted = theme;
    muted.text = theme.muted;
    const chip_width = layerChipWidth(theme, doc.layers[model.layer].name);
    ui.label(muted, frame.board_name, .{ .x = 20 + chip_width + 14, .y = 26, .w = 540 - chip_width, .h = 18 }, 12);
    ui.label(muted, frame.fidelity, .{ .x = 20, .y = 498, .w = 440, .h = 18 }, 12);
    ui.label(muted, "Large: tap · small: hold · layer while held", .{ .x = 520, .y = 498, .w = 260, .h = 18 }, 12);
    var result: ?Result = null;
    if (try drawViewSwitch(view, theme)) |choice| {
        const captured = try desktop.key_selection.Action.capture(model, model.primary, false);
        if (choice == 1) result = .{ .combo = captured };
        if (choice == 2) result = .{ .encoders = captured };
    }
    view.canvas_focus = false;
    if (plan.len == 0) ui.label(theme, "Physical geometry unavailable", .{ .x = 20, .y = 110, .w = 600, .h = 30 }, 16);
    if (view.drag) |drag| drag.validate(model) catch {
        view.drag = null;
        if (dvui.dragName("key_chord")) dvui.dragEnd();
    };
    for (plan) |item| try drawKey(view, model, frame, item, theme, &result);
    return result;
}

fn layerChipWidth(theme: ui.Theme, name: []const u8) f32 {
    return @min(@as(f32, 220), ui.captionSize(name, theme.captionStyle(19, 0)).w + 44);
}

/// The edited layer as a pill in its color.
fn drawLayerChip(theme: ui.Theme, name: []const u8, layer: usize) void {
    const color = ui.layerColor(theme, layer);
    const width = layerChipWidth(theme, name);
    const chip = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 20, .y = 18, .w = width, .h = 30 },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, color, 0.2) },
        .color_border = .{ .color = color },
        .border = .all(1.5),
        .corners = .all(15),
        .padding = .{},
        .margin = .{},
        .tag = "keyboard.layer",
    });
    chip.deinit();
    const dot = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 31, .y = 28, .w = 10, .h = 10 },
        .background = true,
        .color_fill = .{ .color = color },
        .corners = .all(5),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();
    // Key captions use key IDs (u16) as id_extra; stay above that range.
    var style = theme.captionStyle(19, 0x10000);
    style.align_x = 0;
    ui.caption(name, .{ .x = 48, .y = 18, .w = width - 56, .h = 30 }, style);
}

/// Keys, Combos and Encoders as a segmented control. Keys is the canvas; the
/// other two open their editors. Returns the chosen segment when clicked.
fn drawViewSwitch(view: *View, theme: ui.Theme) !?usize {
    const track = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 580, .y = 16, .w = 200, .h = 34 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
    });
    track.deinit();
    const names = [_][]const u8{ "Keys", "Combos", "Encoders" };
    const widths = [_]f32{ 60, 72, 60 };
    var x: f32 = 584;
    var chosen: ?usize = null;
    for (names, widths, 0..) |name, width, index| {
        var opts = ui.options(theme, .{ .x = x, .y = 20, .w = width, .h = 26 }, 13);
        opts.id_extra = index;
        opts.tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "keyboard.view.{d}", .{index});
        opts.corners = .all(6);
        opts.padding = .{};
        opts.background = index == 0;
        opts.color_fill = .{ .color = ui.mix(theme.control, theme.text, 0.12) };
        opts.color_text = .{ .color = if (index == 0) theme.text else theme.muted };
        if (dvui.button(@src(), name, .{}, opts) and index != 0) chosen = index;
        x += width;
    }
    view.choice = 0;
    return chosen;
}

/// The caption a transparent key falls through to, from the nearest lower
/// layer that assigns the key, or null when no layer does.
fn inheritedCaption(labels: *const desktop.label_cache.LabelCache, layer: usize, index: usize) ?[]const u8 {
    var lower = layer;
    while (lower > 0) {
        lower -= 1;
        const entry = labels.lookup(lower, index, .{});
        if (!isTransparent(entry.*)) return entry.caption;
    }
    return null;
}

fn isTransparent(content: desktop.label_cache.CachedKeyContent) bool {
    return if (content.label) |text| std.mem.eql(u8, text, "---") else false;
}

/// Draws one selectable key and accepts host-palette chord drops. The border
/// carries the color of the edited layer; transparent keys show the legend
/// they fall through to, dimmed.
fn drawKey(
    view: *View,
    model: *const desktop.model.Model,
    frame: Frame,
    item: desktop.physical_view.DrawKey,
    theme: ui.Theme,
    result: *?Result,
) !void {
    const index = item.placed.key_index;
    const rect = ui.rect(item.placed.rect);
    const content = item.content;
    const transparent = isTransparent(content);
    const selected = model.selected[index];
    const layer_color = ui.layerColor(theme, model.layer);
    const turned = item.placed.rotation != 0;
    const fill = if (selected) ui.mix(theme.keycap, layer_color, 0.22) else if (transparent) theme.panel else theme.keycap;
    const border = if (selected) layer_color else ui.mix(theme.keycap, layer_color, if (transparent) 0.3 else 0.65);
    const corner = @max(4, rect.w * 0.12);
    const thickness: f32 = if (selected) 2.5 else 1.5;
    var opts = ui.options(theme, rect, 20);
    opts.id_extra = item.placed.id;
    opts.tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "key.select.{d}", .{index});
    // A turned key keeps its upright hit area and draws its face as a path.
    opts.background = !turned;
    opts.corners = .all(corner);
    opts.border = if (turned) .{} else .all(thickness);
    opts.color_fill = .{ .color = fill };
    opts.color_border = .{ .color = border };
    opts.padding = .all(2);
    var data: dvui.WidgetData = undefined;
    opts.data_out = &data;
    if (turned) ui.turnedFace(rect, item.placed.rotation, corner, fill, border, thickness);
    if (dvui.button(@src(), "", .{}, opts) and result.* == null) {
        result.* = .{ .select = try desktop.key_selection.Action.capture(model, index, view.extend) };
    }
    const inset = @max(3, rect.w * 0.08);
    const bounds: dvui.Rect = .{ .x = rect.x + inset, .y = rect.y + inset, .w = @max(1, rect.w - inset * 2), .h = @max(1, rect.h - inset * 2) };
    const fallthrough = if (transparent) inheritedCaption(frame.labels, model.layer, index) else null;
    const text = if (transparent) fallthrough orelse "" else content.caption orelse content.label orelse "";
    ui.caption(text, bounds, .{
        .color = if (transparent) theme.muted else theme.text,
        .secondary = theme.muted,
        .size = 22 * @min(1, item.scale),
        .id_extra = item.placed.id,
        .layer_colors = !transparent,
        .layers = theme.layers,
    });
    if (dvui.focusedWidgetId() == data.id) view.canvas_focus = true;
    try acceptChordDrop(view, model, &data, index, result);
}

fn acceptChordDrop(view: *View, model: *const desktop.model.Model, data: *dvui.WidgetData, index: usize, result: *?Result) !void {
    const drag = view.drag orelse return;
    if (!dvui.dragName("key_chord")) return;
    for (dvui.events()) |*event| {
        if (!dvui.eventMatch(event, .{ .id = data.id, .r = data.borderRectScale().r, .drag_name = "key_chord" })) continue;
        if (event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action == .position) data.focusBorder();
        if (mouse.action == .release and mouse.button == .left) {
            event.handle(@src(), data);
            dvui.dragEnd();
            view.drag = null;
            if (result.* == null) result.* = .{ .chord = try drag.drop(model, index, false) };
        }
    }
}
