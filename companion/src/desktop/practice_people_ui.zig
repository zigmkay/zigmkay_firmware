//! Personal Tutor profiles in the Tutor top bar: the person chip, its menu
//! (switch, new, rename, delete with a two-step confirmation) and the dialog
//! that names a new profile or renames one. Switching itself happens in the
//! application, between lessons. Uses `ui.Theme` tokens only.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");

const people = desktop.practice_people;

/// One person as the menu shows them.
pub const Entry = struct {
    id: u32,
    name: []const u8,
    colour: u8,
    /// Progress on the bound layout, such as "16/26 letters · 5-day streak".
    detail: []const u8 = "",
    current: bool = false,
};

pub const Named = struct {
    buf: [people.max_name_bytes]u8 = undefined,
    len: usize = 0,
    colour: u8 = 0,

    pub fn name(self: *const Named) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Named, text: []const u8, colour: u8) void {
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
        self.colour = colour;
    }
};

/// What the user asked for; the application applies it between frames.
pub const Action = union(enum) {
    switch_to: u32,
    create: Named,
    rename: struct { id: u32, named: Named },
    delete: u32,
};

pub const DialogKind = enum { create, rename };

/// The menu and dialog state, kept in the Tutor view.
pub const State = struct {
    menu_open: bool = false,
    /// The menu asks whether to delete the current person.
    confirm_delete: bool = false,
    dialog: ?DialogKind = null,
    /// The person the rename dialog renames.
    dialog_person: u32 = 0,
    /// The name field, zero-terminated.
    name: [people.max_name_bytes + 1]u8 = @splat(0),
    colour: u8 = 0,
    /// Frames since the dialog opened; the field takes the focus first.
    dialog_frames: u8 = 0,

    /// Whether the menu or the dialog holds the keys.
    pub fn open(self: *const State) bool {
        return self.menu_open or self.dialog != null;
    }

    pub fn close(self: *State) void {
        self.menu_open = false;
        self.confirm_delete = false;
        self.dialog = null;
    }

    fn openDialog(self: *State, kind: DialogKind, person: ?*const Entry, colour: u8) void {
        self.menu_open = false;
        self.confirm_delete = false;
        self.dialog = kind;
        self.dialog_frames = 0;
        self.name = @splat(0);
        if (person) |p| {
            const n = @min(p.name.len, people.max_name_bytes);
            @memcpy(self.name[0..n], p.name[0..n]);
            self.dialog_person = p.id;
            self.colour = p.colour;
        } else {
            self.dialog_person = 0;
            self.colour = colour;
        }
    }
};

/// The colour of a person's avatar: pink, purple, green, amber and blue of
/// the layer palette, so both themes keep their contrast.
pub fn colourOf(theme: ui.Theme, colour: u8) dvui.Color {
    const layer_index = [_]usize{ 6, 4, 3, 2, 1 };
    return ui.layerColor(theme, layer_index[colour % layer_index.len]);
}

fn initialOf(name: []const u8, buf: *[4]u8) []const u8 {
    if (name.len == 0) return "?";
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch 1;
    const n = @min(len, name.len);
    @memcpy(buf[0..n], name[0..n]);
    if (n == 1) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

/// A round avatar with the person's initial.
fn avatar(theme: ui.Theme, rect: dvui.Rect, name: []const u8, colour: u8, id: usize) void {
    const circle = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = colourOf(theme, colour) },
        .corners = .all(rect.w / 2),
        .padding = .{},
        .margin = .{},
    });
    circle.deinit();
    var buf: [4]u8 = undefined;
    const initial = initialOf(name, &buf);
    dvui.labelNoFmt(@src(), initial, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = id,
        .rect = rect,
        .font = ui.editorFont(initial, rect.h * 0.52).withWeight(.bold),
        .color_text = .{ .color = ui.color(0xFFFFFF) },
        .padding = .{},
        .margin = .{},
    });
}

/// The chip's width for a name, within the room the top bar has. A compact
/// chip shows the avatar alone.
pub fn chipWidth(name: []const u8, compact: bool) f32 {
    if (compact) return 58;
    const text_w = ui.editorFont(name, 14).textSize(name).w;
    return std.math.clamp(text_w + 74, 96, 200);
}

/// Draws the person chip and, while open, its menu below it. Returns what
/// the user picked.
pub fn chipAndMenu(state: *State, theme: ui.Theme, bounds: dvui.Rect, entries: []const Entry, compact: bool) ?Action {
    const current = for (entries) |*e| {
        if (e.current) break e;
    } else return null;
    var chip_data: dvui.WidgetData = undefined;
    if (chip(theme, bounds, current, state.menu_open, compact, &chip_data)) {
        state.menu_open = !state.menu_open;
        state.confirm_delete = false;
    }
    if (!state.menu_open) return null;
    return menu(state, theme, &chip_data, entries, current);
}

fn chip(theme: ui.Theme, bounds: dvui.Rect, current: *const Entry, open: bool, compact: bool, data: *dvui.WidgetData) bool {
    var opts = ui.options(theme, bounds, 14);
    opts.tag = "practice.person.chip";
    opts.background = true;
    opts.border = .all(if (open) 1.5 else 1);
    opts.corners = .all(bounds.h / 2);
    opts.padding = .{};
    opts.color_fill = .{ .color = if (open) ui.mix(theme.control, theme.accent, 0.14) else theme.control };
    opts.color_border = .{ .color = if (open) theme.accent else theme.border };
    opts.data_out = data;
    const clicked = dvui.button(@src(), "", .{}, opts);
    const size = bounds.h - 10;
    avatar(theme, .{ .x = bounds.x + 5, .y = bounds.y + 5, .w = size, .h = size }, current.name, current.colour, 0x9300);
    if (!compact) dvui.labelNoFmt(@src(), current.name, .{ .align_y = 0.5, .ellipsize = true }, .{
        .rect = .{ .x = bounds.x + size + 13, .y = bounds.y, .w = @max(0, bounds.w - size - 13 - 30), .h = bounds.h },
        .font = ui.editorFont(current.name, 14),
        .color_text = .{ .color = theme.text },
        .padding = .{},
        .margin = .{},
    });
    dvui.icon(@src(), "person.expand", ui.control_icons.expand, .{}, .{
        .color_text = .{ .color = theme.muted },
        .rect = .{ .x = bounds.x + bounds.w - 26, .y = bounds.y + (bounds.h - 15) / 2, .w = 15, .h = 15 },
        .padding = .{},
        .margin = .{},
    });
    return clicked;
}

const menu_w: f32 = 320;
const pad: f32 = 6;
const person_h: f32 = 50;
const action_h: f32 = 36;
const divider_h: f32 = 11;
const confirm_h: f32 = 96;

fn menu(state: *State, theme: ui.Theme, chip_data: *dvui.WidgetData, entries: []const Entry, current: *const Entry) ?Action {
    const can_delete = entries.len > 1;
    const listed: f32 = @floatFromInt(entries.len);
    const actions_h: f32 = if (state.confirm_delete) confirm_h else action_h * 3;
    const height = pad * 2 + listed * person_h + divider_h + actions_h;
    const scale = dvui.parentGet().screenRectScale(.{}).s / dvui.windowNaturalScale();
    const anchor = chip_data.borderRectScale().r.toNatural();
    const screen = dvui.windowRect();
    const w = menu_w * scale;
    const x = std.math.clamp(anchor.x + anchor.w - w, 8, @max(8, screen.w - w - 8));
    const rect: dvui.Rect = .{ .x = x, .y = anchor.y + anchor.h + 6 * scale, .w = w, .h = height * scale };
    if (dismissed(rect, chip_data.borderRectScale().r)) {
        state.close();
        return null;
    }
    var stored = rect;
    const popup = dvui.floatingWindow(@src(), .{ .rect = &stored, .resize = .none }, .{
        .rect = rect,
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .tag = "practice.person.menu",
    });
    defer popup.deinit();

    var action: ?Action = null;
    var y: f32 = pad;
    for (entries, 0..) |*entry, i| {
        if (personRow(theme, entry, y, i) and !entry.current) action = .{ .switch_to = entry.id };
        y += person_h;
    }
    separator(theme, y);
    y += divider_h;

    const arena = dvui.currentWindow().arena();
    if (state.confirm_delete) {
        const question = std.fmt.allocPrint(arena, "Delete “{s}” and all of its progress?", .{current.name}) catch "Delete this profile and all of its progress?";
        rowText(question, .{ .x = 14, .y = y + 4, .w = menu_w - 28, .h = 22 }, 13, theme.danger, false, 0x9410);
        const bw = (menu_w - 28 - 8) / 2;
        if (ui.dangerButton(theme, ui.control_icons.delete, "Delete", "practice.person.confirm_delete", .{ .x = 14, .y = y + 34, .w = bw, .h = 32 })) {
            action = .{ .delete = current.id };
        }
        if (ui.button(theme, "Cancel", "practice.person.cancel_delete", .{ .x = 14 + bw + 8, .y = y + 34, .w = bw, .h = 32 })) {
            state.confirm_delete = false;
        }
    } else {
        if (actionRow(theme, ui.control_icons.add, "New profile…", theme.text, "practice.person.new", y, 0, true)) {
            var colour_buf: [people.max_people]u8 = undefined;
            for (entries, 0..) |e, i| colour_buf[i] = e.colour;
            state.openDialog(.create, null, freeColour(colour_buf[0..entries.len]));
            return null;
        }
        y += action_h;
        const rename = std.fmt.allocPrint(arena, "Rename “{s}”…", .{current.name}) catch "Rename…";
        if (actionRow(theme, ui.control_icons.rename, rename, theme.text, "practice.person.rename", y, 1, true)) {
            state.openDialog(.rename, current, 0);
            return null;
        }
        y += action_h;
        const delete = if (can_delete)
            std.fmt.allocPrint(arena, "Delete “{s}”…", .{current.name}) catch "Delete…"
        else
            "The last profile cannot be deleted";
        if (actionRow(theme, ui.control_icons.delete, delete, if (can_delete) theme.danger else theme.muted, "practice.person.delete", y, 2, can_delete)) {
            state.confirm_delete = true;
        }
    }
    if (action != null) state.close();
    return action;
}

fn freeColour(used: []const u8) u8 {
    var mask: u8 = 0;
    for (used) |c| mask |= @as(u8, 1) << @intCast(c % people.colour_count);
    for (0..people.colour_count) |c| if (mask & (@as(u8, 1) << @intCast(c)) == 0) return @intCast(c);
    return @intCast(used.len % people.colour_count);
}

/// Whether a click outside the menu and its chip, or Escape, closes it.
fn dismissed(natural: dvui.Rect, chip_rect: dvui.Rect.Physical) bool {
    const physical = dvui.Rect.Natural.cast(natural).scale(dvui.windowNaturalScale(), dvui.Rect.Physical);
    for (dvui.events()) |*event| switch (event.evt) {
        .mouse => |mouse| if (mouse.action == .press and !physical.contains(mouse.p) and !chip_rect.contains(mouse.p)) return true,
        .key => |key| if (key.action == .down and key.code == .escape) {
            event.handle(@src(), dvui.parentGet().data());
            return true;
        },
        else => {},
    };
    return false;
}

fn separator(theme: ui.Theme, y: f32) void {
    const line = dvui.box(@src(), .{}, .{
        .rect = .{ .x = pad + 4, .y = y + 5, .w = menu_w - pad * 2 - 8, .h = 1 },
        .background = true,
        .color_fill = .{ .color = theme.border },
        .padding = .{},
        .margin = .{},
    });
    line.deinit();
}

fn rowButton(theme: ui.Theme, rect: dvui.Rect, id: usize, tag: ?[]const u8, selected: bool, enabled: bool) bool {
    const highlight = ui.mix(theme.panel, theme.accent, 0.16);
    const opts: dvui.Options = .{
        .id_extra = id,
        .tag = tag,
        .rect = rect,
        .background = true,
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .border = .{},
        .color_fill = .{ .color = if (selected) highlight else theme.panel },
        .color_fill_hover = .{ .color = if (selected) highlight else ui.mix(theme.panel, theme.text, 0.07) },
        .color_fill_press = .{ .color = highlight },
    };
    if (!enabled) {
        const box = dvui.box(@src(), .{}, opts);
        box.deinit();
        return false;
    }
    return dvui.button(@src(), "", .{}, opts);
}

fn rowText(text: []const u8, rect: dvui.Rect, size: f32, color: dvui.Color, bold: bool, id: usize) void {
    var font = ui.editorFont(text, size);
    if (bold) font = font.withWeight(.bold);
    dvui.labelNoFmt(@src(), text, .{ .align_y = 0.5, .ellipsize = true }, .{
        .id_extra = id,
        .rect = rect,
        .font = font,
        .color_text = .{ .color = color },
        .padding = .{},
        .margin = .{},
    });
}

fn personRow(theme: ui.Theme, entry: *const Entry, y: f32, i: usize) bool {
    const arena = dvui.currentWindow().arena();
    const tag = std.fmt.allocPrint(arena, "practice.person.{d}", .{entry.id}) catch null;
    const clicked = rowButton(theme, .{ .x = pad, .y = y, .w = menu_w - pad * 2, .h = person_h - 2 }, 0x9500 + i, tag, entry.current, true);
    avatar(theme, .{ .x = pad + 10, .y = y + 11, .w = 26, .h = 26 }, entry.name, entry.colour, 0x9600 + i);
    const text_w = menu_w - pad * 2 - 56 - 34;
    rowText(entry.name, .{ .x = pad + 48, .y = y + 5, .w = text_w, .h = 20 }, 14, theme.text, entry.current, 0x9700 + i);
    rowText(entry.detail, .{ .x = pad + 48, .y = y + 24, .w = text_w, .h = 18 }, 12, theme.muted, false, 0x9800 + i);
    if (entry.current) dvui.icon(@src(), "person.current", ui.control_icons.check, .{}, .{
        .id_extra = i,
        .color_text = .{ .color = theme.accent },
        .rect = .{ .x = menu_w - pad - 30, .y = y + 16, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
    return clicked;
}

fn actionRow(theme: ui.Theme, icon: []const u8, text: []const u8, color: dvui.Color, tag: []const u8, y: f32, i: usize, enabled: bool) bool {
    const clicked = rowButton(theme, .{ .x = pad, .y = y, .w = menu_w - pad * 2, .h = action_h - 2 }, 0x9900 + i, tag, false, enabled);
    dvui.icon(@src(), "person.action", icon, .{}, .{
        .id_extra = i,
        .color_text = .{ .color = color },
        .rect = .{ .x = pad + 14, .y = y + 9, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
    rowText(text, .{ .x = pad + 44, .y = y, .w = menu_w - pad * 2 - 54, .h = action_h - 2 }, 14, color, false, 0x9a00 + i);
    return clicked;
}

pub const dialog_w: f32 = 440;
const dialog_head_h: f32 = 88;
const dialog_foot_h: f32 = 62;
const dialog_body_h: f32 = 196;

/// The dialog that names a new profile or renames one, while open.
pub fn dialog(state: *State, theme: ui.Theme, entries: []const Entry) ?Action {
    const kind = state.dialog orelse return null;
    const screen = dvui.windowRect();
    const w = @min(dialog_w, screen.w - 24);
    const h = @min(dialog_head_h + dialog_body_h + dialog_foot_h, screen.h - 24);
    var stored: dvui.Rect = .{ .x = (screen.w - w) / 2, .y = @max(12, (screen.h - h) / 2 - 40), .w = w, .h = h };
    var open = true;
    var fw = dvui.floatingWindow(@src(), .{ .modal = true, .rect = &stored, .resize = .none, .open_flag = &open }, .{
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(14),
        .tag = "practice.person.dialog",
    });
    defer fw.deinit();

    const renamed = for (entries) |*e| {
        if (e.id == state.dialog_person) break e;
    } else null;
    const arena = dvui.currentWindow().arena();
    const title = switch (kind) {
        .create => "New profile",
        .rename => std.fmt.allocPrint(arena, "Rename “{s}”", .{if (renamed) |r| r.name else ""}) catch "Rename profile",
    };
    const header = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 1, .y = 1, .w = w - 2, .h = dialog_head_h - 1 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .corners = ui.topCorners(13),
        .padding = .{},
        .margin = .{},
    });
    header.deinit();
    rowText(title, .{ .x = 22, .y = 16, .w = w - 44, .h = 26 }, 18, theme.text, true, 0x9b00);
    rowText("Letters, speed, streak and settings are separate", .{ .x = 22, .y = 44, .w = w - 44, .h = 18 }, 12.5, theme.muted, false, 0x9b06);
    rowText("for each profile. Everything stays on this computer.", .{ .x = 22, .y = 62, .w = w - 44, .h = 18 }, 12.5, theme.muted, false, 0x9b07);
    ui.divider(theme, .{ .x = 0, .y = dialog_head_h, .w = w, .h = 1 }, 0x9b01);

    var y = dialog_head_h + 16;
    rowText("Name", .{ .x = 22, .y = y, .w = 200, .h = 18 }, 12.5, theme.muted, false, 0x9b02);
    y += 22;
    var field = ui.options(theme, .{ .x = 22, .y = y, .w = w - 44, .h = 38 }, 15);
    field.tag = "practice.person.name";
    field.border = .all(1.5);
    field.color_border = .{ .color = theme.accent };
    field.corners = .all(8);
    field.padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 };
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = state.name[0..people.max_name_bytes] }, .placeholder = "Name" }, field);
    // The name opens with the cursor after it.
    if (state.dialog_frames == 0) entry.textLayout.selection.moveCursor(std.math.maxInt(usize), false);
    const field_id = entry.data().id;
    const entered = entry.enter_pressed;
    entry.deinit();
    if (state.dialog_frames < 2) dvui.focusWidget(field_id, null, null);
    state.dialog_frames +|= 1;

    var others: [people.max_people][]const u8 = undefined;
    var other_len: usize = 0;
    for (entries) |e| {
        if (kind == .rename and e.id == state.dialog_person) continue;
        others[other_len] = e.name;
        other_len += 1;
    }
    const raw = std.mem.sliceTo(&state.name, 0);
    const check = people.checkNameAmong(raw, others[0..other_len]);
    y += 44;
    // Say what is wrong once something was typed; an empty field just waits.
    const problem: ?people.NameProblem = switch (check) {
        .ok => null,
        .problem => |p| if (p == .empty and raw.len == 0) null else p,
    };
    if (problem) |p| rowText(p.text(), .{ .x = 22, .y = y, .w = w - 44, .h = 18 }, 12, theme.danger, false, 0x9b03);
    y += 24;

    rowText("Colour", .{ .x = 22, .y = y, .w = 200, .h = 18 }, 12.5, theme.muted, false, 0x9b04);
    y += 24;
    for (0..people.colour_count) |c| {
        const r: dvui.Rect = .{ .x = 22 + @as(f32, @floatFromInt(c)) * 40, .y = y, .w = 30, .h = 30 };
        const chosen = state.colour == c;
        const swatch = dvui.button(@src(), "", .{}, .{
            .id_extra = 0x9c00 + c,
            .tag = if (chosen) "practice.person.colour.chosen" else null,
            .rect = r,
            .background = true,
            .corners = .all(15),
            .border = .all(if (chosen) 2.5 else 0),
            .color_border = .{ .color = theme.text },
            .color_fill = .{ .color = colourOf(theme, @intCast(c)) },
            .color_fill_hover = .{ .color = ui.mix(colourOf(theme, @intCast(c)), theme.text, 0.15) },
            .padding = .{},
            .margin = .{},
        });
        if (swatch) {
            state.colour = @intCast(c);
            dvui.focusWidget(field_id, null, null);
        }
    }

    // Footer
    const foot_y = h - dialog_foot_h;
    const footer = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 1, .y = foot_y, .w = w - 2, .h = dialog_foot_h - 1 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .corners = ui.bottomCorners(13),
        .padding = .{},
        .margin = .{},
    });
    footer.deinit();
    ui.divider(theme, .{ .x = 0, .y = foot_y, .w = w, .h = 1 }, 0x9b05);
    const confirm_text = if (kind == .create) "Create and switch" else "Save";
    const confirm_w = ui.editorFont(confirm_text, 15).textSize(confirm_text).w + 36;
    const ok = check == .ok;
    const confirm = ui.iconButtonEnabled(theme, null, confirm_text, "practice.person.confirm", .{ .x = w - 22 - confirm_w, .y = foot_y + 14, .w = confirm_w, .h = 34 }, true, ok);
    const cancel = ui.button(theme, "Cancel", "practice.person.cancel", .{ .x = w - 22 - confirm_w - 10 - 96, .y = foot_y + 14, .w = 96, .h = 34 });

    var escape = false;
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (key.action == .down and key.code == .escape) {
            escape = true;
            event.handle(@src(), fw.data());
        }
    }
    if (cancel or escape or !open) {
        state.close();
        return null;
    }
    if ((confirm or entered) and ok) {
        var named: Named = .{};
        named.set(check.ok, state.colour);
        const action: Action = switch (kind) {
            .create => .{ .create = named },
            .rename => .{ .rename = .{ .id = state.dialog_person, .named = named } },
        };
        state.close();
        return action;
    }
    return null;
}
