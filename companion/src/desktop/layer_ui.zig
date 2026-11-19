//! Retained layer sidebar; draw returns one immutable document-operation intent.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const LayerId = @import("project").LayerId;

pub const View = struct {
    observed: ?[32]u8 = null,
    selected: ?LayerId = null,
    name: [129]u8 = @splat(0),
};

const row_pitch: f32 = 56;
const row_height: f32 = 48;
/// Rows visible before the list scrolls; the rename field follows the list.
const visible_rows = 10;

pub fn draw(view: *View, model: *const desktop.model.Model, theme: ui.Theme) !?desktop.layer_editor.Action {
    const digest = try model.id();
    const doc = model.document();
    const selected = doc.layers[model.layer];
    // Reload the name field when the document or the selected layer changes.
    if (view.observed == null or !std.mem.eql(u8, &view.observed.?, &digest) or view.selected != selected.id) {
        view.name = @splat(0);
        @memcpy(view.name[0..selected.name.len], selected.name);
        view.observed = digest;
        view.selected = selected.id;
    }
    const box = ui.panel(theme, .sidebar);
    defer box.deinit();
    var result: ?desktop.layer_editor.Action = null;
    ui.label(theme, "Layers", .{ .x = 20, .y = 20, .w = 160, .h = 26 }, 19);
    if (ui.iconButton(theme, ui.control_icons.add, "", "layer.add", .{ .x = 196, .y = 12, .w = 32, .h = 32 }, false)) {
        result = try desktop.layer_editor.capture(model, .add, selected.id, "");
    }
    const shown: f32 = @floatFromInt(@min(doc.layers.len, visible_rows));
    const list_height = shown * row_pitch;
    {
        const area = dvui.scrollArea(@src(), .{}, .{
            .rect = .{ .x = 12, .y = 52, .w = 216, .h = list_height },
            .padding = .{},
            .margin = .{},
            .background = false,
        });
        defer area.deinit();
        const list = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = 216, .h = @as(f32, @floatFromInt(doc.layers.len)) * row_pitch },
            .padding = .{},
            .background = false,
        });
        defer list.deinit();
        for (doc.layers, 0..) |layer, i| {
            if (try drawRow(model, layer, i, theme)) |action| {
                if (result == null) result = try desktop.layer_editor.capture(model, action, layer.id, "");
            }
        }
    }
    const rename_y = 52 + list_height + 18;
    var muted = theme;
    muted.text = theme.muted;
    ui.label(muted, "Layer name", .{ .x = 20, .y = rename_y, .w = 200, .h = 18 }, 12);
    const rename = dvui.textEntry(
        @src(),
        .{ .text = .{ .buffer = &view.name } },
        ui.options(theme, .{ .x = 12, .y = rename_y + 22, .w = 148, .h = 34 }, 14),
    );
    const enter = rename.enter_pressed;
    rename.deinit();
    const rename_clicked = ui.iconButton(theme, null, "Rename", "layer.rename", .{ .x = 166, .y = rename_y + 22, .w = 62, .h = 34 }, false);
    if ((enter or rename_clicked) and result == null) {
        result = try desktop.layer_editor.capture(model, .rename, selected.id, std.mem.sliceTo(&view.name, 0));
    }
    return result;
}

/// Draws one layer row: a select area, the colored position badge, the name
/// and the duplicate and delete buttons. The selected row is tinted with its
/// layer color. Returns the operation the user requested.
fn drawRow(model: *const desktop.model.Model, layer: anytype, i: usize, theme: ui.Theme) !?desktop.layer_editor.Kind {
    const arena = dvui.currentWindow().arena();
    const y = @as(f32, @floatFromInt(i)) * row_pitch;
    const accent = ui.layerColor(theme, i);
    const current = model.layer == i;
    var requested: ?desktop.layer_editor.Kind = null;
    var opts = ui.options(theme, .{ .x = 0, .y = y, .w = 216, .h = row_height }, 15);
    opts.id_extra = i;
    opts.tag = try std.fmt.allocPrint(arena, "layer.select.{d}", .{layer.id});
    opts.corners = .all(10);
    {
        var background = opts;
        background.id_extra = 1000 + i;
        background.tag = null;
        background.background = current;
        background.color_fill = .{ .color = ui.mix(theme.panel, accent, 0.2) };
        background.color_border = .{ .color = accent };
        background.border = .all(if (current) 1.5 else 0);
        const card = dvui.box(@src(), .{}, background);
        card.deinit();
    }
    // The select button leaves room for the duplicate and delete buttons.
    opts.background = false;
    opts.border = .{};
    opts.rect.?.w = 156;
    if (dvui.button(@src(), "", .{}, opts)) requested = .select;
    const badge = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 12, .y = y + 10, .w = 28, .h = 28 },
        .background = true,
        .color_fill = .{ .color = accent },
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .id_extra = i,
    });
    badge.deinit();
    var number: [4]u8 = undefined;
    var white = theme;
    white.text = ui.color(0xFFFFFF);
    const digits = std.fmt.bufPrint(&number, "{d}", .{i}) catch "?";
    ui.caption(digits, .{ .x = 12, .y = y + 10, .w = 28, .h = 28 }, .{ .color = white.text, .secondary = white.text, .size = 15, .id_extra = 2000 + i });
    ui.caption(layer.name, .{ .x = 52, .y = y, .w = 104, .h = row_height }, .{ .color = theme.text, .secondary = theme.text, .size = 15, .align_x = 0, .id_extra = 3000 + i });
    const duplicate = try std.fmt.allocPrint(arena, "layer.duplicate.{d}", .{layer.id});
    const icons = ui.control_icons;
    if (current) {
        if (ui.iconButton(theme, icons.duplicate, "", duplicate, .{ .x = 158, .y = y + 10, .w = 26, .h = 28 }, false) and requested == null) requested = .duplicate;
        const delete = try std.fmt.allocPrint(arena, "layer.delete.{d}", .{layer.id});
        if (ui.iconButton(theme, icons.remove, "", delete, .{ .x = 186, .y = y + 10, .w = 26, .h = 28 }, false) and requested == null) requested = .delete;
    }
    return requested;
}
