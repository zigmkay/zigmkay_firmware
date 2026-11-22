//! Retained typed controls over an owned draft; document commit stays explicit.
//! The form follows the inspector: a segmented behaviour control, then Tap and
//! Hold cards with modifier toggles and optional parts added with "+" buttons.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const p = @import("project");
const types = @import("layout-model");
const ui = @import("editor-ui");
const labels = desktop.labels;
const Symbol = labels.keycap_symbols.Symbol;

pub const Draft = desktop.action_form.Draft;

pub const Options = struct {
    /// Offers the transparent (inherited) mode. Combos cannot be transparent.
    inherit: bool = true,
};

/// Text in the flowing layout, in the editor font. In a row it is centered
/// vertically.
fn text(value: []const u8, size: f32, tint: dvui.Color, id: usize) void {
    dvui.labelNoFmt(@src(), value, .{}, .{
        .id_extra = id,
        .font = ui.editorFont(value, size),
        .color_text = .{ .color = tint },
        .padding = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .margin = .{},
    });
}

fn rowText(value: []const u8, size: f32, tint: dvui.Color, id: usize) void {
    dvui.labelNoFmt(@src(), value, .{}, .{
        .id_extra = id,
        .font = ui.editorFont(value, size),
        .color_text = .{ .color = tint },
        .padding = .{},
        .margin = .{},
        .gravity_y = 0.5,
    });
}

fn note(t: ui.Theme, value: []const u8) void {
    text(value, 12, t.muted, std.hash.Wyhash.hash(2, value));
}

/// A titled card in the control color. The caller deinits it.
fn card(t: ui.Theme, id: usize) *dvui.BoxWidget {
    return dvui.box(@src(), .{}, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = t.bg },
        .color_border = .{ .color = t.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 12 },
        .margin = .{ .h = 10 },
    });
}

fn row(id: usize) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .margin = .{ .y = 2, .h = 2 }, .padding = .{} });
}

/// A card title with an optional remove button on the right. Returns true
/// when the remove button was clicked.
fn cardTitle(t: ui.Theme, title: []const u8, removable: bool, tag: []const u8) bool {
    const line = row(std.hash.Wyhash.hash(3, tag));
    defer line.deinit();
    dvui.labelNoFmt(@src(), title, .{}, .{
        .font = ui.editorFont(title, 15).withWeight(.bold),
        .color_text = .{ .color = t.text },
        .padding = .{ .y = 2, .h = 4 },
        .expand = .horizontal,
        .gravity_y = 0.5,
    });
    if (!removable) return false;
    return dvui.buttonIcon(@src(), tag, ui.control_icons.remove, .{}, .{}, .{
        .tag = tag,
        .id_extra = std.hash.Wyhash.hash(0, tag),
        .min_size_content = .{ .w = 14, .h = 14 },
        .padding = .all(5),
        .corners = .all(6),
        .background = false,
        .color_text = .{ .color = t.muted },
        .gravity_y = 0.5,
    });
}

/// A segmented control; returns true when the choice changed.
fn segmented(t: ui.Theme, names: []const []const u8, values: []const usize, choice: *usize, tag: []const u8) bool {
    const track = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
        .id_extra = std.hash.Wyhash.hash(0, tag),
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = t.control },
        .color_border = .{ .color = t.border },
        .border = .all(1),
        .corners = .all(9),
        .padding = .all(3),
        .margin = .{ .h = 12 },
        .tag = tag,
    });
    defer track.deinit();
    var changed = false;
    for (names, values, 0..) |name, value, index| {
        const chosen = choice.* == value;
        const segment_tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}.{d}", .{ tag, value }) catch tag;
        var font = ui.editorFont(name, 14);
        if (chosen) font = font.withWeight(.bold);
        if (dvui.button(@src(), name, .{}, .{
            .id_extra = index,
            .tag = segment_tag,
            .expand = .horizontal,
            .font = font,
            .background = chosen,
            .color_fill = .{ .color = if (chosen) t.panel else t.control },
            .color_text = .{ .color = if (chosen) t.text else t.muted },
            .border = if (chosen) .all(1) else .{},
            .color_border = .{ .color = t.border },
            .corners = .all(7),
            .padding = .{ .x = 6, .y = 7, .w = 6, .h = 7 },
            .margin = .{},
        }) and !chosen) {
            choice.* = value;
            changed = true;
        }
    }
    return changed;
}

/// A toggle chip whose caption may hold keyboard symbols.
fn toggle(t: ui.Theme, caption: []const u8, on: bool, tag: []const u8, id: usize) bool {
    const tint = if (on) ui.color(0xFFFFFF) else t.text;
    return ui.richButton(@src(), caption, .{ .color = tint, .secondary = tint, .size = 15, .id_extra = id }, .{
        .tag = tag,
        .id_extra = id,
        .min_size_content = .{ .w = 22, .h = 18 },
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .margin = .{ .w = 6 },
        .corners = .all(7),
        .border = .all(1),
        .background = true,
        .color_fill = .{ .color = if (on) t.accent else t.control },
        .color_border = .{ .color = if (on) t.accent else t.border },
        .gravity_y = 0.5,
    });
}

/// A "+ Part" button that adds an optional part of the action.
fn addButton(t: ui.Theme, caption: []const u8, tag: []const u8) bool {
    return dvui.button(@src(), caption, .{}, .{
        .tag = tag,
        .id_extra = std.hash.Wyhash.hash(0, tag),
        .font = ui.editorFont(caption, 13),
        .background = false,
        .color_text = .{ .color = t.text },
        .color_border = .{ .color = t.border },
        .border = .all(1),
        .corners = .all(7),
        .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        .margin = .{ .w = 8, .h = 6 },
    });
}

/// A labeled number entry with a unit after it.
fn number(t: ui.Theme, comptime T: type, value: *T, title: []const u8, unit: []const u8) void {
    const id = std.hash.Wyhash.hash(0, title);
    const line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .margin = .{ .w = 24, .y = 2, .h = 2 } });
    defer line.deinit();
    rowText(title, 13, t.muted, id);
    _ = dvui.textEntryNumber(@src(), T, .{ .value = value }, .{
        .id_extra = id,
        .min_size_content = .{ .w = 64, .h = 22 },
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .margin = .{ .x = 10, .w = 6 },
        .corners = .all(7),
        .gravity_y = 0.5,
    });
    if (unit.len != 0) rowText(unit, 13, t.muted, id +% 1);
}

const modifier_fields = .{ "left_ctrl", "left_shift", "left_alt", "left_gui", "right_ctrl", "right_shift", "right_alt", "right_gui" };

/// Modifier bits of one side in the host's order: ⌃⌥⇧⌘ on macOS, Ctrl ⇧ Alt Win elsewhere.
const host_order: [4]u3 = if (labels.running_host == .macos) .{ 0, 2, 1, 3 } else .{ 0, 1, 2, 3 };

fn modifierCaption(bit: u3) []const u8 {
    return switch (bit % 4) {
        0 => if (labels.running_host == .macos) Symbol.literal(.control) else "Ctrl",
        1 => Symbol.literal(.shift),
        2 => if (labels.running_host == .macos) Symbol.literal(.option) else "Alt",
        3 => switch (labels.running_host) {
            .macos => Symbol.literal(.command),
            .windows => Symbol.literal(.windows),
            .linux => "Super",
        },
        else => unreachable,
    };
}

/// Left and right modifier toggles on one line.
fn modifiers(t: ui.Theme, mods: *types.Modifiers, title: []const u8) void {
    const id = std.hash.Wyhash.hash(0, title);
    note(t, title);
    const line = row(id);
    defer line.deinit();
    var bits = mods.toByte();
    inline for (.{ "Left", "Right" }, 0..) |side, side_index| {
        dvui.labelNoFmt(@src(), side, .{}, .{
            .id_extra = id +% side_index,
            .font = ui.editorFont(side, 13),
            .color_text = .{ .color = t.muted },
            .min_size_content = .{ .w = 40 },
            .margin = .{ .x = if (side_index == 0) 0 else 18, .w = 4 },
            .gravity_y = 0.5,
        });
        for (host_order, 0..) |base, order| {
            const bit: u3 = base + @as(u3, side_index) * 4;
            const mask = @as(u8, 1) << bit;
            const tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "action.modifier.{s}.{d}", .{ title, bit }) catch title;
            if (toggle(t, modifierCaption(bit), bits & mask != 0, tag, id +% side_index * 8 +% order)) bits ^= mask;
        }
    }
    mods.* = @bitCast(bits);
}

/// Hold parts: modifiers, the layer and an optional callback.
pub fn hold(value: *p.Hold, doc: p.Document, title: []const u8, theme: ui.Theme) !void {
    if (doc.layers.len == 0 or doc.layers.len > p.Limits.layers) return error.InvalidActionFormLayers;
    modifiers(theme, &value.hold_modifiers, title);
    var selected: usize = 0;
    var names: [16][]const u8 = undefined;
    names[0] = "No layer";
    for (doc.layers, 0..) |layer, i| {
        names[i + 1] = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d} · {s}", .{ i, layer.name }) catch layer.name;
        if (value.layer_id == layer.id) selected = i + 1;
    }
    note(theme, "Layer while held");
    if (dvui.dropdown(@src(), names[0 .. doc.layers.len + 1], .{ .choice = &selected }, .{}, .{
        .id_extra = std.hash.Wyhash.hash(1, title),
        .expand = .horizontal,
        .corners = .all(7),
        .margin = .{ .h = 6 },
    })) {
        value.layer_id = if (selected == 0) null else doc.layers[selected - 1].id;
    }
    if (value.custom) |*id| {
        const remove_tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "action.remove.{s}.callback", .{title}) catch title;
        const line = row(std.hash.Wyhash.hash(4, title));
        defer line.deinit();
        if (customChoice(theme, id, "Hold callback ID", remove_tag)) value.custom = null;
    } else {
        const add_tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "action.add.{s}.callback", .{title}) catch title;
        if (addButton(theme, "+ Callback or signal", add_tag)) value.custom = 1;
    }
}

/// Reserved companion signals use custom IDs 253 to 255; other IDs are callbacks.
const signals = [_][]const u8{ "Custom callback", "Toggle companion logging", "Quit companion", "Show / hide companion" };

/// The signal or callback chooser with its remove button. Returns true when removed.
fn customChoice(t: ui.Theme, id: *u8, title: []const u8, remove_tag: []const u8) bool {
    var selected: usize = switch (id.*) {
        253 => 1,
        254 => 2,
        255 => 3,
        else => 0,
    };
    if (dvui.dropdown(@src(), &signals, .{ .choice = &selected }, .{}, .{
        .id_extra = std.hash.Wyhash.hash(0, title),
        .expand = .horizontal,
        .corners = .all(7),
        .gravity_y = 0.5,
    })) id.* = switch (selected) {
        1 => 253,
        2 => 254,
        3 => 255,
        else => 1,
    };
    if (selected == 0) number(t, u8, id, "ID", "");
    return removeButton(t, remove_tag);
}

fn removeButton(t: ui.Theme, tag: []const u8) bool {
    return dvui.buttonIcon(@src(), tag, ui.control_icons.remove, .{}, .{}, .{
        .tag = tag,
        .id_extra = std.hash.Wyhash.hash(0, tag),
        .min_size_content = .{ .w = 14, .h = 14 },
        .padding = .all(7),
        .margin = .{ .x = 6 },
        .corners = .all(7),
        .background = false,
        .color_text = .{ .color = t.muted },
        .gravity_y = 0.5,
    });
}

/// One optional tap part on its own line, with a remove button.
fn partLine(t: ui.Theme, title: []const u8, id: usize) *dvui.BoxWidget {
    const line = row(id);
    dvui.labelNoFmt(@src(), title, .{}, .{
        .id_extra = id,
        .font = ui.editorFont(title, 13),
        .color_text = .{ .color = t.muted },
        .min_size_content = .{ .w = 92 },
        .gravity_y = 0.5,
    });
    return line;
}

/// Tap parts: the key with its modifiers, then optional one-shot, callback,
/// media and mouse parts. Parts may coexist.
pub fn tap(value: *p.Tap, doc: p.Document, theme: ui.Theme) !void {
    const t = theme;
    if (value.key_press) |*key| {
        {
            const line = row(1);
            defer line.deinit();
            keyChoice(&key.tap_keycode);
            number(t, u8, &key.tap_keycode, "HID", "");
            if (removeButton(t, "action.remove.key")) value.key_press = null;
        }
        if (value.key_press) |*kept| {
            modifiers(t, &kept.tap_modifiers, "Modifiers sent with the key");
            _ = dvui.checkbox(@src(), &kept.dead, "Dead-key chord", .{ .margin = .{ .y = 2, .h = 4 } });
        }
    }
    if (value.one_shot) |*one| {
        const box = card(t, 11);
        defer box.deinit();
        if (cardTitle(t, "One-shot", true, "action.remove.one_shot")) {
            value.one_shot = null;
        } else try hold(one, doc, "One-shot modifiers", t);
    }
    if (value.custom) |*id| {
        const line = partLine(t, "Callback", 12);
        defer line.deinit();
        if (customChoice(t, id, "Tap callback ID", "action.remove.callback")) value.custom = null;
    }
    if (value.media_key) |*media| {
        const line = partLine(t, "Media key", 13);
        defer line.deinit();
        _ = dvui.dropdownEnum(@src(), types.MediaCode, .{ .choice = media }, .{}, .{ .expand = .horizontal, .corners = .all(7), .gravity_y = 0.5 });
        if (removeButton(t, "action.remove.media")) value.media_key = null;
    }
    if (value.mouse_action) |*mouse| {
        const line = partLine(t, "Mouse", 14);
        defer line.deinit();
        _ = dvui.dropdownEnum(@src(), types.MouseAction, .{ .choice = mouse }, .{}, .{ .expand = .horizontal, .corners = .all(7), .gravity_y = 0.5 });
        if (removeButton(t, "action.remove.mouse")) value.mouse_action = null;
    }
    const additions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
    defer additions.deinit();
    if (value.key_press == null and addButton(t, "+ Key", "action.add.key")) value.key_press = .{ .tap_keycode = 4 };
    if (value.one_shot == null and addButton(t, "+ One-shot layer", "action.add.one_shot")) value.one_shot = .{};
    if (value.custom == null and addButton(t, "+ Callback or signal", "action.add.callback")) value.custom = 1;
    if (value.media_key == null and addButton(t, "+ Media key", "action.add.media")) value.media_key = .VolumeUp;
    if (value.mouse_action == null and addButton(t, "+ Mouse", "action.add.mouse")) value.mouse_action = .WheelDown;
}

/// A searchable HID usage picker. The combo box text shows the current usage
/// until the user types, then filters by name, host label or code.
fn keyChoice(code: *u8) void {
    const combo = dvui.comboBox(@src(), .{ .placeholder = "Type a key name or HID code…" }, .{
        .expand = .horizontal,
        .tag = "action.key.search",
        .corners = .all(7),
        .gravity_y = 0.5,
    });
    defer combo.deinit();
    const id = combo.te.data().id;
    const previous = dvui.dataGet(null, id, "selected_code", u8);
    var filtering = dvui.dataGet(null, id, "filtering", bool) orelse false;
    if (previous == null or previous.? != code.*) {
        var buffer: [64]u8 = undefined;
        combo.te.textSet(labels.usage(code.*, &buffer), false);
        filtering = false;
    }
    if (combo.te.text_changed) {
        filtering = true;
        combo.sug.selected_index = 0;
        combo.sug.open();
    }
    combo.sug.options.max_size_content = .height(240);
    const query = if (filtering) combo.te.getText() else "";
    var name_buffers: [256][80]u8 = undefined;
    var names: [256][]const u8 = undefined;
    var codes: [256]u8 = undefined;
    var count: usize = 0;
    for (0..256) |candidate| {
        const usage: u8 = @intCast(candidate);
        var buffer: [64]u8 = undefined;
        const name = labels.usage(usage, &buffer);
        const caption = std.fmt.bufPrint(&name_buffers[count], "{s} ({d})", .{ name, candidate }) catch unreachable;
        const matches = query.len == 0 or labels.containsIgnoreCase(caption, query) or
            labels.matchesUsage(labels.running_host, usage, query);
        if (!matches) continue;
        names[count] = caption;
        codes[count] = usage;
        count += 1;
    }
    if (combo.entries(names[0..count])) |choice| {
        code.* = codes[choice];
        var buffer: [64]u8 = undefined;
        combo.te.textSet(labels.usage(code.*, &buffer), false);
        filtering = false;
    }
    dvui.dataSet(null, id, "selected_code", code.*);
    dvui.dataSet(null, id, "filtering", filtering);
}

const home_row_mods = [_][]const u8{
    "Home row mod…",
    "Hold left Control",
    "Hold left Shift",
    "Hold left Alt / Option",
    "Hold left GUI / Command",
    "Hold right Control",
    "Hold right Shift",
    "Hold right Alt / Option",
    "Hold right GUI / Command",
};

/// Indexed by `Draft.mode`.
const modes = [_][]const u8{ "Inherit", "No action", "Tap", "Hold", "Tap–hold", "Autofire" };
const mode_values = [_]usize{ 0, 1, 2, 3, 4, 5 };

pub fn draw(draft: *Draft, doc: p.Document, theme: ui.Theme, options: Options) !void {
    try draft.validate();
    if (doc.layers.len == 0 or doc.layers.len > p.Limits.layers) return error.InvalidActionFormLayers;
    const first: usize = if (options.inherit) 0 else 1;
    _ = segmented(theme, modes[first..], mode_values[first..], &draft.mode, "action.mode");
    switch (draft.mode) {
        0 => note(theme, "The key does what the layer below assigns."),
        1 => note(theme, "Sends nothing."),
        else => {},
    }
    if (draft.mode == 2 or draft.mode == 4 or draft.mode == 5) {
        const box = card(theme, 1);
        defer box.deinit();
        _ = cardTitle(theme, "Tap", false, "action.tap");
        try tap(&draft.tap, doc, theme);
    }
    if (draft.mode == 3 or draft.mode == 4) {
        const box = card(theme, 2);
        defer box.deinit();
        {
            const line = row(5);
            defer line.deinit();
            dvui.labelNoFmt(@src(), "Hold", .{}, .{
                .font = ui.editorFont("Hold", 15).withWeight(.bold),
                .color_text = .{ .color = theme.text },
                .expand = .horizontal,
                .gravity_y = 0.5,
            });
            if (draft.tap.key_press != null and draft.mode == 4) {
                var choice: usize = 0;
                if (dvui.dropdown(@src(), &home_row_mods, .{ .choice = &choice }, .{}, .{
                    .min_size_content = .{ .w = 190 },
                    .corners = .all(7),
                    .gravity_y = 0.5,
                })) {
                    if (choice > 0) draft.homeRowMod(@as(u8, 1) << @intCast(choice - 1));
                }
            }
        }
        try hold(&draft.hold, doc, "Hold modifiers", theme);
    }
    if (draft.mode == 4 or draft.mode == 5) {
        const line = row(6);
        defer line.deinit();
        if (draft.mode == 4) {
            number(theme, u16, &draft.term, "Tapping term", "ms");
            _ = dvui.checkbox(@src(), &draft.retro, "Retro tapping", .{ .gravity_y = 0.5 });
        } else {
            number(theme, u16, &draft.initial, "Initial delay", "ms");
            number(theme, u16, &draft.repeat, "Repeat every", "ms");
        }
    }
}
