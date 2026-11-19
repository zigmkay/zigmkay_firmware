//! Retained OS keyboard chord source; injected owned previews only.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const Chord = desktop.chord_action.Action;

pub const View = struct {
    shift: bool = false,
    option: bool = false,
    drag: ?Chord = null,
    source_revision: ?u64 = null,
};

/// A modifier toggle, filled with the accent color while it is on.
fn toggle(theme: ui.Theme, on: bool, text: []const u8, tag: []const u8, bounds: dvui.Rect) bool {
    const tint = if (on) ui.color(0xFFFFFF) else theme.text;
    var opts = ui.options(theme, bounds, 13);
    opts.tag = tag;
    opts.id_extra = std.hash.Wyhash.hash(0, tag);
    opts.background = true;
    opts.border = .all(if (on) 0 else 1);
    opts.corners = .all(8);
    opts.padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 };
    if (on) opts.color_fill = .{ .color = theme.accent };
    return ui.richButton(@src(), text, .{ .color = tint, .secondary = tint, .size = 15, .id_extra = opts.id_extra.? }, opts);
}

fn cancelDrag(view: *View) void {
    view.drag = null;
    if (dvui.dragName("key_chord")) dvui.dragEnd();
}

/// Draws the OS keyboard. While the tap editor is open (`tap_editor`), a hint
/// says that a click sets the tap.
pub fn draw(view: *View, model: *const desktop.model.Model, cache: *const desktop.host_palette.Cache, theme: ui.Theme, tap_editor: bool) !?Chord {
    const panel_rect = ui.panelRect(.os);
    const box = ui.panel(theme, .os);
    defer box.deinit();
    ui.label(theme, "OS keyboard", .{ .x = 20, .y = 20, .w = 140, .h = 26 }, 19);
    var muted = theme;
    muted.text = theme.muted;
    const source_w = @min(@as(f32, 420), ui.editorFont(cache.source_id, 12).textSize(cache.source_id).w + 4);
    ui.label(muted, cache.source_id, .{ .x = 152, .y = 26, .w = source_w, .h = 18 }, 12);
    if (tap_editor) hint(theme, .{ .x = 152 + source_w + 14, .y = 18, .w = 250, .h = 28 });
    const symbols = desktop.labels.keycap_symbols.Symbol;
    if (toggle(theme, view.shift, symbols.literal(.shift) ++ " Shift", "os.shift", .{ .x = panel_rect.w - 172, .y = 14, .w = 72, .h = 30 })) view.shift = !view.shift;
    const option = if (cache.host == .macos) symbols.literal(.option) ++ " Option" else "Alt";
    if (toggle(theme, view.option, option, "os.option", .{ .x = panel_rect.w - 92, .y = 14, .w = 72, .h = 30 })) view.option = !view.option;
    // A drag started from an older input source preview no longer matches its captions.
    if (view.source_revision != null and view.source_revision.? != cache.revision) cancelDrag(view);
    view.source_revision = cache.revision;
    if (view.drag) |drag| drag.validate(model) catch cancelDrag(view);
    var result: ?Chord = null;
    // Rows are centered; one unit is a regular key and its gap.
    var widest: f32 = 0;
    for (desktop.host_palette.rows) |row| {
        var units: f32 = 0;
        for (row) |key| units += key.units;
        widest = @max(widest, units);
    }
    const unit = @min(@as(f32, 64), (panel_rect.w - 40) / widest);
    const left = (panel_rect.w - widest * unit) / 2;
    for (desktop.host_palette.rows, 0..) |row, ri| {
        var x: f32 = left;
        for (row, 0..) |key, ki| {
            const caption = cache.caption(key.code, view.shift, view.option);
            const length = std.unicode.utf8CountCodepoints(caption) catch caption.len;
            const size: f32 = if (length > 3) 13 else 19;
            const bounds: dvui.Rect = .{ .x = x, .y = 58 + @as(f32, @floatFromInt(ri)) * 44, .w = unit * key.units - 5, .h = 39 };
            var opts = ui.options(theme, bounds, size);
            opts.padding = .all(2);
            opts.id_extra = ri * 100 + ki;
            opts.background = true;
            opts.gravity_x = 0.5;
            opts.gravity_y = 0.5;
            opts.border = .all(1);
            opts.corners = .all(6);
            opts.color_fill = .{ .color = theme.keycap };
            opts.tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "os.key.{d}", .{key.code});
            if (try dragSource(view, model, key.code, caption, size, opts)) |action| {
                if (result == null) result = action;
            }
            x += unit * key.units;
        }
    }
    return result;
}

/// A key that starts a chord drag on press. Returns the chord when the drag is
/// released on the key itself instead of on a drop target.
fn dragSource(view: *View, model: *const desktop.model.Model, code: u8, caption: []const u8, size: f32, opts: dvui.Options) !?Chord {
    var key: dvui.ButtonWidget = undefined;
    key.init(@src(), .{}, opts);
    defer key.deinit();
    var result: ?Chord = null;
    for (dvui.events()) |*event| {
        if (!key.matchEvent(event) or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action == .press and mouse.button == .left) {
            event.handle(@src(), key.data());
            dvui.captureMouse(key.data(), event.num);
            dvui.focusWidget(key.data().id, null, null);
            view.drag = try Chord.capture(model, .{
                .tap_keycode = code,
                .tap_modifiers = .{ .left_shift = view.shift, .left_alt = view.option },
            });
            dvui.dragPreStart(.left, mouse.p, .{ .name = "key_chord", .cursor = .crosshair });
        } else if (mouse.action == .motion and dvui.captured(key.data().id)) {
            if (dvui.dragging(mouse.p, "key_chord")) |_| {
                event.handle(@src(), key.data());
                dvui.captureMouse(null, event.num);
            }
        } else if (mouse.action == .release and mouse.button == .left and dvui.captured(key.data().id)) {
            event.handle(@src(), key.data());
            dvui.captureMouse(null, event.num);
            dvui.dragEnd();
            result = view.drag;
            view.drag = null;
        } else if (mouse.action == .position) key.hover = true;
    }
    key.drawBackground();
    const content = key.data().contentRect();
    const tint = opts.color_text.?.color;
    ui.caption(caption, .{ .w = content.w, .h = content.h }, .{
        .color = tint,
        .secondary = tint,
        .size = size,
        .id_extra = opts.id_extra orelse 0,
    });
    key.drawFocus();
    return result;
}

/// The accent pill that tells a click on the OS keyboard sets the tap.
fn hint(theme: ui.Theme, bounds: dvui.Rect) void {
    const pill = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, theme.accent, 0.14) },
        .color_border = .{ .color = theme.accent },
        .border = .all(1),
        .corners = .all(14),
        .padding = .{},
        .margin = .{},
        .tag = "os.hint",
    });
    pill.deinit();
    dvui.icon(@src(), "hint", ui.control_icons.keyboard, .{}, .{
        .rect = .{ .x = bounds.x + 10, .y = bounds.y + 7, .w = 14, .h = 14 },
        .color_text = .{ .color = theme.accent },
        .padding = .{},
        .margin = .{},
    });
    ui.label(theme, "Click a key to set the tap", .{ .x = bounds.x + 30, .y = bounds.y + 5, .w = bounds.w - 36, .h = 18 }, 12);
}
