//! Retained typed controls over an owned draft; document commit stays explicit.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const p = @import("project");
const types = @import("layout-model");
const labels = desktop.labels;

pub const Draft = desktop.action_form.Draft;

fn number(comptime T: type, value: *T, title: []const u8) void {
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = std.hash.Wyhash.hash(0, title) });
    defer row.deinit();
    dvui.labelNoFmt(@src(), title, .{}, .{ .min_size_content = .{ .w = 200 } });
    _ = dvui.textEntryNumber(@src(), T, .{ .value = value }, .{ .min_size_content = .{ .w = 110, .h = 26 }, .padding = .all(6) });
}

const modifier_fields = .{ "left_ctrl", "left_shift", "left_alt", "left_gui", "right_ctrl", "right_shift", "right_alt", "right_gui" };

/// The running host's name for modifier bit `bit`, left side first.
fn modifierLabel(comptime bit: usize) []const u8 {
    const side = if (bit < 4) "L " else "R ";
    return switch (bit % 4) {
        0 => side ++ "Control",
        1 => side ++ "Shift",
        2 => if (labels.running_host == .macos) side ++ "Option" else side ++ "Alt",
        3 => switch (labels.running_host) {
            .macos => side ++ "Command",
            .windows => side ++ "Windows",
            .linux => side ++ "Super",
        },
        else => unreachable,
    };
}

/// Left and right modifier checkboxes, one row per side.
fn modifiers(mods: *types.Modifiers, title: []const u8) void {
    const box = dvui.box(@src(), .{}, .{ .id_extra = std.hash.Wyhash.hash(0, title), .expand = .horizontal });
    defer box.deinit();
    dvui.labelNoFmt(@src(), title, .{}, .{});
    inline for (0..2) |side| {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = side });
        defer row.deinit();
        inline for (modifier_fields, 0..) |field, i| {
            if (i / 4 == side) {
                var checked = @field(mods, field);
                if (dvui.checkbox(@src(), &checked, modifierLabel(i), .{ .id_extra = i })) @field(mods, field) = checked;
            }
        }
    }
}

pub fn hold(value: *p.Hold, doc: p.Document, title: []const u8) !void {
    if (doc.layers.len == 0 or doc.layers.len > p.Limits.layers) return error.InvalidActionFormLayers;
    const box = dvui.box(@src(), .{}, .{ .id_extra = std.hash.Wyhash.hash(0, title), .expand = .horizontal });
    defer box.deinit();
    dvui.labelNoFmt(@src(), title, .{}, .{});
    modifiers(&value.hold_modifiers, "Hold modifiers (left/right)");
    var selected: usize = 0;
    var names: [16][]const u8 = undefined;
    names[0] = "No layer";
    for (doc.layers, 0..) |layer, i| {
        names[i + 1] = layer.name;
        if (value.layer_id == layer.id) selected = i + 1;
    }
    if (dvui.dropdown(@src(), names[0 .. doc.layers.len + 1], .{ .choice = &selected }, .{}, .{ .expand = .horizontal })) {
        value.layer_id = if (selected == 0) null else doc.layers[selected - 1].id;
    }
    var has_custom = value.custom != null;
    if (dvui.checkbox(@src(), &has_custom, "Custom hold callback / reserved signal", .{})) value.custom = if (has_custom) 1 else null;
    if (value.custom) |*id| customChoice(id, "Hold callback ID");
}

/// Reserved companion signals use custom IDs 253 to 255; other IDs are callbacks.
const signals = [_][]const u8{ "Custom callback", "Toggle companion logging", "Quit companion", "Show / hide companion" };

fn customChoice(id: *u8, title: []const u8) void {
    var selected: usize = switch (id.*) {
        253 => 1,
        254 => 2,
        255 => 3,
        else => 0,
    };
    if (dvui.dropdown(@src(), &signals, .{ .choice = &selected }, .{}, .{ .expand = .horizontal })) id.* = switch (selected) {
        1 => 253,
        2 => 254,
        3 => 255,
        else => 1,
    };
    if (selected == 0) number(u8, id, title);
}

pub fn tap(value: *p.Tap, doc: p.Document) !void {
    dvui.label(@src(), "Tap fields may coexist; uncheck a field only to remove it.", .{}, .{});
    var has_key = value.key_press != null;
    if (dvui.checkbox(@src(), &has_key, "Key / modifier chord", .{})) value.key_press = if (has_key) .{ .tap_keycode = 4 } else null;
    if (value.key_press) |*key| {
        keyChoice(&key.tap_keycode);
        number(u8, &key.tap_keycode, "HID usage (252 = recovery)");
        modifiers(&key.tap_modifiers, "Tap modifiers (left/right)");
        _ = dvui.checkbox(@src(), &key.dead, "Dead-key chord", .{});
    }
    var has_one_shot = value.one_shot != null;
    if (dvui.checkbox(@src(), &has_one_shot, "One-shot hold", .{})) value.one_shot = if (has_one_shot) .{} else null;
    if (value.one_shot) |*one| try hold(one, doc, "One-shot fields");
    var has_custom = value.custom != null;
    if (dvui.checkbox(@src(), &has_custom, "Custom tap callback / reserved signal", .{})) value.custom = if (has_custom) 1 else null;
    if (value.custom) |*id| customChoice(id, "Tap callback ID");
    var has_media = value.media_key != null;
    if (dvui.checkbox(@src(), &has_media, "Consumer / media key", .{})) value.media_key = if (has_media) .VolumeUp else null;
    if (value.media_key) |*media| _ = dvui.dropdownEnum(@src(), types.MediaCode, .{ .choice = media }, .{}, .{ .expand = .horizontal });
    var has_mouse = value.mouse_action != null;
    if (dvui.checkbox(@src(), &has_mouse, "Mouse action", .{})) value.mouse_action = if (has_mouse) .WheelDown else null;
    if (value.mouse_action) |*mouse| _ = dvui.dropdownEnum(
        @src(),
        types.MouseAction,
        .{ .choice = mouse },
        .{},
        .{ .expand = .horizontal },
    );
}

/// A searchable HID usage picker. The combo box text shows the current usage
/// until the user types, then filters by name, host label or code.
fn keyChoice(code: *u8) void {
    const combo = dvui.comboBox(@src(), .{ .placeholder = "Type a key name or HID code…" }, .{
        .expand = .horizontal,
        .tag = "action.key.search",
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
    "Set home row mod…",
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
const modes = [_][]const u8{
    "Transparent / inherited",
    "Explicit no action",
    "Tap only",
    "Hold only",
    "Tap / hold",
    "Tap with autofire",
};

pub fn draw(draft: *Draft, doc: p.Document) !void {
    try draft.validate();
    if (doc.layers.len == 0 or doc.layers.len > p.Limits.layers) return error.InvalidActionFormLayers;
    if (draft.tap.key_press != null and (draft.mode == 2 or draft.mode == 4)) {
        var choice: usize = 0;
        if (dvui.dropdown(@src(), &home_row_mods, .{ .choice = &choice }, .{}, .{ .expand = .horizontal })) {
            if (choice > 0) draft.homeRowMod(@as(u8, 1) << @intCast(choice - 1));
        }
        if (draft.mode == 4) {
            dvui.label(@src(), "Home row mod: keep the tap key, choose hold modifiers below.", .{}, .{});
        }
    }
    _ = dvui.dropdown(@src(), &modes, .{ .choice = &draft.mode }, .{}, .{ .expand = .horizontal });
    if (draft.mode == 2 or draft.mode == 4 or draft.mode == 5) try tap(&draft.tap, doc);
    if (draft.mode == 3 or draft.mode == 4) try hold(&draft.hold, doc, "Hold fields");
    if (draft.mode == 4) {
        number(u16, &draft.term, "Tapping term (ms)");
        _ = dvui.checkbox(@src(), &draft.retro, "Retro tapping", .{});
    }
    if (draft.mode == 5) {
        number(u16, &draft.initial, "Initial delay (ms)");
        number(u16, &draft.repeat, "Repeat interval (ms)");
    }
}
