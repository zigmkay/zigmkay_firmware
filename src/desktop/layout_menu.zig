//! The layout crumb of the editor head and its menu: the layouts of this
//! keyboard and what can be done with the open one.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");

pub const Choice = struct {
    name: []const u8,
    /// Muted text on the right, such as when it was edited.
    detail: []const u8 = "",
    current: bool = false,
    /// The layout running on the connected keyboard.
    running: bool = false,
};

pub const Command = union(enum) {
    /// Opens `choices[index]`.
    open: usize,
    new,
    duplicate,
    rename,
    export_source,
    reveal,
    keyboards,
};

const Action = struct { icon: []const u8, text: []const u8, detail: []const u8 = "", tag: []const u8, command: Command };

const actions = [_][]const Action{
    &.{
        .{ .icon = ui.control_icons.add, .text = "New layout…", .tag = "layout.menu.new", .command = .new },
        .{ .icon = ui.control_icons.duplicate, .text = "Duplicate", .tag = "layout.menu.duplicate", .command = .duplicate },
        .{ .icon = ui.control_icons.rename, .text = "Rename…", .tag = "layout.menu.rename", .command = .rename },
    },
    &.{
        .{ .icon = ui.control_icons.export_source, .text = "Export Zig source…", .tag = "layout.menu.export", .command = .export_source },
        .{ .icon = ui.control_icons.open, .text = "Show in folder", .tag = "layout.menu.reveal", .command = .reveal },
    },
    &.{
        .{ .icon = ui.control_icons.keyboard, .text = "Other keyboard…", .detail = "My Keyboards", .tag = "layout.menu.keyboards", .command = .keyboards },
    },
};

const width: f32 = 340;
const padding: f32 = 8;
const row_height: f32 = 36;
const section_height: f32 = 30;
const separator_height: f32 = 13;
const hint_height: f32 = 30;
/// At most this many layouts are listed; the rest are on My Keyboards.
const max_choices = 10;

/// Draws the crumb button at `bounds` and, while `open`, its menu below it.
/// Clicking outside the menu or pressing Escape closes it.
pub fn draw(theme: ui.Theme, bounds: dvui.Rect, label: []const u8, choices: []const Choice, undo_hint: []const u8, open: *bool) ?Command {
    var crumb_data: dvui.WidgetData = undefined;
    if (crumb(theme, bounds, label, open.*, &crumb_data)) open.* = !open.*;
    if (!open.*) return null;
    const listed = choices[0..@min(choices.len, max_choices)];
    const height = padding * 2 + section_height + @as(f32, @floatFromInt(listed.len)) * row_height +
        separator_height * actions.len + @as(f32, @floatFromInt(actionCount())) * row_height + hint_height;
    const scale = dvui.parentGet().screenRectScale(.{}).s / dvui.windowNaturalScale();
    const anchor = crumb_data.borderRectScale().r.toNatural();
    const rect: dvui.Rect = .{ .x = anchor.x, .y = anchor.y + anchor.h + 6 * scale, .w = width * scale, .h = height * scale };
    if (dismissed(rect, crumb_data.borderRectScale().r)) {
        open.* = false;
        return null;
    }
    const popup = dvui.floatingWindow(@src(), .{}, .{
        .rect = rect,
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(12),
        .tag = "layout.menu.popup",
    });
    defer popup.deinit();
    var command: ?Command = null;
    var y: f32 = padding;
    var muted = theme;
    muted.text = theme.muted;
    sectionLabel(muted, "LAYOUTS ON THIS KEYBOARD", y);
    y += section_height;
    for (listed, 0..) |choice, index| {
        if (layoutRow(theme, choice, index, y)) command = .{ .open = index };
        y += row_height;
    }
    var id: usize = 0;
    for (actions, 0..) |group, group_index| {
        separator(theme, y, group_index);
        y += separator_height;
        for (group) |action| {
            if (actionRow(theme, action, id, y)) command = action.command;
            y += row_height;
            id += 1;
        }
    }
    ui.label(muted, undo_hint, .{ .x = 18, .y = y + 6, .w = width - 36, .h = 18 }, 12);
    if (command != null) open.* = false;
    return command;
}

fn actionCount() usize {
    var count: usize = 0;
    for (actions) |group| count += group.len;
    return count;
}

/// Whether a click outside the menu and its crumb, or Escape, closes it.
fn dismissed(natural: dvui.Rect, crumb_rect: dvui.Rect.Physical) bool {
    const physical = dvui.Rect.Natural.cast(natural).scale(dvui.windowNaturalScale(), dvui.Rect.Physical);
    for (dvui.events()) |*event| switch (event.evt) {
        .mouse => |mouse| if (mouse.action == .press and !physical.contains(mouse.p) and !crumb_rect.contains(mouse.p)) return true,
        .key => |key| if (key.action == .down and key.code == .escape) {
            event.handle(@src(), dvui.parentGet().data());
            return true;
        },
        else => {},
    };
    return false;
}

/// The layout name as a button with a chevron, outlined in the accent color.
fn crumb(theme: ui.Theme, bounds: dvui.Rect, label: []const u8, open: bool, data: *dvui.WidgetData) bool {
    var opts = ui.options(theme, bounds, 15);
    opts.tag = "layout.crumb";
    opts.background = true;
    opts.border = .all(1.5);
    opts.corners = .all(8);
    opts.padding = .{};
    opts.color_border = .{ .color = theme.accent };
    if (open) opts.color_fill = .{ .color = ui.mix(theme.control, theme.accent, 0.18) };
    opts.data_out = data;
    const clicked = dvui.button(@src(), "", .{}, opts);
    var bold = theme;
    bold.text = theme.text;
    var text = ui.options(bold, .{ .x = bounds.x + 14, .y = bounds.y, .w = bounds.w - 44, .h = bounds.h }, 15);
    text.font = text.font.?.withWeight(.bold);
    text.padding = .{};
    dvui.labelNoFmt(@src(), label, .{ .align_y = 0.5, .ellipsize = true }, text);
    dvui.icon(@src(), "layout.expand", ui.control_icons.expand, .{}, .{
        .color_text = .{ .color = theme.muted },
        .rect = .{ .x = bounds.x + bounds.w - 28, .y = bounds.y + (bounds.h - 16) / 2, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
    return clicked;
}

fn sectionLabel(theme: ui.Theme, text: []const u8, y: f32) void {
    var opts = ui.options(theme, .{ .x = 18, .y = y + 8, .w = width - 36, .h = 16 }, 11);
    opts.font = opts.font.?.withWeight(.bold);
    opts.padding = .{};
    dvui.labelNoFmt(@src(), text, .{}, opts);
}

fn separator(theme: ui.Theme, y: f32, index: usize) void {
    const line = dvui.box(@src(), .{}, .{
        .id_extra = index,
        .rect = .{ .x = padding, .y = y + 6, .w = width - padding * 2, .h = 1 },
        .background = true,
        .color_fill = .{ .color = theme.border },
        .padding = .{},
        .margin = .{},
    });
    line.deinit();
}

/// A full-width menu row that highlights under the pointer.
fn row(theme: ui.Theme, y: f32, id: usize, tag: ?[]const u8, selected: bool) bool {
    const highlight = ui.mix(theme.panel, theme.accent, 0.16);
    return dvui.button(@src(), "", .{}, .{
        .id_extra = id,
        .tag = tag,
        .rect = .{ .x = padding, .y = y, .w = width - padding * 2, .h = row_height },
        .background = true,
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .border = .{},
        .color_fill = .{ .color = if (selected) highlight else theme.panel },
        .color_fill_hover = .{ .color = if (selected) highlight else ui.mix(theme.panel, theme.text, 0.07) },
        .color_fill_press = .{ .color = highlight },
    });
}

fn icon(bytes: []const u8, tint: dvui.Color, y: f32, id: usize) void {
    dvui.icon(@src(), "menu.icon", bytes, .{}, .{
        .id_extra = id,
        .color_text = .{ .color = tint },
        .rect = .{ .x = 20, .y = y + 10, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
}

fn rowLabel(theme: ui.Theme, text: []const u8, x: f32, y: f32, w: f32, size: f32, bold: bool, align_x: f32) void {
    var opts = ui.options(theme, .{ .x = x, .y = y, .w = w, .h = row_height }, size);
    if (bold) opts.font = opts.font.?.withWeight(.bold);
    opts.padding = .{};
    opts.id_extra = (@as(usize, @intFromFloat(x)) << 16) + @as(usize, @intFromFloat(y));
    dvui.labelNoFmt(@src(), text, .{ .align_x = align_x, .align_y = 0.5, .ellipsize = true }, opts);
}

fn layoutRow(theme: ui.Theme, choice: Choice, index: usize, y: f32) bool {
    const clicked = row(theme, y, index, null, choice.current);
    if (choice.current) icon(ui.control_icons.check, theme.accent, y, index);
    const right_width: f32 = if (choice.running) 104 else 120;
    rowLabel(theme, choice.name, 46, y, width - 56 - right_width - 8, 14, choice.current, 0);
    if (choice.running) {
        ui.runningBadge(theme, .{ .x = width - padding - 10 - 98, .y = y + 8, .w = 98, .h = 20 }, index);
    } else if (choice.detail.len != 0) {
        var muted = theme;
        muted.text = theme.muted;
        rowLabel(muted, choice.detail, width - padding - 10 - right_width, y, right_width, 12, false, 1);
    }
    return clicked and !choice.current;
}

fn actionRow(theme: ui.Theme, action: Action, id: usize, y: f32) bool {
    const clicked = row(theme, y, 1000 + id, action.tag, false);
    const quiet = action.detail.len != 0;
    var tinted = theme;
    if (quiet) tinted.text = theme.muted;
    icon(action.icon, tinted.text, y, 1000 + id);
    rowLabel(tinted, action.text, 46, y, 180, 14, false, 0);
    if (quiet) rowLabel(tinted, action.detail, width - padding - 130, y, 120, 12, false, 1);
    return clicked;
}
