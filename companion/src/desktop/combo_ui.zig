//! Retained combo sheet; only its returned bound action can commit a document.
//! The list of combos sits on the left; the edited combo, its keys on a small
//! keyboard, its layer, timeout and action on the right.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const forms = @import("action-form-ui");
const p = @import("project");
const labels = desktop.labels;

pub const Result = union(enum) { close, action: desktop.combo_editor.Action };

/// The board drawing and the keycap captions of the editor canvas.
pub const Board = struct {
    labels: *const desktop.label_cache.LabelCache,
    geometry: @FieldType(desktop.library.catalog.Entry, "geometry"),
};

const width: f32 = 960;
const height: f32 = 840;
const margin: f32 = 28;
const list_w: f32 = 272;
const right_x: f32 = margin + list_w + 24;
const right_w: f32 = width - right_x - margin;
const footer_y: f32 = height - 84;

pub fn draw(
    session: *desktop.combo_editor.Session,
    model: *const desktop.model.Model,
    theme: ui.Theme,
    diagnostic: []const u8,
    board: Board,
) !?Result {
    const sheet = ui.sheet(@src(), theme, width, height, "combo.sheet");
    defer sheet.deinit();
    var muted = theme;
    muted.text = theme.muted;
    var result: ?Result = null;
    const explanation = "Press two keys together within the timeout to send one action. Each combo belongs to a layer.";
    if (ui.sheetHeader(theme, width, "Combos", explanation, "combo.dismiss")) result = .close;
    ui.divider(theme, .{ .x = 0, .y = footer_y, .w = width, .h = 1 }, 1);
    if (!try session.fresh(model)) {
        ui.label(theme, "This layout changed while the combo editor was open.", .{ .x = margin, .y = 124, .w = 800, .h = 22 }, 15);
        ui.label(muted, "Close it and open Combos again to continue.", .{ .x = margin, .y = 150, .w = 800, .h = 20 }, 13);
        const close = ui.iconButton(theme, null, "Close", "combo.close", .{ .x = width - margin - 104, .y = footer_y + 22, .w = 104, .h = 40 }, false);
        return if (close or result != null) .close else null;
    }
    const doc = model.document();
    session.layer = @min(session.layer, doc.layers.len - 1);
    try drawList(session, model, theme, board);
    try drawPreview(session, doc, theme, board);
    try drawKeys(session, doc, theme, board, sheet.data().id);
    drawLayerAndTimeout(session, doc, theme);
    ui.divider(theme, .{ .x = right_x, .y = 470, .w = right_w, .h = 1 }, 2);
    var heading = theme;
    heading.text = theme.text;
    ui.label(heading, "Action", .{ .x = right_x, .y = 484, .w = 200, .h = 22 }, 18);
    {
        const body = dvui.scrollArea(@src(), .{}, .{
            .rect = .{ .x = right_x - 4, .y = 516, .w = right_w + 8, .h = footer_y - 12 - 516 },
            .padding = .{ .x = 4, .w = 8 },
            .background = false,
        });
        defer body.deinit();
        try forms.draw(&session.draft, doc, theme, .{ .inherit = false });
    }
    try drawFooter(session, doc, theme, diagnostic, &result);
    return result;
}

/// The tap legend the canvas draws for key `index` on `layer`, falling
/// through transparent keys.
fn legend(board: Board, layer: usize, index: usize) []const u8 {
    if (index >= board.labels.key_count or board.labels.layer_count == 0) return "";
    var current = @min(layer, board.labels.layer_count - 1);
    while (true) {
        const entry = board.labels.lookup(current, index, .{});
        const transparent = if (entry.label) |value| std.mem.eql(u8, value, "---") else false;
        if (!transparent or current == 0) {
            const caption = entry.caption orelse entry.label orelse "";
            if (transparent) return "";
            const end = std.mem.indexOfScalar(u8, caption, '\n') orelse caption.len;
            return caption[0..end];
        }
        current -= 1;
    }
}

fn layerIndex(doc: p.Document, id: p.LayerId) usize {
    for (doc.layers, 0..) |layer, index| if (layer.id == id) return index;
    return 0;
}

fn keyIndex(doc: p.Document, id: []const u8) ?usize {
    for (doc.key_ids, 0..) |key, index| if (std.mem.eql(u8, key, id)) return index;
    return null;
}

/// A keycap face with a caption, outlined in the layer color.
fn keycap(theme: ui.Theme, bounds: dvui.Rect, caption: []const u8, layer: usize, size: f32, id: usize) void {
    const tint = ui.layerColor(theme, layer);
    const face = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.keycap },
        .color_border = .{ .color = ui.mix(theme.keycap, tint, 0.8) },
        .border = .all(if (bounds.w > 40) 2 else 1.5),
        .corners = .all(bounds.w * 0.16),
        .padding = .{},
        .margin = .{},
    });
    face.deinit();
    const inset = bounds.w * 0.14;
    var style = theme.captionStyle(size, id);
    style.secondary_scale = 0.6;
    ui.caption(caption, .{ .x = bounds.x + inset, .y = bounds.y + inset, .w = bounds.w - inset * 2, .h = bounds.h - inset * 2 }, style);
}

/// A small muted glyph between keycaps, such as "+".
fn joiner(theme: ui.Theme, value: []const u8, bounds: dvui.Rect, size: f32, id: usize) void {
    var opts = ui.options(theme, bounds, size);
    opts.id_extra = id;
    opts.padding = .{};
    opts.background = false;
    opts.color_text = .{ .color = theme.muted };
    dvui.labelNoFmt(@src(), value, .{ .align_x = 0.5, .align_y = 0.5 }, opts);
}

fn arrow(theme: ui.Theme, bounds: dvui.Rect, id: usize) void {
    dvui.icon(@src(), "combo.arrow", ui.control_icons.forward, .{}, .{
        .id_extra = id,
        .rect = bounds,
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
}

/// What an action does, spelled out for the list and the preview title.
fn spell(value: ?p.Action, doc: p.Document, buffer: []u8) []const u8 {
    var tap_buffer: [256]u8 = undefined;
    var hold_buffer: [256]u8 = undefined;
    const action = value orelse return "Inherited";
    return switch (action) {
        .none => "No action",
        .tap_only => |tap| labels.tap(tap, buffer),
        .tap_with_autofire => |autofire| std.fmt.bufPrint(buffer, "{s} · repeats", .{labels.tap(autofire.tap, &tap_buffer)}) catch "Autofire",
        .tap_hold => |both| std.fmt.bufPrint(buffer, "{s} · hold {s}", .{
            labels.tap(both.tap, &tap_buffer),
            labels.hold(both.hold, doc, &hold_buffer),
        }) catch "Tap / hold",
        .hold_only => |hold| std.fmt.bufPrint(buffer, "Hold {s}", .{labels.hold(hold, doc, &hold_buffer)}) catch "Hold",
    };
}

/// The short name of an action in the list: its tap, or what it holds.
fn rowTitle(value: ?p.Action, buffer: []u8) []const u8 {
    const action = value orelse return "Inherited";
    return switch (action) {
        .none => "No action",
        .tap_only => |tap| labels.tap(tap, buffer),
        .tap_with_autofire => |autofire| labels.tap(autofire.tap, buffer),
        .tap_hold => |both| labels.tap(both.tap, buffer),
        .hold_only => "Hold",
    };
}

fn modeName(mode: usize) []const u8 {
    return switch (mode) {
        1 => "no action",
        2 => "tap only",
        3 => "hold only",
        4 => "tap–hold",
        5 => "autofire",
        else => "inherited",
    };
}

/// The combo list: count, New combo, then one row per combo.
fn drawList(session: *desktop.combo_editor.Session, model: *const desktop.model.Model, theme: ui.Theme, board: Board) !void {
    const doc = model.document();
    const arena = dvui.currentWindow().arena();
    var muted = theme;
    muted.text = theme.muted;
    const count = try std.fmt.allocPrint(arena, "{d} {s}", .{ doc.combos.len, if (doc.combos.len == 1) "combo" else "combos" });
    ui.label(muted, count, .{ .x = margin, .y = 122, .w = 140, .h = 18 }, 13);
    if (ui.iconButton(theme, ui.control_icons.add, "New combo", "combo.new", .{ .x = margin + list_w - 132, .y = 114, .w = 132, .h = 32 }, false)) session.new();
    const top: f32 = 158;
    const bottom = footer_y - 52;
    const frame = dvui.box(@src(), .{}, .{
        .rect = .{ .x = margin, .y = top, .w = list_w, .h = bottom - top },
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .all(6),
        .margin = .{},
    });
    defer {
        frame.deinit();
        dvui.icon(@src(), "combo.info", ui.control_icons.info, .{}, .{
            .rect = .{ .x = margin + 2, .y = bottom + 17, .w = 15, .h = 15 },
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
        ui.label(muted, "A combo fires only on its own layer.", .{ .x = margin + 24, .y = bottom + 15, .w = list_w - 24, .h = 18 }, 12);
    }
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = .{} });
    defer scroll.deinit();
    const row_h: f32 = 58;
    const rows = doc.combos.len + @intFromBool(session.index == null);
    const content = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = list_w - 24, .h = @as(f32, @floatFromInt(rows)) * (row_h + 6) },
        .padding = .{},
        .margin = .{},
    });
    defer content.deinit();
    const row_w = list_w - 26;
    var y: f32 = 0;
    // An unsaved combo is listed first and selected.
    if (session.index == null) {
        _ = drawRowFrame(theme, .{ .x = 0, .y = y, .w = row_w, .h = row_h }, true, doc.combos.len, "combo.row.new");
        const layer = session.layer;
        drawRowContent(theme, doc, board, .{
            .keys = .{ session.keys[0], session.keys[1] },
            .layer = layer,
            .action = session.draft.action(),
            .title_override = "New combo",
        }, y, doc.combos.len + 1);
        y += row_h + 6;
    }
    for (doc.combos, 0..) |combo, index| {
        const bounds: dvui.Rect = .{ .x = 0, .y = y, .w = row_w, .h = row_h };
        const tag = try std.fmt.allocPrint(arena, "combo.row.{d}", .{index});
        if (drawRowFrame(theme, bounds, session.index == index, index, tag)) try session.pick(model, index);
        drawRowContent(theme, doc, board, .{
            .keys = .{ keyIndex(doc, combo.key_ids[0]), keyIndex(doc, combo.key_ids[1]) },
            .layer = layerIndex(doc, combo.layer_id),
            .action = combo.action,
        }, y, index);
        y += row_h + 6;
    }
}

/// A clickable list row; the selected row is outlined in the accent color.
fn drawRowFrame(theme: ui.Theme, bounds: dvui.Rect, selected: bool, id: usize, tag: []const u8) bool {
    return dvui.button(@src(), "", .{}, .{
        .id_extra = id,
        .tag = tag,
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = if (selected) ui.mix(theme.panel, theme.accent, 0.14) else theme.panel },
        .color_border = .{ .color = if (selected) theme.accent else theme.border },
        .border = .all(if (selected) 1.5 else 1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
    });
}

const RowContent = struct {
    keys: [2]?usize,
    layer: usize,
    action: ?p.Action,
    title_override: ?[]const u8 = null,
};

fn drawRowContent(theme: ui.Theme, doc: p.Document, board: Board, row: RowContent, y: f32, id: usize) void {
    const cap: f32 = 32;
    const top = y + 13;
    var x: f32 = 10;
    for (row.keys, 0..) |key, slot| {
        const caption = if (key) |index| legend(board, row.layer, index) else "?";
        keycap(theme, .{ .x = x, .y = top, .w = cap, .h = cap }, caption, row.layer, 15, id *% 8 +% slot);
        x += cap;
        if (slot == 0) {
            joiner(theme, "+", .{ .x = x, .y = top, .w = 14, .h = cap }, 13, id *% 8 +% 2);
            x += 14;
        }
    }
    arrow(theme, .{ .x = x + 3, .y = top + 9, .w = 14, .h = 14 }, id *% 8 +% 3);
    x += 20;
    var buffer: [256]u8 = undefined;
    keycap(theme, .{ .x = x, .y = top, .w = cap, .h = cap }, labels.keycap(row.action, doc, &buffer), row.layer, 15, id *% 8 +% 4);
    x += cap + 10;
    var spelled: [256]u8 = undefined;
    const title = row.title_override orelse rowTitle(row.action, &spelled);
    ui.caption(title, .{ .x = x, .y = y + 9, .w = list_w - 32 - x, .h = 20 }, .{
        .color = theme.text,
        .secondary = theme.text,
        .size = 14,
        .align_x = 0,
        .id_extra = id *% 8 +% 5,
        .layers = theme.layers,
    });
    dot(theme, .{ .x = x, .y = y + 36, .w = 7, .h = 7 }, row.layer, id *% 8 +% 6);
    var muted = theme;
    muted.text = theme.muted;
    const name = if (row.layer < doc.layers.len) doc.layers[row.layer].name else "";
    ui.label(muted, name, .{ .x = x + 12, .y = y + 31, .w = list_w - 44 - x, .h = 16 }, 12);
}

fn dot(theme: ui.Theme, bounds: dvui.Rect, layer: usize, id: usize) void {
    const circle = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = ui.layerColor(theme, layer) },
        .corners = .all(bounds.w / 2),
        .padding = .{},
        .margin = .{},
    });
    circle.deinit();
}

/// The edited combo as keycaps, the spelled-out action and a summary line.
fn drawPreview(session: *desktop.combo_editor.Session, doc: p.Document, theme: ui.Theme, board: Board) !void {
    const cap: f32 = 58;
    const top: f32 = 120;
    var x = right_x;
    for (session.keys, 0..) |key, slot| {
        keycap(theme, .{ .x = x, .y = top, .w = cap, .h = cap }, legend(board, session.layer, key), session.layer, 26, 900 + slot);
        x += cap;
        if (slot == 0) {
            joiner(theme, "+", .{ .x = x, .y = top, .w = 24, .h = cap }, 20, 902);
            x += 24;
        }
    }
    arrow(theme, .{ .x = x + 9, .y = top + 19, .w = 20, .h = 20 }, 903);
    x += 38;
    const action = session.draft.action();
    var buffer: [256]u8 = undefined;
    keycap(theme, .{ .x = x, .y = top, .w = cap, .h = cap }, labels.keycap(action, doc, &buffer), session.layer, 26, 904);
    x += cap + 20;
    var spelled: [256]u8 = undefined;
    ui.caption(spell(action, doc, &spelled), .{ .x = x, .y = top + 4, .w = width - margin - x, .h = 26 }, .{
        .color = theme.text,
        .secondary = theme.text,
        .size = 19,
        .align_x = 0,
        .id_extra = 905,
        .layers = theme.layers,
    });
    const detail = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} + {s} on {s} · within {d} ms · {s}", .{
        doc.key_ids[session.keys[0]],
        doc.key_ids[session.keys[1]],
        doc.layers[session.layer].name,
        session.timeout,
        modeName(session.draft.mode),
    });
    var muted = theme;
    muted.text = theme.muted;
    ui.label(muted, detail, .{ .x = x, .y = top + 36, .w = width - margin - x, .h = 18 }, 13);
}

/// The two keys: a clickable keyboard and two lists. A click on the keyboard
/// replaces the key that was chosen longer ago.
fn drawKeys(session: *desktop.combo_editor.Session, doc: p.Document, theme: ui.Theme, board: Board, sheet_id: dvui.Id) !void {
    var muted = theme;
    muted.text = theme.muted;
    ui.label(muted, "Keys · click two keys or choose them from the lists", .{ .x = right_x, .y = 206, .w = 400, .h = 18 }, 13);
    const area: dvui.Rect = .{ .x = right_x, .y = 230, .w = 352, .h = 140 };
    var next = dvui.dataGet(null, sheet_id, "next_key", usize) orelse 1;
    const fitted = desktop.physical_view.fit(board.geometry, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h });
    const tint = ui.layerColor(theme, session.layer);
    if (std.math.isFinite(fitted.scale) and fitted.scale > 0) for (board.geometry, 0..) |item, order| {
        const placed = fitted.place(item);
        const index = placed.key_index;
        if (index >= doc.key_ids.len) continue;
        const gap = @max(1, fitted.scale * 0.06);
        const rect: dvui.Rect = .{ .x = placed.rect.x + gap, .y = placed.rect.y + gap, .w = @max(1, placed.rect.w - gap * 2), .h = @max(1, placed.rect.h - gap * 2) };
        const picked = session.keys[0] == index or session.keys[1] == index;
        const tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "combo.key.{d}", .{index});
        if (dvui.button(@src(), "", .{}, .{
            .id_extra = order,
            .tag = tag,
            .rect = rect,
            .background = true,
            .color_fill = .{ .color = if (picked) tint else theme.keycap },
            .color_border = .{ .color = if (picked) tint else ui.mix(theme.keycap, tint, 0.45) },
            .border = .all(1),
            .corners = .all(@max(2, rect.w * 0.14)),
            .padding = .{},
            .margin = .{},
        }) and !picked) {
            session.keys[next] = index;
            next = 1 - next;
        }
        const inset = rect.w * 0.12;
        var style = theme.captionStyle(rect.w * 0.5, 2000 + order);
        if (picked) style.color = ui.color(0xFFFFFF);
        ui.caption(legend(board, session.layer, index), .{ .x = rect.x + inset, .y = rect.y + inset, .w = rect.w - inset * 2, .h = rect.h - inset * 2 }, style);
    };
    dvui.dataSet(null, sheet_id, "next_key", next);

    const arena = dvui.currentWindow().arena();
    const names = try arena.alloc([]const u8, doc.key_ids.len);
    for (names, doc.key_ids, 0..) |*name, id, index| {
        var plain: [64]u8 = undefined;
        const text = labels.keycap_symbols.plain(legend(board, session.layer, index), &plain);
        name.* = if (text.len == 0) id else try std.fmt.allocPrint(arena, "{s} · {s}", .{ text, id });
    }
    const list_x = area.x + area.w + 24;
    const list_w2 = width - margin - list_x;
    inline for (.{ "First key", "Second key" }, 0..) |title, slot| {
        const y: f32 = 226 + @as(f32, slot) * 72;
        ui.label(muted, title, .{ .x = list_x, .y = y, .w = list_w2, .h = 18 }, 12);
        var opts = ui.options(theme, .{ .x = list_x, .y = y + 22, .w = list_w2, .h = 38 }, 14);
        opts.id_extra = slot;
        opts.tag = if (slot == 0) "combo.first" else "combo.second";
        opts.corners = .all(8);
        opts.border = .all(1);
        opts.background = true;
        if (dvui.dropdown(@src(), names, .{ .choice = &session.keys[slot] }, .{}, opts)) dvui.dataSet(null, sheet_id, "next_key", @as(usize, 1 - slot));
    }
}

fn drawLayerAndTimeout(session: *desktop.combo_editor.Session, doc: p.Document, theme: ui.Theme) void {
    var muted = theme;
    muted.text = theme.muted;
    ui.label(muted, "Layer", .{ .x = right_x, .y = 388, .w = 200, .h = 18 }, 12);
    var layer_names: [16][]const u8 = undefined;
    for (doc.layers, 0..) |layer, index| layer_names[index] = layer.name;
    var opts = ui.options(theme, .{ .x = right_x, .y = 410, .w = 352, .h = 38 }, 14);
    opts.tag = "combo.layer";
    opts.corners = .all(8);
    opts.border = .all(1);
    opts.background = true;
    opts.padding = .{ .x = 42, .y = 6, .w = 10, .h = 6 };
    _ = dvui.dropdown(@src(), layer_names[0..doc.layers.len], .{ .choice = &session.layer }, .{}, opts);
    // The layer's number badge in its color, over the dropdown's left edge.
    const badge: dvui.Rect = .{ .x = right_x + 10, .y = 419, .w = 22, .h = 20 };
    const box = dvui.box(@src(), .{}, .{
        .rect = badge,
        .background = true,
        .color_fill = .{ .color = ui.layerColor(theme, session.layer) },
        .corners = .all(5),
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
    var white = theme;
    white.text = ui.color(0xFFFFFF);
    var digits: [4]u8 = undefined;
    const number = std.fmt.bufPrint(&digits, "{d}", .{session.layer}) catch "?";
    var badge_opts = ui.options(white, badge, 12);
    badge_opts.padding = .{};
    badge_opts.background = false;
    badge_opts.font = ui.editorFont(number, 12).withWeight(.bold);
    dvui.labelNoFmt(@src(), number, .{ .align_x = 0.5, .align_y = 0.5 }, badge_opts);

    const timeout_x = right_x + 352 + 24;
    ui.label(muted, "Timeout", .{ .x = timeout_x, .y = 388, .w = 200, .h = 18 }, 12);
    var field = ui.options(theme, .{ .x = timeout_x, .y = 410, .w = 110, .h = 38 }, 14);
    field.tag = "combo.timeout";
    field.corners = .all(8);
    field.border = .all(1);
    field.background = true;
    _ = dvui.textEntryNumber(@src(), u16, .{ .value = &session.timeout }, field);
    ui.label(muted, "ms", .{ .x = timeout_x + 120, .y = 420, .w = 40, .h = 18 }, 13);
}

fn drawFooter(session: *desktop.combo_editor.Session, doc: p.Document, theme: ui.Theme, diagnostic: []const u8, result: *?Result) !void {
    const y = footer_y + 22;
    var status_x: f32 = margin;
    if (session.index != null) {
        if (ui.dangerButton(theme, ui.control_icons.delete, "Delete combo", "combo.delete", .{ .x = margin, .y = y, .w = 164, .h = 40 }) and result.* == null)
            result.* = .{ .action = session.action(.delete) };
        status_x += 180;
    }
    var status = theme;
    status.text = if (diagnostic.len != 0) theme.danger else theme.muted;
    const message = if (diagnostic.len != 0)
        diagnostic
    else if (session.index) |index|
        try std.fmt.allocPrint(dvui.currentWindow().arena(), "Editing {s} + {s}", .{ doc.combos[index].key_ids[0], doc.combos[index].key_ids[1] })
    else
        "New combo · not saved yet";
    ui.label(status, message, .{ .x = status_x, .y = y + 11, .w = width - status_x - 300, .h = 18 }, 13);
    const save_x = width - margin - 150;
    if (ui.iconButton(theme, null, "Close", "combo.close", .{ .x = save_x - 116, .y = y, .w = 104, .h = 40 }, false) and result.* == null) result.* = .close;
    if (ui.iconButton(theme, null, "Save combo", "combo.save", .{ .x = save_x, .y = y, .w = 150, .h = 40 }, true) and result.* == null)
        result.* = .{ .action = session.action(.save) };
}
