//! Owned form drawer. Buttons return intent; only Session.apply commits a model.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const forms = @import("action-form-ui");

pub const Intent = enum { none, apply, cancel };

pub fn draw(session: *desktop.action_form.Session, model: *const desktop.model.Model, theme: ui.Theme, bounds: dvui.Rect) !Intent {
    const window = ui.drawer(@src(), theme, bounds, true);
    defer window.deinit();
    const status = try session.status(model);
    const title = switch (status) {
        .current => "Edit selected actions",
        .applied => "Actions applied",
        .stale_document => "Project changed · reopen the action editor",
        .stale_selection => "Selection changed · reopen the action editor",
    };
    dvui.labelNoFmt(@src(), title, .{}, .{ .font = dvui.Font.theme(.body).withSize(22) });
    var intent: Intent = .none;
    {
        const content = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer content.deinit();
        const column = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        defer column.deinit();
        if (status == .current) {
            const selected = std.mem.count(bool, session.selected, &.{true});
            dvui.label(@src(), "{d} selected · stable layer {d}", .{ selected, session.layer_id }, .{});
            try forms.draw(&session.draft, model.document(), theme, .{});
        }
    }
    const buttons = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer buttons.deinit();
    const apply = status == .current and dvui.button(@src(), "Apply", .{}, .{ .tag = "action.apply", .min_size_content = .{ .w = 110 } });
    if (apply) intent = .apply;
    if (dvui.button(@src(), "Cancel", .{}, .{ .tag = "action.cancel", .min_size_content = .{ .w = 110 } })) intent = .cancel;
    return intent;
}
