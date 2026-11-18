//! Retained encoder action drawer. Slots have no invented hardware direction.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const forms = @import("action-form-ui");

pub const Result = union(enum) { close, action: desktop.encoder_editor.Action };

pub fn draw(session: *desktop.encoder_editor.Session, model: *const desktop.model.Model, theme: ui.Theme, diagnostic: []const u8) !?Result {
    const window = ui.editDrawer(@src(), theme, 900);
    defer window.deinit();
    const size = window.data().rect;
    const footer_y = size.h - 86;
    dvui.label(@src(), "Encoder actions · independent firmware action slots", .{}, .{});
    if (!try session.fresh(model)) {
        dvui.label(@src(), "Project changed · reopen the encoder editor", .{}, .{});
        return if (ui.button(theme, "Close", "encoder.close", .{ .x = 0, .y = footer_y, .w = 100, .h = 40 })) .close else null;
    }
    var result: ?Result = null;
    {
        const body = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 0, .y = 36, .w = size.w - 36, .h = size.h - 160 } });
        defer body.deinit();
        dvui.label(@src(), "{d} action slots · direction and physical mapping require the board contract", .{session.count}, .{});
        if (session.count == 0) {
            dvui.label(@src(), "This project has no encoder action slots", .{}, .{});
        } else {
            const arena = dvui.currentWindow().arena();
            const names = try arena.alloc([]const u8, session.count);
            for (names, 0..) |*name, index| name.* = try std.fmt.allocPrint(arena, "Action slot {d}", .{index});
            _ = dvui.dropdown(@src(), names, .{ .choice = &session.index }, .{}, .{ .expand = .horizontal });
            if (session.index >= session.count) return error.InvalidEncoderDimensions;
            try forms.tap(&session.drafts[session.index], model.document());
        }
        dvui.labelNoFmt(@src(), diagnostic, .{}, .{});
    }
    if (session.dirty()) {
        if (ui.button(theme, "Apply", "encoder.apply", .{ .x = 120, .y = footer_y, .w = 100, .h = 40 })) {
            result = .{ .action = session.action(.apply) };
        }
        const discard: dvui.Rect = .{ .x = 230, .y = footer_y, .w = 150, .h = 40 };
        if (ui.button(theme, "Discard edits", "encoder.discard", discard) and result == null) {
            result = .{ .action = session.action(.discard) };
        }
    }
    // Closing preserves no document changes; staged slot edits are local only.
    const dirty = session.dirty();
    const close: dvui.Rect = .{ .x = 0, .y = footer_y, .w = if (dirty) 190 else 100, .h = 40 };
    if (ui.button(theme, if (dirty) "Close · discard edits" else "Close", "encoder.close", close) and result == null) result = .close;
    return result;
}
