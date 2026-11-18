//! My Keyboards: the hardware on the left, the layouts of the chosen keyboard
//! as cards on the right, and three entry cards on first launch.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const preview = @import("keyboard_preview.zig");
const library = desktop.library;

pub const Running = struct { board_id: [8]u8, profile_id: [8]u8 };

pub const Context = struct {
    library: ?*const library.Library,
    /// The project open in the editor, if any.
    current_path: []const u8 = "",
    /// The layout verified on the connected keyboard.
    running: ?Running = null,
    /// Now, in nanoseconds since the epoch, for relative ages.
    now: i96 = 0,
    /// Whether an editor project is open to go back to.
    has_editor: bool = false,
    collection: []const u8 = "",
};

pub const Intent = union(enum) {
    none,
    /// Opens `library.layouts[index]`.
    open_layout: usize,
    /// New layout for `library.keyboards[index]`.
    new_layout: usize,
    add_keyboard,
    import_git,
    open_folder,
    change_location,
    editor,
    toggle_theme,
};

pub const canvas_width: f32 = 1536;
pub const canvas_height: f32 = 1056;

/// The top bar of the onboarding pages: the wordmark, a breadcrumb trail
/// and the theme toggle. Returns whether the theme toggle was clicked.
pub fn bar(theme: ui.Theme, trail: []const []const u8, light: bool) bool {
    const strip = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 0, .y = 0, .w = canvas_width, .h = 64 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .{ .h = 1 },
        .padding = .{},
        .margin = .{},
        .tag = "onboarding.bar",
    });
    strip.deinit();
    ui.label(theme, "Zigmkay", .{ .x = 24, .y = 17, .w = 110, .h = 30 }, 23);
    rule(theme, .{ .x = 128, .y = 22, .w = 1, .h = 20 }, 0);
    var x: f32 = 144;
    for (trail, 0..) |crumb, index| {
        const last = index + 1 == trail.len;
        var tint = theme;
        tint.text = if (last and trail.len > 1) theme.text else theme.muted;
        const size: f32 = 14;
        const width = textWidth(crumb, size) + 4;
        var opts = ui.options(tint, .{ .x = x, .y = 22, .w = width, .h = 20 }, size);
        if (last and trail.len > 1) opts.font = opts.font.?.withWeight(.bold);
        opts.padding = .{};
        opts.id_extra = index;
        dvui.labelNoFmt(@src(), crumb, .{ .align_y = 0.5 }, opts);
        x += width + 6;
        if (!last) {
            dvui.icon(@src(), "trail", ui.control_icons.next, .{}, .{
                .id_extra = index,
                .color_text = .{ .color = theme.muted },
                .rect = .{ .x = x, .y = 25, .w = 14, .h = 14 },
                .padding = .{},
                .margin = .{},
            });
            x += 20;
        }
    }
    const theme_icon = if (light) ui.control_icons.dark else ui.control_icons.light;
    return ui.iconButton(theme, theme_icon, "", "onboarding.theme", .{ .x = canvas_width - 52, .y = 14, .w = 36, .h = 36 }, false);
}

pub fn textWidth(value: []const u8, size: f32) f32 {
    return ui.options(ui.Theme.get(false), .{}, size).font.?.textSize(value).w;
}

pub fn rule(theme: ui.Theme, rect: dvui.Rect, id: usize) void {
    const line = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.border },
        .padding = .{},
        .margin = .{},
    });
    line.deinit();
}

/// A panel background with a border and rounded corners.
pub fn panel(theme: ui.Theme, rect: dvui.Rect, id: usize) void {
    const box = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(12),
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
}

/// A flat, clickable surface; content is drawn over it afterwards.
pub fn surface(theme: ui.Theme, rect: dvui.Rect, tag: []const u8, id: usize, selected: bool, dashed_border: bool) bool {
    const fill = if (selected) ui.mix(theme.panel, theme.accent, 0.14) else if (dashed_border) theme.panel else theme.control;
    return dvui.button(@src(), "", .{}, .{
        .id_extra = id,
        .tag = tag,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = fill },
        .color_fill_hover = .{ .color = ui.mix(fill, theme.text, 0.05) },
        .color_fill_press = .{ .color = ui.mix(fill, theme.accent, 0.2) },
        .color_border = .{ .color = if (selected) theme.accent else theme.border },
        .border = .all(if (selected) 1.5 else 1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
    });
}

pub fn text(theme: ui.Theme, value: []const u8, rect: dvui.Rect, size: f32, tint: dvui.Color, bold: bool, id: usize) void {
    var t = theme;
    t.text = tint;
    var opts = ui.options(t, rect, size);
    if (bold) opts.font = opts.font.?.withWeight(.bold);
    opts.padding = .{};
    opts.id_extra = id;
    dvui.labelNoFmt(@src(), value, .{ .align_y = 0.5, .ellipsize = true }, opts);
}

/// A rounded pill with centered text.
pub fn pill(theme: ui.Theme, value: []const u8, rect: dvui.Rect, fill: dvui.Color, border: ?dvui.Color, tint: dvui.Color, id: usize) void {
    const box = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = fill },
        .color_border = .{ .color = border orelse fill },
        .border = .all(if (border != null) 1 else 0),
        .corners = .all(rect.h / 2),
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
    var t = theme;
    t.text = tint;
    var opts = ui.options(t, rect, 12);
    opts.padding = .{};
    opts.id_extra = id;
    dvui.labelNoFmt(@src(), value, .{ .align_x = 0.5, .align_y = 0.5 }, opts);
}

/// "PCB 0.7 (LK7) · 34 keys" for a catalog entry.
pub fn hardwareLine(buffer: []u8, entry: *const library.catalog.Entry) []const u8 {
    const revision = entry.display.revision;
    const keys = entry.default_dimensions.key_count;
    const encoders = entry.encoder_action_slots;
    // Revisions such as "38-key" already name the key count.
    const pcb = if (std.mem.endsWith(u8, revision, "-key")) "" else "PCB ";
    const name = if (pcb.len == 0) "" else revision;
    const separator = if (pcb.len == 0) "" else " · ";
    return if (encoders != 0)
        std.fmt.bufPrint(buffer, "{s}{s}{s}{d} keys · {d} encoder directions", .{ pcb, name, separator, keys, encoders }) catch revision
    else
        std.fmt.bufPrint(buffer, "{s}{s}{s}{d} keys", .{ pcb, name, separator, keys }) catch revision;
}

pub fn draw(theme: ui.Theme, light: bool, chosen: *?usize, context: Context) Intent {
    const loaded = context.library;
    if (loaded == null or loaded.?.layouts.len == 0) return drawFirstLaunch(theme, light, context);
    const keyboards = loaded.?;
    var intent: Intent = .none;
    if (bar(theme, &.{"My Keyboards"}, light)) intent = .toggle_theme;
    if (ui.iconButton(theme, ui.control_icons.git, "Import from Git", "onboarding.import", .{ .x = 986, .y = 14, .w = 168, .h = 36 }, false)) intent = .import_git;
    if (ui.iconButton(theme, ui.control_icons.add, "Keyboard", "onboarding.create", .{ .x = 1164, .y = 14, .w = 136, .h = 36 }, true)) intent = .add_keyboard;
    if (context.has_editor and ui.iconButton(theme, ui.control_icons.back, "Back to editor", "onboarding.editor", .{ .x = 1310, .y = 14, .w = 164, .h = 36 }, false)) intent = .editor;
    if (chosen.* == null or chosen.*.? >= keyboards.keyboards.len) chosen.* = currentKeyboard(keyboards, context.current_path);
    const selected = chosen.*.?;
    if (drawHardware(theme, keyboards, selected, context)) |picked| switch (picked) {
        .keyboard => |index| chosen.* = index,
        .intent => |value| intent = value,
    };
    const layouts = drawLayouts(theme, keyboards, selected, context);
    if (layouts != .none) intent = layouts;
    return intent;
}

fn currentKeyboard(keyboards: *const library.Library, current: []const u8) usize {
    if (keyboards.find(current)) |layout| {
        for (keyboards.keyboards, 0..) |keyboard, index| {
            for (keyboard.layouts) |member| if (member == layout) return index;
        }
    }
    return 0;
}

const Picked = union(enum) { keyboard: usize, intent: Intent };

const hardware_row: f32 = 103;

fn drawHardware(theme: ui.Theme, keyboards: *const library.Library, selected: usize, context: Context) ?Picked {
    panel(theme, .{ .x = 16, .y = 80, .w = 400, .h = 960 }, 1);
    text(theme, "Hardware", .{ .x = 36, .y = 98, .w = 300, .h = 26 }, 19, theme.text, true, 1);
    var buffer: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(&buffer, "{d} {s} · {s}", .{
        keyboards.keyboards.len,
        if (keyboards.keyboards.len == 1) "keyboard" else "keyboards",
        if (context.collection.len != 0) std.fs.path.basename(context.collection) else "no collection yet",
    }) catch "";
    text(theme, summary, .{ .x = 36, .y = 126, .w = 360, .h = 18 }, 12, theme.muted, false, 2);
    var picked: ?Picked = null;
    {
        const list = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 28, .y = 156, .w = 380, .h = 760 }, .background = false, .padding = .{}, .margin = .{} });
        defer list.deinit();
        const rows = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = 376, .h = @as(f32, @floatFromInt(keyboards.keyboards.len)) * hardware_row + 70 },
            .padding = .{},
            .margin = .{},
        });
        defer rows.deinit();
        for (keyboards.keyboards, 0..) |keyboard, index| {
            const y = @as(f32, @floatFromInt(index)) * hardware_row;
            const row: dvui.Rect = .{ .x = 0, .y = y, .w = 374, .h = 91 };
            if (surface(theme, row, indexed("keyboards.hardware", index), index, index == selected, false)) picked = .{ .keyboard = index };
            const thumb = dvui.box(@src(), .{}, .{
                .id_extra = index,
                .rect = .{ .x = 12, .y = y + 13, .w = 120, .h = 64 },
                .background = true,
                .color_fill = .{ .color = theme.bg },
                .corners = .all(8),
                .padding = .{},
                .margin = .{},
            });
            thumb.deinit();
            preview.draw(theme, keyboard.entry.geometry, .{ .x = 20, .y = y + 19, .w = 104, .h = 52 }, .{ .id = 100 + index });
            text(theme, keyboard.entry.display.name, .{ .x = 146, .y = y + 18, .w = 190, .h = 20 }, 14, theme.text, true, 10 + index);
            var line: [128]u8 = undefined;
            text(theme, hardwareLine(&line, keyboard.entry), .{ .x = 146, .y = y + 40, .w = 220, .h = 16 }, 12, theme.muted, false, 20 + index);
            var count: [64]u8 = undefined;
            const layouts = std.fmt.bufPrint(&count, "{d} {s}", .{ keyboard.layouts.len, if (keyboard.layouts.len == 1) "layout" else "layouts" }) catch "";
            text(theme, layouts, .{ .x = 146, .y = y + 58, .w = 200, .h = 16 }, 12, theme.muted, false, 30 + index);
            if (runningOn(keyboards, keyboard, context.running)) {
                const dot = dvui.box(@src(), .{}, .{
                    .id_extra = index,
                    .rect = .{ .x = 340, .y = y + 20, .w = 9, .h = 9 },
                    .background = true,
                    .color_fill = .{ .color = ui.color(0x22C55E) },
                    .corners = .all(4.5),
                    .padding = .{},
                    .margin = .{},
                });
                dot.deinit();
            }
        }
        const add_y = @as(f32, @floatFromInt(keyboards.keyboards.len)) * hardware_row;
        if (surface(theme, .{ .x = 0, .y = add_y, .w = 374, .h = 56 }, "keyboards.add", 999, false, true)) picked = .{ .intent = .add_keyboard };
        dvui.icon(@src(), "add.keyboard", ui.control_icons.add, .{}, .{
            .color_text = .{ .color = theme.muted },
            .rect = .{ .x = 110, .y = add_y + 19, .w = 18, .h = 18 },
            .padding = .{},
            .margin = .{},
        });
        text(theme, "Keyboard from catalog", .{ .x = 136, .y = add_y + 18, .w = 200, .h = 20 }, 14, theme.muted, false, 40);
    }
    footer(theme, keyboards, &picked);
    return picked;
}

fn footer(theme: ui.Theme, keyboards: *const library.Library, picked: *?Picked) void {
    rule(theme, .{ .x = 28, .y = 924, .w = 376, .h = 1 }, 3);
    if (keyboards.unreadable.len != 0) {
        var buffer: [128]u8 = undefined;
        const note = std.fmt.bufPrint(&buffer, "{d} {s} could not be read and stay untouched", .{
            keyboards.unreadable.len,
            if (keyboards.unreadable.len == 1) "project" else "projects",
        }) catch "";
        text(theme, note, .{ .x = 36, .y = 898, .w = 370, .h = 18 }, 12, ui.color(0xF59E0B), false, 4);
    }
    if (ui.iconButton(theme, ui.control_icons.open, "Open folder…", "onboarding.open", .{ .x = 28, .y = 938, .w = 182, .h = 36 }, false)) picked.* = .{ .intent = .open_folder };
    if (ui.iconButton(theme, ui.control_icons.folder, "Change location…", "onboarding.location", .{ .x = 218, .y = 938, .w = 186, .h = 36 }, false)) picked.* = .{ .intent = .change_location };
    text(theme, "Open a project or collection, or move where new layouts go", .{ .x = 30, .y = 988, .w = 376, .h = 16 }, 12, theme.muted, false, 5);
}

fn runningLayout(layout: library.Layout, running: ?Running) bool {
    const identity = running orelse return false;
    return std.mem.eql(u8, &identity.board_id, &layout.board_id) and std.mem.eql(u8, &identity.profile_id, &layout.profile_id);
}

fn runningOn(keyboards: *const library.Library, keyboard: library.Keyboard, running: ?Running) bool {
    for (keyboard.layouts) |index| if (runningLayout(keyboards.layouts[index], running)) return true;
    return false;
}

const card_w: f32 = 508;
const card_h: f32 = 318;

fn drawLayouts(theme: ui.Theme, keyboards: *const library.Library, selected: usize, context: Context) Intent {
    const keyboard = keyboards.keyboards[selected];
    panel(theme, .{ .x = 428, .y = 80, .w = 1092, .h = 960 }, 2);
    text(theme, keyboard.entry.display.name, .{ .x = 456, .y = 100, .w = 700, .h = 36 }, 28, theme.text, true, 50);
    var line: [128]u8 = undefined;
    var buffer: [192]u8 = undefined;
    const detail = std.fmt.bufPrint(&buffer, "{s} · {s}", .{ hardwareLine(&line, keyboard.entry), keyboard.entry.fidelity.note() }) catch "";
    text(theme, detail, .{ .x = 456, .y = 140, .w = 760, .h = 20 }, 14, theme.muted, false, 51);
    var intent: Intent = .none;
    if (ui.iconButton(theme, ui.control_icons.add, "New layout", "keyboards.new_layout", .{ .x = 1340, .y = 104, .w = 156, .h = 36 }, false)) intent = .{ .new_layout = selected };
    text(theme, "Layouts", .{ .x = 456, .y = 190, .w = 100, .h = 24 }, 19, theme.text, true, 52);
    text(theme, "Click a layout to edit it", .{ .x = 556, .y = 194, .w = 300, .h = 18 }, 12, theme.muted, false, 53);
    const area = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 448, .y = 222, .w = 1064, .h = 776 }, .background = false, .padding = .{}, .margin = .{} });
    defer area.deinit();
    const count = keyboard.layouts.len + 1;
    const rows = (count + 1) / 2;
    const grid = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 1050, .h = @as(f32, @floatFromInt(rows)) * (card_h + 20) },
        .padding = .{},
        .margin = .{},
    });
    defer grid.deinit();
    for (keyboard.layouts, 0..) |layout_index, slot| {
        if (layoutCard(theme, keyboards.layouts[layout_index], slotRect(slot), layout_index, context)) intent = .{ .open_layout = layout_index };
    }
    const add = slotRect(keyboard.layouts.len);
    if (surface(theme, add, "keyboards.new_card", 999, false, true)) intent = .{ .new_layout = selected };
    const plus = dvui.box(@src(), .{}, .{
        .rect = .{ .x = add.x + add.w / 2 - 24, .y = add.y + 98, .w = 48, .h = 48 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(24),
        .padding = .{},
        .margin = .{},
    });
    plus.deinit();
    dvui.icon(@src(), "new.layout", ui.control_icons.add, .{}, .{
        .color_text = .{ .color = theme.text },
        .rect = .{ .x = add.x + add.w / 2 - 12, .y = add.y + 110, .w = 24, .h = 24 },
        .padding = .{},
        .margin = .{},
    });
    centered(theme, "New layout", .{ .x = add.x, .y = add.y + 164, .w = add.w, .h = 24 }, 17, theme.text, true, 60);
    centered(theme, "Template · duplicate · blank · import from Git", .{ .x = add.x, .y = add.y + 190, .w = add.w, .h = 18 }, 12, theme.muted, false, 61);
    return intent;
}

fn slotRect(slot: usize) dvui.Rect {
    const column: f32 = @floatFromInt(slot % 2);
    const row: f32 = @floatFromInt(slot / 2);
    return .{ .x = 8 + column * (card_w + 20), .y = 2 + row * (card_h + 20), .w = card_w, .h = card_h };
}

fn centered(theme: ui.Theme, value: []const u8, rect: dvui.Rect, size: f32, tint: dvui.Color, bold: bool, id: usize) void {
    var t = theme;
    t.text = tint;
    var opts = ui.options(t, rect, size);
    if (bold) opts.font = opts.font.?.withWeight(.bold);
    opts.padding = .{};
    opts.id_extra = id;
    dvui.labelNoFmt(@src(), value, .{ .align_x = 0.5, .align_y = 0.5 }, opts);
}

fn layoutCard(theme: ui.Theme, layout: library.Layout, rect: dvui.Rect, index: usize, context: Context) bool {
    const current = std.mem.eql(u8, layout.path, context.current_path) and context.has_editor;
    const clicked = dvui.button(@src(), "", .{}, .{
        .id_extra = index,
        .tag = indexed("keyboards.layout", index),
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_fill_hover = .{ .color = ui.mix(theme.panel, theme.text, 0.04) },
        .color_fill_press = .{ .color = ui.mix(theme.panel, theme.accent, 0.12) },
        .color_border = .{ .color = if (current) ui.layerColor(theme, 0) else theme.border },
        .border = .all(if (current) 1.5 else 1),
        .corners = .all(12),
        .padding = .{},
        .margin = .{},
    });
    const well = dvui.box(@src(), .{}, .{
        .id_extra = index,
        .rect = .{ .x = rect.x + 16, .y = rect.y + 16, .w = rect.w - 32, .h = 196 },
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
    });
    well.deinit();
    preview.draw(theme, layout.entry.geometry, .{ .x = rect.x + 40, .y = rect.y + 30, .w = rect.w - 80, .h = 168 }, .{ .captions = layout.base, .id = 1000 + index });
    text(theme, layout.name, .{ .x = rect.x + 16, .y = rect.y + 226, .w = rect.w - 230, .h = 24 }, 17, theme.text, true, 200 + index);
    var age: [64]u8 = undefined;
    var buffer: [192]u8 = undefined;
    const meta = std.fmt.bufPrint(&buffer, "{d} {s} · {d} {s}{s} · edited {s}", .{
        layout.layer_count,
        if (layout.layer_count == 1) "layer" else "layers",
        layout.combo_count,
        if (layout.combo_count == 1) "combo" else "combos",
        if (layout.callback_count != 0) " · callbacks" else "",
        library.age(&age, context.now, layout.modified),
    }) catch "";
    text(theme, meta, .{ .x = rect.x + 16, .y = rect.y + 252, .w = rect.w - 32, .h = 18 }, 12, theme.muted, false, 300 + index);
    var where: [256]u8 = undefined;
    text(theme, location(&where, layout), .{ .x = rect.x + 16, .y = rect.y + 282, .w = rect.w - 32, .h = 18 }, 12, theme.muted, false, 400 + index);
    var badge_x = rect.x + rect.w - 16;
    if (runningLayout(layout, context.running)) {
        badge_x -= 100;
        ui.runningBadge(.{ .x = badge_x, .y = rect.y + 228, .w = 100, .h = 22 }, index);
    }
    if (current) {
        badge_x -= 92;
        pill(theme, "In editor", .{ .x = badge_x, .y = rect.y + 228, .w = 84, .h = 22 }, ui.mix(theme.panel, theme.accent, 0.18), theme.accent, theme.text, 500 + index);
    }
    if (layout.member == null) {
        badge_x -= 128;
        pill(theme, "Outside collection", .{ .x = badge_x, .y = rect.y + 228, .w = 120, .h = 22 }, theme.control, theme.border, theme.muted, 600 + index);
    }
    return clicked;
}

/// The collection directory of a member, or the last two path components.
fn location(buffer: []u8, layout: library.Layout) []const u8 {
    if (layout.member) |member| return member;
    const parent = std.fs.path.dirname(layout.path) orelse return layout.path;
    return std.fmt.bufPrint(buffer, "…/{s}/{s}", .{ std.fs.path.basename(parent), std.fs.path.basename(layout.path) }) catch layout.path;
}

fn drawFirstLaunch(theme: ui.Theme, light: bool, context: Context) Intent {
    var intent: Intent = .none;
    if (bar(theme, &.{"My Keyboards"}, light)) intent = .toggle_theme;
    if (context.has_editor and ui.iconButton(theme, ui.control_icons.back, "Back to editor", "onboarding.editor", .{ .x = 1310, .y = 14, .w = 164, .h = 36 }, false)) intent = .editor;
    text(theme, "Welcome to Zigmkay", .{ .x = 168, .y = 160, .w = 900, .h = 40 }, 28, theme.text, true, 1);
    text(theme, "Set up your first keyboard. You can add more keyboards and layouts at any time.", .{ .x = 168, .y = 210, .w = 1100, .h = 24 }, 17, theme.muted, false, 2);
    const cards = [_]struct { title: []const u8, lines: [2][]const u8, link: []const u8, icon: []const u8, tag: []const u8, intent: Intent }{
        .{ .title = "Start from scratch", .lines = .{ "Choose your keyboard and PCB revision", "from the catalog, then a template." }, .link = "Choose keyboard →", .icon = ui.control_icons.add, .tag = "onboarding.create", .intent = .add_keyboard },
        .{ .title = "Import from Git", .lines = .{ "Bring an existing Zig keymap from a", "repository or folder and compare first." }, .link = "Paste a URL →", .icon = ui.control_icons.git, .tag = "onboarding.import", .intent = .import_git },
        .{ .title = "Open folder", .lines = .{ "Open a project or a whole collection", "you already have on disk." }, .link = "Choose folder →", .icon = ui.control_icons.open, .tag = "onboarding.open", .intent = .open_folder },
    };
    const lk7 = desktop.library.catalog.find("lk7").?;
    for (cards, 0..) |card, index| {
        const x = 168 + @as(f32, @floatFromInt(index)) * 408;
        const rect: dvui.Rect = .{ .x = x, .y = 276, .w = 384, .h = 360 };
        if (surface(theme, rect, card.tag, index, index == 0, false)) intent = card.intent;
        const well = dvui.box(@src(), .{}, .{
            .id_extra = index,
            .rect = .{ .x = x + 20, .y = 296, .w = 344, .h = 150 },
            .background = true,
            .color_fill = .{ .color = theme.bg },
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        well.deinit();
        switch (index) {
            0 => preview.draw(theme, lk7.geometry, .{ .x = x + 60, .y = 316, .w = 264, .h = 110 }, .{ .id = 10 }),
            1 => {
                preview.draw(theme, lk7.geometry, .{ .x = x + 36, .y = 336, .w = 130, .h = 70 }, .{ .id = 11 });
                dvui.icon(@src(), "first.transfer", ui.control_icons.transfer, .{}, .{
                    .color_text = .{ .color = theme.muted },
                    .rect = .{ .x = x + 182, .y = 360, .w = 20, .h = 20 },
                    .padding = .{},
                    .margin = .{},
                });
                preview.draw(theme, lk7.geometry, .{ .x = x + 218, .y = 336, .w = 130, .h = 70 }, .{ .id = 12 });
            },
            else => dvui.icon(@src(), "first.folder", ui.control_icons.open, .{}, .{
                .color_text = .{ .color = theme.muted },
                .rect = .{ .x = x + 156, .y = 335, .w = 72, .h = 72 },
                .padding = .{},
                .margin = .{},
            }),
        }
        const badge = dvui.box(@src(), .{}, .{
            .id_extra = index,
            .rect = .{ .x = x + 20, .y = 470, .w = 40, .h = 40 },
            .background = true,
            .color_fill = .{ .color = if (index == 0) theme.accent else theme.control },
            .color_border = .{ .color = theme.border },
            .border = .all(if (index == 0) 0 else 1),
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        badge.deinit();
        dvui.icon(@src(), "first.icon", card.icon, .{}, .{
            .id_extra = index,
            .color_text = .{ .color = if (index == 0) ui.color(0xFFFFFF) else theme.text },
            .rect = .{ .x = x + 30, .y = 480, .w = 20, .h = 20 },
            .padding = .{},
            .margin = .{},
        });
        text(theme, card.title, .{ .x = x + 20, .y = 528, .w = 344, .h = 26 }, 19, theme.text, true, 10 + index);
        text(theme, card.lines[0], .{ .x = x + 20, .y = 560, .w = 344, .h = 20 }, 14, theme.muted, false, 20 + index);
        text(theme, card.lines[1], .{ .x = x + 20, .y = 580, .w = 344, .h = 20 }, 14, theme.muted, false, 30 + index);
        text(theme, card.link, .{ .x = x + 20, .y = 606, .w = 344, .h = 20 }, 14, if (index == 0) theme.accent else theme.text, true, 40 + index);
    }
    rule(theme, .{ .x = 168, .y = 676, .w = 1200, .h = 1 }, 1);
    dvui.icon(@src(), "first.info", ui.control_icons.info, .{}, .{
        .color_text = .{ .color = theme.muted },
        .rect = .{ .x = 168, .y = 700, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
    var buffer: [4200]u8 = undefined;
    const where = std.fmt.bufPrint(&buffer, "New layouts are saved in {s}", .{if (context.collection.len != 0) context.collection else "the My Keyboards collection"}) catch "";
    text(theme, where, .{ .x = 194, .y = 698, .w = 980, .h = 20 }, 14, theme.muted, false, 50);
    if (ui.iconButton(theme, ui.control_icons.folder, "Change location…", "onboarding.location", .{ .x = 1180, .y = 690, .w = 188, .h = 36 }, false)) intent = .change_location;
    text(theme, "Nothing is written until you create a layout. No keyboard is accessed or flashed from this screen.", .{ .x = 194, .y = 730, .w = 1000, .h = 20 }, 14, theme.muted, false, 51);
    return intent;
}

/// A unique tag such as "keyboards.layout.3" for the `index`th repeated control.
pub fn indexed(prefix: []const u8, index: usize) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}.{d}", .{ prefix, index }) catch prefix;
}
