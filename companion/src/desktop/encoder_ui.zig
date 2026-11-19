//! Retained encoder action sheet. Slots have no invented hardware direction:
//! the board definition does not say which slot is which knob or direction.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const forms = @import("action-form-ui");
const labels = desktop.labels;

pub const Result = union(enum) { close, action: desktop.encoder_editor.Action };

const width: f32 = 900;
const height: f32 = 800;
const margin: f32 = 28;
const footer_y: f32 = height - 84;

pub fn draw(session: *desktop.encoder_editor.Session, model: *const desktop.model.Model, theme: ui.Theme, diagnostic: []const u8) !?Result {
    const sheet = ui.sheet(@src(), theme, width, height, "encoder.sheet");
    defer sheet.deinit();
    var muted = theme;
    muted.text = theme.muted;
    var result: ?Result = null;
    const explanation = "Turning a knob sends one action per step. Each action slot is one direction of one knob.";
    if (ui.sheetHeader(theme, width, "Encoders", explanation, "encoder.dismiss")) result = .close;
    ui.divider(theme, .{ .x = 0, .y = footer_y, .w = width, .h = 1 }, 1);
    const button_y = footer_y + 22;
    const close_rect: dvui.Rect = .{ .x = width - margin - 126 - 116, .y = button_y, .w = 104, .h = 40 };
    if (!try session.fresh(model)) {
        ui.label(theme, "This layout changed while the encoder editor was open.", .{ .x = margin, .y = 124, .w = 800, .h = 22 }, 15);
        ui.label(muted, "Close it and open Encoders again to continue.", .{ .x = margin, .y = 150, .w = 800, .h = 20 }, 13);
        if (ui.iconButton(theme, null, "Close", "encoder.close", close_rect, false)) result = .close;
        return result;
    }
    if (session.count == 0) {
        dvui.icon(@src(), "encoder.none", ui.control_icons.encoder, .{}, .{
            .rect = .{ .x = width / 2 - 20, .y = 250, .w = 40, .h = 40 },
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
        var centered = ui.options(theme, .{ .x = 0, .y = 306, .w = width, .h = 24 }, 17);
        centered.padding = .{};
        centered.background = false;
        dvui.labelNoFmt(@src(), "This keyboard has no encoders", .{ .align_x = 0.5 }, centered);
        centered.rect = .{ .x = 0, .y = 334, .w = width, .h = 20 };
        centered.font = ui.editorFont("", 13);
        centered.color_text = .{ .color = theme.muted };
        dvui.labelNoFmt(@src(), "Its board definition declares no encoder action slots.", .{ .align_x = 0.5 }, centered);
    } else {
        if (session.index >= session.count) return error.InvalidEncoderDimensions;
        const slots_bottom = try drawSlots(session, model, theme);
        ui.divider(theme, .{ .x = margin, .y = slots_bottom + 14, .w = width - 2 * margin, .h = 1 }, 2);
        const heading_y = slots_bottom + 32;
        var heading_buffer: [32]u8 = undefined;
        const heading = std.fmt.bufPrint(&heading_buffer, "Action slot {d}", .{session.index}) catch "Action slot";
        ui.label(theme, heading, .{ .x = margin, .y = heading_y, .w = 400, .h = 24 }, 18);
        var right = ui.options(muted, .{ .x = width - margin - 300, .y = heading_y + 4, .w = 300, .h = 18 }, 13);
        right.padding = .{};
        right.background = false;
        dvui.labelNoFmt(@src(), "Sends one action per step", .{ .align_x = 1 }, right);
        {
            const body_y = heading_y + 36;
            const body = dvui.scrollArea(@src(), .{}, .{
                .rect = .{ .x = margin - 4, .y = body_y, .w = width - 2 * margin + 8, .h = footer_y - 48 - body_y },
                .padding = .{ .x = 4, .w = 8 },
                .background = false,
            });
            defer body.deinit();
            try forms.tap(&session.drafts[session.index], model.document(), theme);
        }
        dvui.icon(@src(), "encoder.info", ui.control_icons.info, .{}, .{
            .rect = .{ .x = margin, .y = footer_y - 32, .w = 15, .h = 15 },
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
        ui.label(muted, "Directions come from the board definition. Without one, slots are listed as Action slot 0, 1, …", .{
            .x = margin + 24,
            .y = footer_y - 34,
            .w = width - 2 * margin - 24,
            .h = 18,
        }, 12);
    }

    var changed: usize = 0;
    for (session.original[0..session.count], session.drafts[0..session.count]) |original, draft| {
        if (!std.meta.eql(original, draft)) changed += 1;
    }
    var status_x: f32 = margin;
    if (changed != 0) {
        if (ui.iconButton(theme, null, "Discard edits", "encoder.discard", .{ .x = margin, .y = button_y, .w = 150, .h = 40 }, false) and result == null)
            result = .{ .action = session.action(.discard) };
        status_x += 166;
    }
    var status = theme;
    status.text = if (diagnostic.len != 0) theme.danger else theme.muted;
    var status_buffer: [96]u8 = undefined;
    const message = if (diagnostic.len != 0)
        diagnostic
    else if (changed == 0)
        "No changes"
    else
        std.fmt.bufPrint(&status_buffer, "{d} {s} not applied · Close discards {s}", .{
            changed,
            if (changed == 1) "change" else "changes",
            if (changed == 1) "it" else "them",
        }) catch "Changes not applied";
    ui.label(status, message, .{ .x = status_x, .y = button_y + 11, .w = close_rect.x - status_x - 12, .h = 18 }, 13);
    // Closing keeps no document changes; staged slot edits are local only.
    if (ui.iconButton(theme, null, "Close", "encoder.close", close_rect, false) and result == null) result = .close;
    const apply = ui.iconButtonEnabled(theme, null, "Apply", "encoder.apply", .{ .x = width - margin - 126, .y = button_y, .w = 126, .h = 40 }, true, changed != 0);
    if (apply and result == null) result = .{ .action = session.action(.apply) };
    return result;
}

/// The action slots in two columns, each with its keycap and spelled action.
/// Returns the bottom of the slot area.
fn drawSlots(session: *desktop.encoder_editor.Session, model: *const desktop.model.Model, theme: ui.Theme) !f32 {
    const doc = model.document();
    const top: f32 = 120;
    const row_h: f32 = 52;
    const gap: f32 = 10;
    const column_w = (width - 2 * margin - gap) / 2;
    const rows = (session.count + 1) / 2;
    const area_h = @min(@as(f32, 4 * (row_h + gap)), @as(f32, @floatFromInt(rows)) * (row_h + gap));
    const scroll = dvui.scrollArea(@src(), .{}, .{
        .rect = .{ .x = margin, .y = top, .w = width - 2 * margin + 10, .h = area_h },
        .background = false,
        .padding = .{},
    });
    defer scroll.deinit();
    const content = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = width - 2 * margin, .h = @as(f32, @floatFromInt(rows)) * (row_h + gap) },
        .padding = .{},
        .margin = .{},
    });
    defer content.deinit();
    const arena = dvui.currentWindow().arena();
    var muted = theme;
    muted.text = theme.muted;
    for (0..session.count) |index| {
        const x = @as(f32, @floatFromInt(index % 2)) * (column_w + gap);
        const y = @as(f32, @floatFromInt(index / 2)) * (row_h + gap);
        const selected = session.index == index;
        const edited = !std.meta.eql(session.original[index], session.drafts[index]);
        const tag = try std.fmt.allocPrint(arena, "encoder.slot.{d}", .{index});
        if (dvui.button(@src(), "", .{}, .{
            .id_extra = index,
            .tag = tag,
            .rect = .{ .x = x, .y = y, .w = column_w, .h = row_h },
            .background = true,
            .color_fill = .{ .color = if (selected) ui.mix(theme.panel, theme.accent, 0.14) else theme.bg },
            .color_border = .{ .color = if (selected) theme.accent else theme.border },
            .border = .all(if (selected) 1.5 else 1),
            .corners = .all(9),
            .padding = .{},
            .margin = .{},
        })) session.index = index;
        dvui.icon(@src(), "encoder.slot", ui.control_icons.encoder, .{}, .{
            .id_extra = index,
            .rect = .{ .x = x + 16, .y = y + 17, .w = 18, .h = 18 },
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
        const name = try std.fmt.allocPrint(arena, "Action slot {d}", .{index});
        ui.label(theme, name, .{ .x = x + 44, .y = y + 16, .w = 130, .h = 20 }, 14);
        const tap = session.drafts[index];
        const empty = std.meta.eql(tap, @as(@TypeOf(tap), .{}));
        var buffer: [256]u8 = undefined;
        const spelled = if (empty) "Nothing" else labels.tap(tap, &buffer);
        const keycap_x = x + 176;
        if (!empty) {
            const face = dvui.box(@src(), .{}, .{
                .id_extra = index,
                .rect = .{ .x = keycap_x, .y = y + 10, .w = 32, .h = 32 },
                .background = true,
                .color_fill = .{ .color = theme.keycap },
                .color_border = .{ .color = ui.mix(theme.keycap, ui.layerColor(theme, 0), 0.65) },
                .border = .all(1.5),
                .corners = .all(6),
                .padding = .{},
                .margin = .{},
            });
            face.deinit();
            var cap_buffer: [256]u8 = undefined;
            ui.caption(labels.keycap(.{ .tap_only = tap }, doc, &cap_buffer), .{ .x = keycap_x + 4, .y = y + 14, .w = 24, .h = 24 }, theme.captionStyle(15, 300 + index));
        }
        const text_x = if (empty) keycap_x else keycap_x + 44;
        ui.caption(spelled, .{ .x = text_x, .y = y + 16, .w = column_w - (text_x - x) - 30, .h = 20 }, .{
            .color = if (empty) theme.muted else theme.text,
            .secondary = theme.muted,
            .size = 14,
            .align_x = 0,
            .id_extra = 600 + index,
            .layers = theme.layers,
        });
        if (edited) {
            const dot = dvui.box(@src(), .{}, .{
                .id_extra = index,
                .rect = .{ .x = x + column_w - 22, .y = y + row_h / 2 - 4, .w = 8, .h = 8 },
                .background = true,
                .color_fill = .{ .color = theme.accent },
                .corners = .all(4),
                .padding = .{},
                .margin = .{},
            });
            dot.deinit();
        }
    }
    return top + area_h;
}
