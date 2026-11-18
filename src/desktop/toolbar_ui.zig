//! Retained editor head: the Keyboard › Layout breadcrumb, the work flow and
//! the document controls, over explicit layout inventory and build capabilities.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
pub const layout_menu = @import("layout_menu.zig");
const dispatch = desktop.editor_dispatch;

/// Where the open layout stands relative to its saved project.
pub const Save = enum {
    saved,
    /// Edited; an automatic save follows shortly.
    pending,
    saving,
    failed,
    /// Not saved automatically, such as before a project is chosen.
    manual,
};

pub const Frame = struct {
    keyboard_name: []const u8,
    connection: []const u8,
    /// The layouts of this keyboard, for the layout menu.
    layouts: []const layout_menu.Choice = &.{},
    save: Save = .saved,
    build_status: []const u8 = "",
    can_build: bool = false,
    can_flash: bool = false,
    flash_status: []const u8 = "",
    flash_active: bool = false,
    build_active: bool = false,
    first_build: bool = false,
    flash_succeeded: bool = false,
    flash_failed: bool = false,
    diagnostic: []const u8 = "",
    now_ms: u64 = 0,
};

pub const View = struct {
    light: bool = false,
    auto_build: bool = false,
    details_open: bool = false,
    result_hash: u64 = 0,
    result_until: u64 = 0,
    /// Whether the layout menu is open.
    menu_open: bool = false,
    /// The layout menu command chosen this frame, for the application.
    command: ?layout_menu.Command = null,
    /// The layout crumb is a name field while renaming.
    renaming: bool = false,
    rename_frames: u8 = 0,
    rename: [129]u8 = @splat(0),
};

/// Captures `intent` when `clicked`, unless an earlier control already requested one.
fn offer(result: *?dispatch.Request, model: *const desktop.model.Model, clicked: bool, intent: dispatch.Intent) !void {
    if (clicked and result.* == null) result.* = try dispatch.Request.capture(model, intent);
}

/// The head reads Keyboard › Layout, then the order of work: build, flash.
/// Saving is automatic; undo, redo and the theme sit at the right edge.
pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame) !?dispatch.Request {
    const theme = ui.Theme.get(view.light);
    const icons = ui.control_icons;
    const box = ui.panel(theme, .toolbar);
    defer box.deinit();
    const width = box.data().contentRect().w;
    var result: ?dispatch.Request = null;
    view.command = null;
    ui.label(theme, "Zigmkay", .{ .x = 24, .y = 17, .w = 110, .h = 30 }, 23);
    const keyboards = ui.iconButton(theme, icons.keyboard, frame.keyboard_name, "keyboard.collection", .{ .x = 140, .y = 14, .w = 196, .h = 36 }, false);
    try offer(&result, model, keyboards, .{ .open = .keyboards });
    flowArrow(theme, 340);
    const crumb: dvui.Rect = .{ .x = 360, .y = 14, .w = 240, .h = 36 };
    if (view.renaming) {
        try offer(&result, model, drawRename(view, theme, crumb), .{ .rename_layout = view.rename });
    } else if (layout_menu.draw(theme, crumb, model.document().name, frame.layouts, undoHint(), &view.menu_open)) |command| {
        if (command == .rename) startRename(view, model.document().name) else view.command = command;
    }
    drawSave(theme, frame.save);
    const build = ui.iconButtonEnabled(theme, icons.build, "Build", "firmware.build", .{ .x = 820, .y = 14, .w = 118, .h = 36 }, true, frame.can_build);
    try offer(&result, model, build, .build);
    flowArrow(theme, 942);
    const flash_label = if (frame.flash_active) "Flash details" else "Flash";
    const flash_bounds: dvui.Rect = .{ .x = 962, .y = 14, .w = 128, .h = 36 };
    const flash = ui.iconButtonEnabled(theme, icons.flash, flash_label, "firmware.inspect", flash_bounds, true, frame.can_flash or frame.flash_active);
    try offer(&result, model, flash, .flash);
    const right = width - 16;
    const undo = ui.iconButtonEnabled(theme, icons.undo, "", "edit.undo", .{ .x = right - 132, .y = 14, .w = 36, .h = 36 }, false, model.undo_stack.items.len != 0);
    try offer(&result, model, undo, .undo);
    const redo = ui.iconButtonEnabled(theme, icons.redo, "", "edit.redo", .{ .x = right - 90, .y = 14, .w = 36, .h = 36 }, false, model.redo_stack.items.len != 0);
    try offer(&result, model, redo, .redo);
    const theme_icon = if (view.light) icons.dark else icons.light;
    if (ui.iconButton(theme, theme_icon, "", "theme.toggle", .{ .x = right - 36, .y = 14, .w = 36, .h = 36 }, false)) {
        view.light = !view.light;
    }
    drawActivity(view, theme, frame, width);
    return result;
}

fn undoHint() []const u8 {
    return if (@import("builtin").os.tag == .macos)
        "Changes save automatically · ⌘Z undoes"
    else
        "Changes save automatically · Ctrl+Z undoes";
}

fn startRename(view: *View, name: []const u8) void {
    view.rename = @splat(0);
    const len = @min(name.len, view.rename.len - 1);
    @memcpy(view.rename[0..len], name[0..len]);
    view.renaming = true;
    view.rename_frames = 0;
}

/// The layout name as a field. Enter renames; leaving the field cancels.
fn drawRename(view: *View, theme: ui.Theme, bounds: dvui.Rect) bool {
    var opts = ui.options(theme, bounds, 15);
    opts.tag = "layout.rename";
    opts.border = .all(1.5);
    opts.color_border = .{ .color = theme.accent };
    opts.corners = .all(8);
    opts.padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 };
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.rename } }, opts);
    const id = entry.data().id;
    const entered = entry.enter_pressed;
    entry.deinit();
    if (view.rename_frames == 0) dvui.focusWidget(id, null, null);
    view.rename_frames +|= 1;
    const name = std.mem.sliceTo(&view.rename, 0);
    if (entered or (view.rename_frames > 2 and dvui.focusedWidgetId() != id)) view.renaming = false;
    return entered and name.len != 0;
}

/// Whether the layout is saved, shown as a quiet note next to the breadcrumb.
fn drawSave(theme: ui.Theme, save: Save) void {
    const text, const tint, const icon: ?[]const u8 = switch (save) {
        .saved => .{ "Saved", ui.color(0x6EC59A), ui.control_icons.saved },
        .pending => .{ "Edited", theme.muted, null },
        .saving => .{ "Saving…", theme.muted, null },
        .failed => .{ "Save failed · see Details", ui.color(0xF06B73), ui.control_icons.warning },
        .manual => return,
    };
    var x: f32 = 616;
    if (icon) |bytes| {
        dvui.icon(@src(), "save.state", bytes, .{}, .{
            .color_text = .{ .color = tint },
            .rect = .{ .x = x, .y = 25, .w = 14, .h = 14 },
            .padding = .{},
            .margin = .{},
        });
        x += 20;
    }
    var muted = theme;
    muted.text = if (save == .failed) tint else theme.muted;
    var opts = ui.options(muted, .{ .x = x, .y = 22, .w = 190, .h = 20 }, 12);
    opts.padding = .{};
    opts.tag = "file.save_state";
    dvui.labelNoFmt(@src(), text, .{ .align_y = 0.5 }, opts);
}

/// The chevron between the steps of the work flow.
fn flowArrow(theme: ui.Theme, x: f32) void {
    dvui.icon(@src(), "flow", ui.control_icons.next, .{}, .{
        .id_extra = @intFromFloat(x),
        .color_text = .{ .color = theme.muted },
        .rect = .{ .x = x, .y = 24, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
}

const Activity = struct {
    busy: bool,
    failed: bool,
    /// The complete latest status, shown in the details popup.
    full: []const u8,
    hint: []const u8,
    /// The short status shown in the toolbar row.
    message: []const u8,

    /// Summarizes build and flash progress. A success message is shown for five
    /// seconds after the status last changed, then collapses to "Ready".
    fn init(view: *View, frame: Frame) Activity {
        const busy = frame.build_active or frame.flash_active;
        const failed = frame.diagnostic.len != 0 or (frame.flash_failed and !frame.build_active);
        const full = if (frame.diagnostic.len != 0)
            frame.diagnostic
        else if (frame.build_active)
            "Building firmware…"
        else if (frame.flash_status.len != 0)
            frame.flash_status
        else
            frame.build_status;
        const hint = if (failed)
            ""
        else if (frame.build_active and frame.first_build)
            "First build may take a few minutes"
        else if (frame.build_active)
            "Compiling firmware and practice runner"
        else
            "";
        const result_hash = std.hash.Wyhash.hash(0, full);
        if (view.result_hash != result_hash) {
            view.result_hash = result_hash;
            view.result_until = frame.now_ms +| 5000;
        }
        const success = !busy and !failed and (frame.flash_succeeded or std.mem.eql(u8, full, "Built snapshot"));
        const message = if (frame.diagnostic.len != 0)
            "Needs attention · open Details"
        else if (failed)
            "Flash failed · open Details"
        else if (success and frame.now_ms > view.result_until)
            "Ready"
        else if (full.len == 0)
            "Ready"
        else
            full;
        return .{ .busy = busy, .failed = failed, .full = full, .hint = hint, .message = message };
    }
};

fn drawActivity(view: *View, theme: ui.Theme, frame: Frame, width: f32) void {
    const activity: Activity = .init(view, frame);
    const row = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 16, .y = 64, .w = width - 32, .h = 36 },
        .padding = .{},
        .margin = .{},
        .tag = "editor.activity",
    });
    defer row.deinit();
    const row_width = width - 32;
    const separator = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 0, .y = 0, .w = row_width, .h = 1 },
        .background = true,
        .color_fill = .{ .color = theme.border },
        .padding = .{},
        .margin = .{},
    });
    separator.deinit();
    drawActivityIcon(activity, theme);
    const controls_x = row_width - 470;
    const message_width = if (activity.hint.len != 0) @min(@as(f32, 300), controls_x - 40) else controls_x - 40;
    var label_options = ui.options(theme, .{ .x = 30, .y = 6, .w = message_width, .h = 26 }, 14);
    label_options.padding = .{};
    label_options.tag = "editor.activity.message";
    dvui.labelNoFmt(@src(), activity.message, .{ .align_y = 0.5, .ellipsize = true }, label_options);
    var muted = theme;
    muted.text = theme.muted;
    if (activity.hint.len != 0) {
        const hint_bounds: dvui.Rect = .{ .x = 30 + message_width + 12, .y = 10, .w = @max(0, controls_x - message_width - 52), .h = 20 };
        ui.label(muted, activity.hint, hint_bounds, 12);
    }
    ui.label(muted, frame.connection, .{ .x = controls_x, .y = 10, .w = 220, .h = 20 }, 12);
    var auto_options = ui.options(theme, .{ .x = row_width - 220, .y = 8, .w = 120, .h = 22 }, 13);
    auto_options.padding = .{};
    auto_options.tag = "firmware.auto_build";
    _ = dvui.checkbox(@src(), &view.auto_build, "Auto-build", auto_options);
    if (ui.iconButton(theme, if (view.details_open) null else ui.control_icons.expand, "Details", "editor.activity.details", .{ .x = row_width - 92, .y = 5, .w = 92, .h = 26 }, false)) {
        view.details_open = !view.details_open;
    }
    if (view.details_open) drawDetails(view, activity, theme);
}

/// A spinner while busy, otherwise a status dot or a warning mark.
fn drawActivityIcon(activity: Activity, theme: ui.Theme) void {
    const tint = if (activity.failed) ui.color(0xF06B73) else if (activity.busy) ui.color(0x328BFF) else ui.color(0x6EC59A);
    if (!activity.busy) {
        var icon_theme = theme;
        icon_theme.text = tint;
        ui.label(icon_theme, if (activity.failed) "!" else "●", .{ .x = 8, .y = 8, .w = 18, .h = 20 }, 14);
        return;
    }
    const track = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 4, .y = 7, .w = 22, .h = 22 },
        .padding = .{},
        .margin = .{},
        .border = .all(3),
        .corners = .all(11),
        .color_border = .{ .color = theme.control },
    });
    track.deinit();
    dvui.spinner(@src(), .{
        .rect = .{ .x = 4, .y = 7, .w = 22, .h = 22 },
        .min_size_content = .{ .w = 22, .h = 22 },
        .padding = .{},
        .margin = .{},
        .color_text = .{ .color = tint },
    });
}

fn drawDetails(view: *View, activity: Activity, theme: ui.Theme) void {
    const popup = dvui.floatingWindow(@src(), .{ .modal = false }, .{
        .rect = .{ .x = @max(16, dvui.windowRect().w - 650), .y = 110, .w = 620, .h = 240 },
        .padding = .all(18),
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_text = .{ .color = theme.text },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
    });
    defer popup.deinit();
    ui.label(theme, "Build and Flash activity", .{ .x = 0, .y = 0, .w = 584, .h = 25 }, 17);
    {
        const scroll = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 0, .y = 36, .w = 584, .h = 105 }, .background = false });
        defer scroll.deinit();
        const text = dvui.textLayout(@src(), .{ .break_lines = true }, .{
            .expand = .horizontal,
            .background = false,
            .font = ui.options(theme, .{}, 14).font,
            .padding = .{},
        });
        text.addText(activity.full, .{});
        if (activity.hint.len != 0) {
            text.addText("\n\n", .{});
            text.addText(activity.hint, .{});
        }
        text.deinit();
    }
    if (ui.button(theme, "Copy details", "editor.activity.copy", .{ .x = 0, .y = 155, .w = 130, .h = 32 })) {
        const full = activity.full;
        const details = if (activity.hint.len == 0)
            full
        else
            std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}\n\n{s}", .{ full, activity.hint }) catch full;
        dvui.clipboardTextSet(details);
    }
    if (ui.button(theme, "Close", "editor.activity.close", .{ .x = 474, .y = 155, .w = 110, .h = 32 })) view.details_open = false;
}
