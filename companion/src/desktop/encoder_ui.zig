//! Retained encoder action sheet. Slots are grouped per knob and named by
//! direction, following `desktop.encoder_editor.slot`.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const forms = @import("action-form-ui");
const labels = desktop.labels;
const editor = desktop.encoder_editor;

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
    const explanation = "Turning a knob sends one action per step, one for each direction.";
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
        var heading_buffer: [48]u8 = undefined;
        const heading = editor.slotName(session.index, session.count, &heading_buffer);
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
        ui.label(muted, "A knob's push button is a key on the keyboard; assign it there.", .{
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

/// The action slots grouped per knob, one row of direction cells each, with
/// the slot's keycap and spelled action. A knob's header shows only on boards
/// with several knobs. Returns the bottom of the slot area.
fn drawSlots(session: *desktop.encoder_editor.Session, model: *const desktop.model.Model, theme: ui.Theme) !f32 {
    const top: f32 = 120;
    const row_h: f32 = 52;
    const gap: f32 = 10;
    const knobs = editor.knobs(session.count);
    const header_h: f32 = if (knobs > 1) 26 else 0;
    // A knob's cells, left to right. A future push button slot is one more
    // cell here, or a row of its own below the turns.
    const turns = [_]editor.Direction{ .clockwise, .counter_clockwise };
    const column_w = (width - 2 * margin - gap) / @as(f32, turns.len);
    const group_h = header_h + row_h + 2 * gap;
    const content_h = @as(f32, @floatFromInt(knobs)) * group_h - 2 * gap;
    const area_h = @min(3 * group_h - 2 * gap, content_h);
    const scroll = dvui.scrollArea(@src(), .{}, .{
        .rect = .{ .x = margin, .y = top, .w = width - 2 * margin + 10, .h = area_h },
        .background = false,
        .padding = .{},
    });
    defer scroll.deinit();
    const content = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = width - 2 * margin, .h = content_h },
        .padding = .{},
        .margin = .{},
    });
    defer content.deinit();
    const arena = dvui.currentWindow().arena();
    var muted = theme;
    muted.text = theme.muted;
    for (0..knobs) |knob| {
        const group_y = @as(f32, @floatFromInt(knob)) * group_h;
        if (knobs > 1) {
            const title = try std.fmt.allocPrint(arena, "Knob {d}", .{knob + 1});
            var header = ui.options(muted, .{ .x = 2, .y = group_y, .w = 200, .h = 18 }, 13);
            header.id_extra = knob;
            header.padding = .{};
            header.background = false;
            header.font = ui.editorFont(title, 13).withWeight(.bold);
            dvui.labelNoFmt(@src(), title, .{}, header);
        }
        for (turns, 0..) |direction, column| {
            const index = editor.slotIndex(knob, direction);
            if (index >= session.count) continue;
            try drawSlot(session, model, theme, index, .{
                .x = @as(f32, @floatFromInt(column)) * (column_w + gap),
                .y = group_y + header_h,
                .w = column_w,
                .h = row_h,
            });
        }
    }
    return top + area_h;
}

/// One slot cell: its direction icon and name, keycap and spelled action.
fn drawSlot(session: *desktop.encoder_editor.Session, model: *const desktop.model.Model, theme: ui.Theme, index: usize, bounds: dvui.Rect) !void {
    const doc = model.document();
    const arena = dvui.currentWindow().arena();
    const x = bounds.x;
    const y = bounds.y;
    const column_w = bounds.w;
    const row_h = bounds.h;
    const selected = session.index == index;
    const edited = !std.meta.eql(session.original[index], session.drafts[index]);
    const tag = try std.fmt.allocPrint(arena, "encoder.slot.{d}", .{index});
    if (dvui.button(@src(), "", .{}, .{
        .id_extra = index,
        .tag = tag,
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = if (selected) ui.mix(theme.panel, theme.accent, 0.14) else theme.bg },
        .color_border = .{ .color = if (selected) theme.accent else theme.border },
        .border = .all(if (selected) 1.5 else 1),
        .corners = .all(9),
        .padding = .{},
        .margin = .{},
    })) session.index = index;
    const direction = editor.slot(index).direction;
    dvui.icon(@src(), "encoder.slot", switch (direction) {
        .clockwise => ui.control_icons.clockwise,
        .counter_clockwise => ui.control_icons.counter_clockwise,
    }, .{}, .{
        .id_extra = index,
        .rect = .{ .x = x + 16, .y = y + 17, .w = 18, .h = 18 },
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
    ui.label(theme, direction.name(), .{ .x = x + 44, .y = y + 16, .w = 150, .h = 20 }, 14);
    const tap = session.drafts[index];
    const empty = std.meta.eql(tap, @as(@TypeOf(tap), .{}));
    var buffer: [256]u8 = undefined;
    const spelled = if (empty) "Nothing" else labels.tap(tap, &buffer);
    const keycap_x = x + 200;
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
