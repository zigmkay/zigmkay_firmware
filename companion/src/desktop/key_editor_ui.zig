//! The editor of one key half, opened from the keyboard canvas as a popover at
//! the key, and the strip below the keyboard that explains the primary key.
//! The upper half edits the tap, the lower half the hold or autofire; the key
//! type follows from what is set. Every change applies at once and undo
//! reverts it.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const p = @import("project");
const ui = @import("editor-ui");
const keyboard = @import("keyboard-ui");
const labels = desktop.labels;
const catalog = desktop.action_catalog;
const editing = desktop.inspector_session;
const Modifiers = @FieldType(@typeInfo(@FieldType(p.Tap, "key_press")).optional.child, "tap_modifiers");

pub const Part = keyboard.Part;
pub const Intent = desktop.inspector_action.Intent;
pub const Action = desktop.inspector_action.Action;

pub const View = struct {
    /// The open half editor, anchored at the primary key.
    open: ?Part = null,
    /// The layer the editor was opened on; switching layers closes it.
    layer: usize = 0,
    category: catalog.Category = .all,
    search: [128]u8 = @splat(0),
    /// Waiting for a key press on the computer's keyboard to become the tap.
    listening: bool = false,
    /// The side new modifiers go to while none is set, per part.
    right: [2]bool = .{ false, false },
    diagnostic: [128]u8 = @splat(0),
    pending: bool = false,
    close_requested: bool = false,
};

pub const Frame = struct {
    /// Screen rectangle of the primary key on the canvas.
    anchor: ?dvui.Rect.Physical,
    /// OS keyboard captions, to turn typed text into key usages.
    host: *const desktop.host_palette.Cache,
};

/// Inner padding of number fields, so their digits fit a 34 high field.
const number_padding: dvui.Rect = .{ .x = 8, .y = 5, .w = 8, .h = 5 };
const tap_width: f32 = 440;
const hold_width: f32 = 430;
const margin: f32 = 18;

/// Borrowed for one frame. Mutations go straight to the session's drafts.
const Context = struct {
    session: *editing.Session,
    model: *const desktop.model.Model,
    view: *View,
    theme: ui.Theme,
    muted: ui.Theme,
    host: *const desktop.host_palette.Cache,
    intent: Intent = .none,

    /// Keeps the first intent requested during the frame.
    fn choose(self: *Context, intent: Intent) void {
        if (self.intent == .none) self.intent = intent;
    }

    fn report(self: *Context, failure: anyerror) void {
        @memset(&self.view.diagnostic, 0);
        const name = @errorName(failure);
        const count = @min(name.len, self.view.diagnostic.len - 1);
        @memcpy(self.view.diagnostic[0..count], name[0..count]);
    }

    /// The primary key's action, or the action it falls through to.
    fn primaryAction(self: *const Context) ?p.Action {
        return self.session.first() orelse self.session.resolved[self.session.primary];
    }

    fn selectedCount(self: *const Context) usize {
        var count: usize = 0;
        for (self.session.selected) |selected| count += @intFromBool(selected);
        return count;
    }

    fn mixed(self: *const Context) bool {
        for (self.session.selected, self.session.drafts) |selected, action| {
            if (selected and !std.meta.eql(action, self.session.first())) return true;
        }
        return false;
    }
};

pub fn draw(session: *editing.Session, model: *const desktop.model.Model, view: *View, theme: ui.Theme, frame: Frame) !?Action {
    if (try session.stale(model)) return error.StaleSession;
    var muted = theme;
    muted.text = theme.muted;
    var context: Context = .{
        .session = session,
        .model = model,
        .view = view,
        .theme = theme,
        .muted = muted,
        .host = frame.host,
    };
    if (view.open != null and view.layer != model.layer) close(view);
    const before = try dvui.currentWindow().arena().dupe(?p.Action, session.drafts);
    try drawBar(&context);
    if (view.pending or view.close_requested) {
        view.listening = false;
    } else if (view.open) |part| if (frame.anchor) |anchor| try drawPopover(&context, part, anchor);
    // Edits apply at once. An invalid draft stays staged with its diagnostic
    // until the next valid edit, Discard or another key.
    var changed = false;
    for (before, session.drafts) |old, staged| changed = changed or !std.meta.eql(old, staged);
    if (changed and context.intent == .none) {
        @memset(&view.diagnostic, 0);
        if (session.validate(model)) |_| context.choose(.apply) else |err| context.report(err);
    }
    return if (context.intent == .none) null else try Action.capture(session, model, context.intent);
}

/// Opens the editor of `part` on the current layer.
pub fn open(view: *View, part: Part, layer: usize) void {
    if (view.open != part) {
        view.search = @splat(0);
        view.category = .all;
    }
    view.open = part;
    view.layer = layer;
    view.listening = false;
}

pub fn close(view: *View) void {
    view.open = null;
    view.listening = false;
}

// The strip below the keyboard -------------------------------------------------

/// What the primary key does in plain words, its clipboard and its fall-back
/// actions. A pending request or close question replaces the actions.
fn drawBar(self: *Context) !void {
    const t = self.theme;
    const panel = ui.panelRect(.physical);
    const top = panel.y + panel.h - keyboard.bar_height;
    const left = panel.x + 20;
    const right = panel.x + panel.w - 20;
    ui.divider(t, .{ .x = left, .y = top, .w = right - left, .h = 1 }, 0xba7);
    const row = top + 16;
    drawKeycap(self, .{ .x = left, .y = row, .w = 44, .h = 44 });
    const text_x = left + 58;
    if (self.view.pending or self.view.close_requested) {
        const pending = self.view.pending;
        ui.label(t, if (pending) "Unapplied edits · resolve before continuing" else "Unsaved layout · save before closing", .{
            .x = text_x,
            .y = row + 12,
            .w = 420,
            .h = 20,
        }, 14);
        const buttons = if (pending)
            [3][2][]const u8{ .{ "Apply", "pending.apply" }, .{ "Discard", "pending.discard" }, .{ "Keep editing", "pending.keep" } }
        else
            [3][2][]const u8{ .{ "Save and close", "close.save" }, .{ "Close", "close.discard" }, .{ "Keep editing", "close.keep" } };
        const widths = [3]f32{ if (pending) 96 else 140, 96, 128 };
        var x = right;
        var index: usize = 3;
        while (index > 0) {
            index -= 1;
            x -= widths[index];
            if (ui.iconButton(t, null, buttons[index][0], buttons[index][1], .{ .x = x, .y = row + 4, .w = widths[index], .h = 36 }, index == 0)) {
                self.choose(switch (index) {
                    0 => if (pending) .resolve_apply else .save_close,
                    1 => if (pending) .resolve_discard else .discard_close,
                    else => if (pending) .keep_editing else .keep_close,
                });
                if (index == 2) {
                    self.view.pending = false;
                    self.view.close_requested = false;
                }
            }
            x -= 8;
        }
        return;
    }
    // Clipboard and fall-back actions, right-aligned.
    const actions = [_]struct { icon: []const u8, text: []const u8, tag: []const u8, w: f32 }{
        .{ .icon = ui.control_icons.copy, .text = "Copy", .tag = "edit.copy", .w = 92 },
        .{ .icon = ui.control_icons.paste, .text = "Paste", .tag = "edit.paste", .w = 96 },
        .{ .icon = ui.control_icons.inherit, .text = "Inherit", .tag = "key.inherit", .w = 104 },
        .{ .icon = ui.control_icons.nothing, .text = "No action", .tag = "key.unassign", .w = 124 },
    };
    var x = right;
    var widths: f32 = 0;
    for (actions) |entry| widths += entry.w + 8;
    x -= widths - 8;
    const actions_left = x;
    for (actions, 0..) |entry, index| {
        const enabled = index != 2 or self.model.layer > 0;
        if (ui.iconButtonEnabled(t, entry.icon, entry.text, entry.tag, .{ .x = x, .y = row + 4, .w = entry.w, .h = 36 }, false, enabled)) switch (index) {
            0 => self.choose(.copy),
            1 => self.choose(.paste),
            2 => self.session.mutate(.inherit),
            else => self.session.mutate(.unassign),
        };
        x += entry.w + 8;
    }
    const diagnostic = std.mem.sliceTo(&self.view.diagnostic, 0);
    var sentence: [640]u8 = undefined;
    const text = if (diagnostic.len != 0) diagnostic else try describe(self, &sentence);
    ui.caption(text, .{ .x = text_x, .y = row + 2, .w = actions_left - text_x - 16, .h = 40 }, .{
        .color = if (diagnostic.len != 0) t.danger else t.text,
        .secondary = t.muted,
        .size = 15,
        .align_x = 0,
        .id_extra = 0x30000,
        .layers = t.layers,
    });
}

/// The selection in plain words: the primary key's behaviour, or how many
/// keys are selected when they differ.
fn describe(self: *const Context, buffer: []u8) ![]const u8 {
    const count = self.selectedCount();
    const doc = self.model.document();
    var behaviour: [512]u8 = undefined;
    const own = self.session.first();
    const said = if (own == null and self.session.resolved[self.session.primary] != null)
        try std.fmt.bufPrint(&behaviour, "Falls through · {s}", .{labels.behaviour(self.primaryAction(), doc, behaviour[256..])})
    else
        labels.behaviour(own, doc, &behaviour);
    if (count <= 1) return std.fmt.bufPrint(buffer, "{s}", .{said}) catch said;
    if (self.mixed()) return std.fmt.bufPrint(buffer, "{d} keys selected · different actions", .{count});
    return std.fmt.bufPrint(buffer, "{d} keys · {s}", .{ count, said });
}

/// The primary key as the canvas draws it, on the edited layer's color.
fn drawKeycap(self: *Context, bounds: dvui.Rect) void {
    const t = self.theme;
    const face = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = t.keycap },
        .color_border = .{ .color = ui.layerColor(t, self.model.layer) },
        .border = .all(2),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = "key.preview",
    });
    face.deinit();
    var buffer: [512]u8 = undefined;
    const caption = labels.keycap(self.primaryAction(), self.model.document(), &buffer);
    ui.caption(caption, .{ .x = bounds.x + 5, .y = bounds.y + 5, .w = bounds.w - 10, .h = bounds.h - 10 }, .{
        .color = t.text,
        .secondary = t.muted,
        .size = 18,
        .id_extra = 0x30001,
        .layers = t.layers,
    });
}

// The popover -----------------------------------------------------------------

/// Places the editor below the key, or above it when the window ends first.
fn drawPopover(self: *Context, part: Part, anchor: dvui.Rect.Physical) !void {
    const width = if (part == .tap) tap_width else hold_width;
    const height = if (part == .tap) tapHeight(self) else holdHeight(self);
    const scale = dvui.parentGet().screenRectScale(.{}).s / dvui.windowNaturalScale();
    const key = anchor.toNatural();
    const window = dvui.windowRect();
    const w = width * scale;
    const h = height * scale;
    const gap = 10 * scale;
    var y = key.y + key.h + gap;
    if (y + h > window.h - 8 and key.y - gap - h >= 8) y = key.y - gap - h;
    const rect: dvui.Rect = .{
        .x = std.math.clamp(key.x + key.w / 2 - w / 2, 8, @max(8, window.w - w - 8)),
        .y = std.math.clamp(y, 8, @max(8, window.h - h - 8)),
        .w = w,
        .h = h,
    };
    const popover = dvui.floatingWindow(@src(), .{ .resize = .none }, .{
        .rect = rect,
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = self.theme.panel },
        .color_border = .{ .color = ui.mix(self.theme.border, self.theme.text, 0.12) },
        .border = .all(1),
        .corners = .all(14),
        .box_shadow = .{ .offset = .{ .x = 0, .y = 8 }, .fade = 24, .alpha = 0.35 },
        .tag = "key.editor",
    });
    defer popover.deinit();
    if (header(self, part, width)) {
        dropFocus();
        close(self.view);
        return;
    }
    switch (part) {
        .tap => try drawTap(self, width, height),
        .hold => try drawHold(self, width, height),
    }
    // Escape closes the editor unless a key is being captured.
    if (!self.view.listening) for (dvui.events()) |*event| switch (event.evt) {
        .key => |pressed| if (pressed.action == .down and pressed.code == .escape and !event.handled) {
            event.handle(@src(), popover.data());
            dropFocus();
            close(self.view);
        },
        else => {},
    };
}

/// Clears the focus inside the closing popover. Otherwise its last focused
/// control, which never draws again, leaves dvui waiting to scroll the
/// canvas to whatever the editor focuses next.
fn dropFocus() void {
    dvui.focusWidget(null, null, null);
}

/// Title, subtitle and close button. Returns true when closed.
fn header(self: *Context, part: Part, width: f32) bool {
    const t = self.theme;
    ui.label(t, if (part == .tap) "Tap" else "Hold", .{ .x = margin, .y = 14, .w = 200, .h = 24 }, 17);
    const count = self.selectedCount();
    const layer = self.model.document().layers[self.model.layer].name;
    var buffer: [192]u8 = undefined;
    const subtitle = if (count > 1)
        std.fmt.bufPrint(&buffer, "{d} keys · {s}", .{ count, layer }) catch layer
    else
        std.fmt.bufPrint(&buffer, "{s} · {s}", .{ if (part == .tap) "When tapped" else "When held", layer }) catch layer;
    ui.label(self.muted, subtitle, .{ .x = margin, .y = 38, .w = width - 80, .h = 18 }, 12);
    return ui.iconButton(t, ui.control_icons.remove, "", "key.editor.close", .{ .x = width - margin - 30, .y = 14, .w = 30, .h = 30 }, false);
}

/// The footer: remove the half and a reminder that edits are live.
fn footer(self: *Context, part: Part, width: f32, height: f32) void {
    const y = height - 50;
    ui.divider(self.theme, .{ .x = 0, .y = y - 12, .w = width, .h = 1 }, 0xf00);
    const text = if (part == .tap) "Remove tap" else "Remove hold";
    if (ui.dangerButton(self.theme, ui.control_icons.delete, text, "key.editor.clear", .{ .x = margin, .y = y, .w = 150, .h = 34 })) {
        const autofire = if (self.primaryAction()) |action| action == .tap_with_autofire else false;
        self.session.mutate(if (part == .tap) .clear_tap else if (autofire) .{ .mode = .tap } else .clear_hold);
    }
    var hint = ui.options(self.muted, .{ .x = margin + 160, .y = y + 8, .w = width - 2 * margin - 160, .h = 18 }, 12);
    hint.padding = .{};
    hint.background = false;
    hint.color_text = .{ .color = self.theme.muted };
    dvui.labelNoFmt(@src(), "Applies at once · Undo reverts it", .{ .align_x = 1 }, hint);
}

fn sectionLabel(self: *Context, text: []const u8, y: f32) void {
    ui.label(self.muted, text, .{ .x = margin, .y = y, .w = 380, .h = 16 }, 12);
}

// Tap ---------------------------------------------------------------------------

fn tapHeight(self: *const Context) f32 {
    const tap = editing.tapPart(self.primaryAction());
    var height: f32 = 542;
    if (tap.one_shot != null) height += 52;
    if (tap.custom != null) height += 46;
    return height;
}

fn drawTap(self: *Context, width: f32, height: f32) !void {
    const t = self.theme;
    const inner = width - 2 * margin;
    try capture(self, .{ .x = margin, .y = 64, .w = inner, .h = 40 });
    var y: f32 = 114;
    tapComponents(self, .{ .x = margin, .y = y, .w = inner, .h = 32 });
    y += 42;
    const search = dvui.textEntry(@src(), .{ .text = .{ .buffer = &self.view.search }, .placeholder = "Search keys, symbols, media…" }, .{
        .rect = .{ .x = margin, .y = y, .w = inner, .h = 36 },
        .tag = "key.editor.search",
        .font = ui.editorFont("Search", 14),
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        .margin = .{},
    });
    search.deinit();
    y += 44;
    try categories(self, .tap, .{ .x = margin - 2, .y = y, .w = inner + 4, .h = 66 });
    y += 70;
    try results(self, .tap, .{ .x = margin, .y = y, .w = inner, .h = 132 });
    y += 144;
    sectionLabel(self, "Sent together with the key", y);
    modifierRow(self, .tap, y + 20);
    const key_press = editing.tapPart(self.primaryAction()).key_press;
    if (key_press) |key| {
        var dead = key.dead;
        if (dvui.checkbox(@src(), &dead, "Dead key", .{
            .rect = .{ .x = width - margin - 120, .y = y - 4, .w = 120, .h = 22 },
            .tag = "key.editor.dead",
            .font = ui.editorFont("Dead key", 13),
            .color_text = .{ .color = t.text },
        })) self.session.mutate(.{ .tap_dead = dead });
    }
    y += 70;
    const tap = editing.tapPart(self.primaryAction());
    if (tap.one_shot) |one| {
        oneShot(self, one, y);
        y += 52;
    }
    if (tap.custom) |id| {
        callbackNumber(self, "Callback or signal ID", id, "tap_custom", y);
        y += 46;
    }
    footer(self, .tap, width, height);
}

/// The button that waits for a key press on the computer's keyboard. Typed
/// text is found on the OS keyboard, so the key follows the host layout.
fn capture(self: *Context, bounds: dvui.Rect) !void {
    const t = self.theme;
    const listening = self.view.listening;
    var data: dvui.WidgetData = undefined;
    var opts = ui.options(t, bounds, 14);
    opts.tag = "key.editor.capture";
    opts.background = true;
    opts.border = .all(if (listening) 1.5 else 1);
    opts.corners = .all(8);
    opts.padding = .{};
    opts.color_fill = .{ .color = if (listening) ui.mix(t.bg, t.accent, 0.12) else t.bg };
    opts.color_border = .{ .color = if (listening) t.accent else t.border };
    opts.data_out = &data;
    if (dvui.button(@src(), "", .{}, opts)) self.view.listening = !listening;
    dvui.icon(@src(), "capture", ui.control_icons.keyboard, .{}, .{
        .rect = .{ .x = bounds.x + 12, .y = bounds.y + 11, .w = 18, .h = 18 },
        .color_text = .{ .color = if (listening) t.accent else t.muted },
        .padding = .{},
        .margin = .{},
    });
    const text = if (listening) "Press a key… Esc cancels" else "Press a key on your keyboard";
    ui.label(if (listening) t else self.muted, text, .{ .x = bounds.x + 40, .y = bounds.y + 10, .w = bounds.w - 52, .h = 20 }, 14);
    if (!listening) return;
    dvui.wantTextInput(data.borderRectScale().r.toNatural());
    for (dvui.events()) |*event| {
        if (event.handled) continue;
        switch (event.evt) {
            .key => |key| {
                if (key.action != .down) continue;
                if (key.code == .escape) {
                    event.handle(@src(), &data);
                    self.view.listening = false;
                    return;
                }
                const usage = fixedUsage(key.code) orelse if (key.mod.control() or key.mod.command())
                    if (character(key.code)) |char| find(self.host, &.{char}, false) else null
                else
                    null;
                if (usage) |found| {
                    event.handle(@src(), &data);
                    var mods: Modifiers = .{
                        .left_ctrl = key.mod.control(),
                        .left_shift = key.mod.shift() or found.shift,
                        .left_alt = key.mod.alt() or found.option,
                        .left_gui = key.mod.command(),
                    };
                    if (found.code >= 224) mods = .{};
                    self.session.mutate(.{ .tap_key = .{ .tap_keycode = found.code, .tap_modifiers = mods } });
                    self.view.listening = false;
                    return;
                }
            },
            .text => |typed| switch (typed.action) {
                .value => |value| if (find(self.host, value.txt, true)) |found| {
                    event.handle(@src(), &data);
                    self.session.mutate(.{ .tap_key = .{
                        .tap_keycode = found.code,
                        .tap_modifiers = .{ .left_shift = found.shift, .left_alt = found.option },
                    } });
                    self.view.listening = false;
                    return;
                },
                else => {},
            },
            else => {},
        }
    }
}

const Found = struct { code: u8, shift: bool = false, option: bool = false };

/// The OS keyboard key that types `text`, trying it plain, shifted and with
/// Option. Letters match either case when `exact` is false.
fn find(host: *const desktop.host_palette.Cache, text: []const u8, exact: bool) ?Found {
    for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } }) |variant| {
        for (desktop.host_palette.rows) |row| for (row) |key| {
            const caption = host.caption(key.code, variant[0], variant[1]);
            const same = if (exact) std.mem.eql(u8, caption, text) else std.ascii.eqlIgnoreCase(caption, text);
            if (same and key.code >= 4 and key.code < 224) return .{ .code = key.code, .shift = variant[0], .option = variant[1] };
        };
    }
    return null;
}

/// HID usages of keys that type no text.
fn fixedUsage(code: dvui.enums.Key) ?Found {
    const usage: u8 = switch (code) {
        .enter => 40,
        .backspace => 42,
        .tab => 43,
        .space => 44,
        .caps_lock => 57,
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => 58 + @as(u8, @intCast(@backingInt(code) - @backingInt(dvui.enums.Key.f1))),
        .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24 => 104 + @as(u8, @intCast(@backingInt(code) - @backingInt(dvui.enums.Key.f13))),
        .print => 70,
        .scroll_lock => 71,
        .pause => 72,
        .insert => 73,
        .home => 74,
        .page_up => 75,
        .delete => 76,
        .end => 77,
        .page_down => 78,
        .right => 79,
        .left => 80,
        .down => 81,
        .up => 82,
        .menu => 101,
        else => return null,
    };
    return .{ .code = usage };
}

/// The character a text key types without modifiers on a US layout, used to
/// find shortcuts such as ⌘C that type no text.
fn character(code: dvui.enums.Key) ?u8 {
    const index = @backingInt(code);
    if (index <= @backingInt(dvui.enums.Key.z)) return 'a' + @as(u8, @intCast(index));
    if (index >= @backingInt(dvui.enums.Key.zero) and index <= @backingInt(dvui.enums.Key.nine))
        return '0' + @as(u8, @intCast(index - @backingInt(dvui.enums.Key.zero)));
    return switch (code) {
        .minus => '-',
        .equal => '=',
        .left_bracket => '[',
        .right_bracket => ']',
        .backslash => '\\',
        .semicolon => ';',
        .apostrophe => '\'',
        .comma => ',',
        .period => '.',
        .slash => '/',
        .grave => '`',
        else => null,
    };
}

/// The parts of the tap as chips with a remove button each.
fn tapComponents(self: *Context, bounds: dvui.Rect) void {
    const tap = editing.tapPart(self.primaryAction());
    const row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .rect = bounds, .padding = .{}, .margin = .{} });
    defer row.deinit();
    var buffer: [256]u8 = undefined;
    var name: [64]u8 = undefined;
    var any = false;
    if (tap.key_press) |key| {
        any = true;
        chip(self, labels.tap(.{ .key_press = key }, &buffer), "key.editor.remove.key", .{ .tap_key = null });
    }
    if (tap.one_shot) |one| {
        any = true;
        var text: [320]u8 = undefined;
        const shown = std.fmt.bufPrint(&text, "One-shot · {s}", .{labels.hold(one, self.model.document(), &buffer)}) catch "One-shot";
        chip(self, shown, "key.editor.remove.one_shot", .{ .tap_one_shot = null });
    }
    if (tap.media_key) |media| {
        any = true;
        chip(self, labels.spelled(labels.mediaSymbol(media), &name), "key.editor.remove.media", .{ .tap_media = null });
    }
    if (tap.mouse_action) |mouse| {
        any = true;
        chip(self, labels.spelled(labels.mouseSymbol(mouse), &name), "key.editor.remove.mouse", .{ .tap_mouse = null });
    }
    if (tap.custom) |id| {
        any = true;
        chip(self, labels.signal(id, &buffer), "key.editor.remove.callback", .{ .tap_custom = null });
    }
    if (!any) dvui.labelNoFmt(@src(), "Nothing on tap yet · pick a key below or press one", .{}, .{
        .font = ui.editorFont("Nothing", 13),
        .color_text = .{ .color = self.theme.muted },
        .gravity_y = 0.5,
        .padding = .{ .y = 7 },
    });
}

/// An assigned part with a button that removes it.
fn chip(self: *Context, text: []const u8, tag: []const u8, operation: editing.Operation) void {
    const t = self.theme;
    const id = std.hash.Wyhash.hash(0, tag);
    const style: ui.CaptionStyle = .{ .color = t.text, .secondary = t.text, .size = 14, .id_extra = id, .layers = t.layers };
    const size = ui.captionSize(text, style);
    const box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .min_size_content = .{ .w = size.w + 46, .h = 30 },
        .max_size_content = .{ .w = size.w + 46, .h = 30 },
        .background = true,
        .color_fill = .{ .color = ui.mix(t.control, t.accent, 0.16) },
        .color_border = .{ .color = ui.mix(t.border, t.accent, 0.5) },
        .border = .all(1),
        .corners = .all(15),
        .padding = .{},
        .margin = .{ .w = 6, .h = 4 },
    });
    defer box.deinit();
    ui.caption(text, .{ .x = 12, .y = 4, .w = size.w + 2, .h = 22 }, style);
    if (dvui.button(@src(), "×", .{}, .{
        .id_extra = id,
        .tag = tag,
        .rect = .{ .x = size.w + 18, .y = 3, .w = 24, .h = 24 },
        .font = ui.editorFont("×", 15),
        .color_text = .{ .color = t.muted },
        .background = false,
        .corners = .all(12),
        .padding = .{},
        .margin = .{},
    })) self.session.mutate(operation);
}

/// Search categories as wrapping chips; only those that fit the part show.
fn categories(self: *Context, target: catalog.Target, bounds: dvui.Rect) !void {
    const t = self.theme;
    const names = [_][]const u8{ "All", "Keys", "Modifiers", "Layers", "Media", "Mouse", "Callbacks", "One-shot", "Signals" };
    const chips = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .rect = bounds, .tag = "key.editor.category", .padding = .{}, .margin = .{} });
    defer chips.deinit();
    for (names, 0..) |name, index| {
        const category: catalog.Category = @fromBackingInt(@intCast(index));
        if (!catalog.available(target, category)) continue;
        if (target == .tap and category == .layer) continue;
        const chosen = self.view.category == category;
        const tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "key.editor.category.{d}", .{index});
        if (dvui.button(@src(), name, .{}, .{
            .tag = tag,
            .id_extra = index,
            .font = ui.editorFont(name, 13),
            .corners = .all(14),
            .padding = .{ .x = 11, .y = 5, .w = 11, .h = 5 },
            .margin = .{ .x = 2, .y = 2, .w = 4, .h = 4 },
            .background = true,
            .border = .all(1),
            .color_border = .{ .color = if (chosen) t.accent else t.border },
            .color_fill = .{ .color = if (chosen) ui.mix(t.control, t.accent, 0.22) else t.control },
            .color_text = .{ .color = if (chosen) t.text else t.muted },
        })) self.view.category = category;
    }
}

/// Search results as wrapping tiles; a click adds the result to the part.
fn results(self: *Context, target: catalog.Target, bounds: dvui.Rect) !void {
    const t = self.theme;
    const document = self.model.document();
    const area = dvui.scrollArea(@src(), .{}, .{ .rect = bounds, .background = false, .padding = .{}, .margin = .{} });
    defer area.deinit();
    const tiles = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .padding = .{}, .margin = .{} });
    defer tiles.deinit();
    var entries: [96]catalog.Entry = undefined;
    const found = catalog.search(document, target, self.view.category, std.mem.sliceTo(&self.view.search, 0), &entries);
    const current = editing.tapPart(self.primaryAction()).key_press;
    var buffer: [256]u8 = undefined;
    for (entries[0..found], 0..) |entry, index| {
        const text = catalog.label(entry, document, &buffer);
        const style: ui.CaptionStyle = .{ .color = t.text, .secondary = t.text, .size = 15, .id_extra = index, .layers = t.layers };
        const measured = ui.captionSize(text, style);
        const side = @max(11, (44 - measured.w) / 2);
        const tall = @max(9, (38 - measured.h) / 2);
        const chosen = switch (entry) {
            .key => |code| if (current) |key| key.tap_keycode == code else false,
            else => false,
        };
        const tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "key.editor.result.{d}", .{index});
        if (ui.richButton(@src(), text, style, .{
            .tag = tag,
            .id_extra = index,
            .background = true,
            .border = .all(if (chosen) 2 else 1),
            .color_border = .{ .color = if (chosen) t.accent else t.border },
            .color_fill = .{ .color = if (chosen) ui.mix(t.keycap, t.accent, 0.18) else t.keycap },
            .corners = .all(8),
            .padding = .{ .x = side, .y = tall, .w = side, .h = tall },
            .margin = .{ .w = 6, .h = 6 },
        })) add(self, target, entry);
    }
    if (found == 0) dvui.labelNoFmt(@src(), "Nothing matches", .{}, .{
        .font = ui.editorFont("Nothing matches", 13),
        .color_text = .{ .color = t.muted },
    });
}

/// Adds a search result to the tap or the hold.
fn add(self: *Context, target: catalog.Target, entry: catalog.Entry) void {
    const session = self.session;
    const held = target == .hold;
    switch (entry) {
        .key => |code| session.mutate(.{ .tap_usage = code }),
        .modifier => |bit| setModifier(self, if (held) .hold else .tap, @intCast(bit % 4), bit >= 4),
        .layer => |id| session.mutate(if (held) .{ .hold_layer = id } else .{ .one_shot_layer = id }),
        .media => |value| session.mutate(.{ .tap_media = value }),
        .mouse => |value| session.mutate(.{ .tap_mouse = value }),
        .callback, .signal => |id| session.mutate(if (held) .{ .hold_custom = id } else .{ .tap_custom = id }),
        .one_shot => session.mutate(.{ .tap_one_shot = .{} }),
    }
}

/// The one-shot's layer and modifiers.
fn oneShot(self: *Context, one: p.Hold, y: f32) void {
    sectionLabel(self, "One-shot", y + 12);
    const layers = self.model.document().layers;
    var names: [p.Limits.layers + 1][]const u8 = undefined;
    names[0] = "No layer";
    var selected: usize = 0;
    for (layers, 0..) |layer, index| {
        names[index + 1] = layer.name;
        if (one.layer_id == layer.id) selected = index + 1;
    }
    if (dvui.dropdown(@src(), names[0 .. layers.len + 1], .{ .choice = &selected }, .{}, .{
        .rect = .{ .x = margin + 70, .y = y + 4, .w = 150, .h = 34 },
        .tag = "key.editor.one_shot.layer",
        .font = ui.editorFont("Layer", 13),
    })) self.session.mutate(.{ .one_shot_layer = if (selected == 0) null else layers[selected - 1].id });
    modifierToggles(self, .one_shot, margin + 232, y + 2);
}

fn callbackNumber(self: *Context, title: []const u8, id: u8, comptime operation: []const u8, y: f32) void {
    sectionLabel(self, title, y + 12);
    var value = id;
    if (dvui.textEntryNumber(@src(), u8, .{ .value = &value }, .{
        .rect = .{ .x = margin + 170, .y = y + 4, .w = 90, .h = 34 },
        .tag = "key.editor." ++ operation,
        .padding = number_padding,
        .id_extra = std.hash.Wyhash.hash(0, operation),
    }).changed) self.session.mutate(@unionInit(editing.Operation, operation, value));
}

// Hold --------------------------------------------------------------------------

fn holdHeight(self: *const Context) f32 {
    const action = self.primaryAction();
    const autofire = if (action) |value| value == .tap_with_autofire else false;
    var height: f32 = if (autofire) 372 else 554;
    if (!autofire and editing.holdPart(action).custom != null) height += 46;
    return height;
}

fn drawHold(self: *Context, width: f32, height: f32) !void {
    const t = self.theme;
    const inner = width - 2 * margin;
    const action = self.primaryAction();
    const autofire = if (action) |value| value == .tap_with_autofire else false;
    var y: f32 = 66;
    if (autofire) {
        const note = dvui.box(@src(), .{}, .{
            .rect = .{ .x = margin, .y = y, .w = inner, .h = 64 },
            .background = true,
            .color_fill = .{ .color = t.control },
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        note.deinit();
        ui.label(t, "Autofire replaces the hold action.", .{ .x = margin + 14, .y = y + 12, .w = inner - 28, .h = 20 }, 14);
        ui.label(self.muted, "Turn it off to hold a modifier or a layer.", .{ .x = margin + 14, .y = y + 34, .w = inner - 28, .h = 18 }, 12);
        y += 78;
    } else {
        sectionLabel(self, "Modifier while held", y);
        modifierRow(self, .hold, y + 20);
        y += 72;
        sectionLabel(self, "Layer while held", y);
        try layerChips(self, .{ .x = margin - 2, .y = y + 20, .w = inner + 4, .h = 72 });
        y += 98;
        try holdCallback(self, y);
        y += 46;
        if (editing.holdPart(action).custom) |id| {
            callbackNumber(self, "Callback ID", id, "hold_custom", y);
            y += 46;
        }
        ui.divider(t, .{ .x = margin, .y = y, .w = inner, .h = 1 }, 0xd1);
        y += 12;
        timing(self, action, y, inner);
        y += 56;
    }
    autofireCard(self, action, .{ .x = margin, .y = y, .w = inner, .h = 124 });
    footer(self, .hold, width, height);
}

/// The layers a hold can switch to, as chips in their colors.
fn layerChips(self: *Context, bounds: dvui.Rect) !void {
    const t = self.theme;
    const layers = self.model.document().layers;
    const current = editing.holdPart(self.primaryAction()).layer_id;
    const chips = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .rect = bounds, .padding = .{}, .margin = .{} });
    defer chips.deinit();
    const arena = dvui.currentWindow().arena();
    for (0..layers.len + 1) |index| {
        const id: ?p.LayerId = if (index == 0) null else layers[index - 1].id;
        if (id != null and index - 1 == self.model.layer) continue;
        const chosen = std.meta.eql(id, current);
        const name = if (index == 0) "None" else layers[index - 1].name;
        const tag = if (index == 0) "key.editor.layer.none" else try std.fmt.allocPrint(arena, "key.editor.layer.{d}", .{index - 1});
        const font = ui.editorFont(name, 13);
        const badge: f32 = if (index == 0) 0 else 24;
        const w = font.textSize(name).w + 24 + badge;
        var widget: dvui.ButtonWidget = undefined;
        widget.init(@src(), .{}, .{
            .tag = tag,
            .id_extra = index,
            .min_size_content = .{ .w = w, .h = 30 },
            .max_size_content = .{ .w = w, .h = 30 },
            .background = true,
            .border = .all(1),
            .color_border = .{ .color = if (chosen) t.accent else t.border },
            .color_fill = .{ .color = if (chosen) ui.mix(t.control, t.accent, 0.22) else t.control },
            .corners = .all(15),
            .padding = .{},
            .margin = .{ .x = 2, .y = 2, .w = 4, .h = 4 },
        });
        widget.processEvents();
        widget.drawBackground();
        if (index != 0) {
            const color = ui.layerColor(t, index - 1);
            const dot = dvui.box(@src(), .{}, .{
                .id_extra = index,
                .rect = .{ .x = 10, .y = 7, .w = 16, .h = 16 },
                .background = true,
                .color_fill = .{ .color = color },
                .corners = .all(4),
                .padding = .{},
                .margin = .{},
            });
            dot.deinit();
            var number: [8]u8 = undefined;
            const digits = std.fmt.bufPrint(&number, "{d}", .{index - 1}) catch "";
            dvui.labelNoFmt(@src(), digits, .{ .align_x = 0.5 }, .{
                .id_extra = index,
                .rect = .{ .x = 10, .y = 7, .w = 16, .h = 16 },
                .font = ui.editorFont(digits, 10).withWeight(.bold),
                .color_text = .{ .color = ui.color(0xFFFFFF) },
                .padding = .{},
                .margin = .{},
                .gravity_y = 0.5,
            });
        }
        dvui.labelNoFmt(@src(), name, .{}, .{
            .id_extra = index,
            .rect = .{ .x = 12 + badge, .y = 6, .w = w - 12 - badge, .h = 18 },
            .font = font,
            .color_text = .{ .color = t.text },
            .padding = .{},
            .margin = .{},
            .gravity_y = 0.5,
        });
        const clicked = widget.clicked();
        widget.deinit();
        if (clicked and !chosen) self.session.mutate(.{ .hold_layer = id });
    }
}

/// A callback or companion signal sent while the key is held.
fn holdCallback(self: *Context, y: f32) !void {
    sectionLabel(self, "Callback while held", y + 12);
    const document = self.model.document();
    var entries: [48]catalog.Entry = undefined;
    var count = catalog.search(document, .hold, .callback, "", &entries);
    count += catalog.search(document, .hold, .signal, "", entries[count..]);
    const arena = dvui.currentWindow().arena();
    const names = try arena.alloc([]const u8, count + 1);
    names[0] = "None";
    const current = editing.holdPart(self.primaryAction()).custom;
    var selected: usize = 0;
    for (entries[0..count], 1..) |entry, index| {
        var buffer: [256]u8 = undefined;
        names[index] = try arena.dupe(u8, catalog.label(entry, document, &buffer));
        const id = switch (entry) {
            .callback, .signal => |value| value,
            else => null,
        };
        if (id != null and id == current) selected = index;
    }
    if (dvui.dropdown(@src(), names, .{ .choice = &selected }, .{}, .{
        .rect = .{ .x = margin + 150, .y = y + 4, .w = 224, .h = 34 },
        .tag = "key.editor.hold.callback",
        .font = ui.editorFont("Callback", 13),
    })) {
        const id: ?u8 = if (selected == 0) null else switch (entries[selected - 1]) {
            .callback, .signal => |value| value,
            else => null,
        };
        self.session.mutate(.{ .hold_custom = id });
    }
}

/// The tapping term and retro tapping of a key that taps and holds.
fn timing(self: *Context, action: ?p.Action, y: f32, inner: f32) void {
    const value = action orelse return;
    if (value != .tap_hold) {
        ui.label(self.muted, "Hold timing applies once the key also taps.", .{ .x = margin, .y = y + 14, .w = inner, .h = 18 }, 12);
        return;
    }
    sectionLabel(self, "Counts as held after", y);
    var term = value.tap_hold.tapping_term.ms;
    if (dvui.textEntryNumber(@src(), u16, .{ .value = &term, .min = 1, .max = 10000 }, .{
        .rect = .{ .x = margin, .y = y + 18, .w = 86, .h = 34 },
        .tag = "key.editor.tapping_term",
        .padding = number_padding,
    }).changed) self.session.mutate(.{ .tapping_term = term });
    ui.label(self.muted, "ms", .{ .x = margin + 92, .y = y + 26, .w = 30, .h = 18 }, 13);
    var retro = value.tap_hold.retro_tapping;
    if (dvui.checkbox(@src(), &retro, "Send the tap if released alone", .{
        .rect = .{ .x = margin + 130, .y = y + 22, .w = inner - 130, .h = 26 },
        .tag = "key.editor.retro",
        .font = ui.editorFont("Send", 13),
        .color_text = .{ .color = self.theme.text },
    })) self.session.mutate(.{ .retro_tapping = retro });
}

/// Autofire in place of a hold: the tap repeats while the key is held.
fn autofireCard(self: *Context, action: ?p.Action, bounds: dvui.Rect) void {
    const t = self.theme;
    const on = if (action) |value| value == .tap_with_autofire else false;
    const possible = !editing.tapEmpty(editing.tapPart(action));
    const card = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = t.bg },
        .color_border = .{ .color = if (on) t.accent else t.border },
        .border = .all(1),
        .corners = .all(12),
        .padding = .{},
        .margin = .{},
    });
    card.deinit();
    var checked = on;
    if (possible) {
        if (dvui.checkbox(@src(), &checked, "", .{
            .rect = .{ .x = bounds.x + 12, .y = bounds.y + 12, .w = 26, .h = 26 },
            .tag = "key.editor.autofire",
        })) self.session.mutate(.{ .mode = if (checked) .repeat else .tap });
    }
    dvui.icon(@src(), "autofire", ui.control_icons.autofire, .{}, .{
        .rect = .{ .x = bounds.x + 42, .y = bounds.y + 16, .w = 17, .h = 17 },
        .color_text = .{ .color = if (on) t.accent else t.muted },
        .padding = .{},
        .margin = .{},
    });
    ui.label(if (possible) t else self.muted, "Autofire", .{ .x = bounds.x + 66, .y = bounds.y + 14, .w = 120, .h = 22 }, 15);
    var note = ui.options(self.muted, .{ .x = bounds.x + 180, .y = bounds.y + 17, .w = bounds.w - 194, .h = 18 }, 12);
    note.padding = .{};
    note.background = false;
    note.color_text = .{ .color = t.muted };
    dvui.labelNoFmt(@src(), if (possible) "instead of a hold action" else "needs a tap action", .{ .align_x = 1 }, note);
    ui.label(self.muted, "While held, the tap repeats.", .{ .x = bounds.x + 42, .y = bounds.y + 42, .w = bounds.w - 56, .h = 18 }, 13);
    const fields = [_]struct { title: []const u8, x: f32 }{ .{ .title = "Start after", .x = 42 }, .{ .title = "Repeat every", .x = 182 } };
    var delay: u16 = 180;
    var interval: u16 = 50;
    if (on) {
        delay = action.?.tap_with_autofire.initial_delay.ms;
        interval = action.?.tap_with_autofire.repeat_interval.ms;
    }
    for (fields, 0..) |field, index| {
        const x = bounds.x + field.x;
        ui.label(self.muted, field.title, .{ .x = x, .y = bounds.y + 66, .w = 120, .h = 16 }, 12);
        const value = if (index == 0) &delay else &interval;
        if (on) {
            if (dvui.textEntryNumber(@src(), u16, .{ .value = value, .min = 1, .max = 10000 }, .{
                .id_extra = index,
                .rect = .{ .x = x, .y = bounds.y + 82, .w = 86, .h = 34 },
                .padding = number_padding,
                .tag = if (index == 0) "key.editor.initial_delay" else "key.editor.repeat_interval",
            }).changed) self.session.mutate(if (index == 0) .{ .initial_delay = value.* } else .{ .repeat_interval = value.* });
        } else {
            var buffer: [16]u8 = undefined;
            ui.label(self.muted, std.fmt.bufPrint(&buffer, "{d}", .{value.*}) catch "", .{ .x = x + 10, .y = bounds.y + 90, .w = 70, .h = 20 }, 14);
        }
        ui.label(self.muted, "ms", .{ .x = x + 92, .y = bounds.y + 92, .w = 30, .h = 18 }, 13);
    }
}

// Modifiers ---------------------------------------------------------------------

/// Bits 0–3 of a modifier set, in the host's order: ⌃⌥⇧⌘ on macOS.
const host_order: [4]u3 = switch (labels.running_host) {
    .macos => .{ 0, 2, 1, 3 },
    .windows, .linux => .{ 0, 1, 2, 3 },
};

fn isOn(self: *const Context, target: editing.ModifierTarget, bit: u3) bool {
    return self.session.modifierState(target, bit) != .off or self.session.modifierState(target, bit + 4) != .off;
}

fn clearBit(self: *Context, target: editing.ModifierTarget, bit: u3) void {
    if (self.session.modifierState(target, bit) == .mixed) self.session.toggleModifier(target, bit);
    if (self.session.modifierState(target, bit) == .on) self.session.toggleModifier(target, bit);
}

fn setModifier(self: *Context, target: editing.ModifierTarget, bit: u3, right: bool) void {
    const chosen = if (right) bit + 4 else bit;
    if (self.session.modifierState(target, chosen) != .on) self.session.toggleModifier(target, chosen);
}

/// Which side modifiers of `target` are on; new ones go to that side.
fn rightSide(self: *const Context, target: editing.ModifierTarget, part: usize) bool {
    var left = false;
    var right = false;
    for (0..4) |bit| {
        left = left or self.session.modifierState(target, @intCast(bit)) != .off;
        right = right or self.session.modifierState(target, @intCast(bit + 4)) != .off;
    }
    return if (left or right) right and !left else self.view.right[part];
}

/// Four modifier toggles and the Left / Right choice.
fn modifierRow(self: *Context, target: editing.ModifierTarget, y: f32) void {
    modifierToggles(self, target, margin, y);
    const part: usize = if (target == .hold) 1 else 0;
    const right = rightSide(self, target, part);
    const t = self.theme;
    const track: dvui.Rect = .{ .x = margin + 4 * 48 + 8, .y = y, .w = 128, .h = 38 };
    const box = dvui.box(@src(), .{}, .{
        .id_extra = part,
        .rect = track,
        .background = true,
        .color_fill = .{ .color = t.bg },
        .color_border = .{ .color = t.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
    inline for (.{ "Left", "Right" }, 0..) |side, index| {
        const chosen = right == (index == 1);
        const tag = if (target == .hold) "key.editor.hold.side." ++ side else "key.editor.tap.side." ++ side;
        var font = ui.editorFont(side, 13);
        if (chosen) font = font.withWeight(.bold);
        if (dvui.button(@src(), side, .{}, .{
            .id_extra = part * 2 + index,
            .tag = tag,
            .rect = .{ .x = track.x + 3 + @as(f32, index) * 61, .y = y + 3, .w = 61, .h = 32 },
            .font = font,
            .background = chosen,
            .color_fill = .{ .color = ui.mix(t.control, t.text, 0.1) },
            .color_text = .{ .color = if (chosen) t.text else t.muted },
            .corners = .all(6),
            .padding = .{},
            .margin = .{},
        }) and !chosen) {
            self.view.right[part] = index == 1;
            // Moves the modifiers that are on to the chosen side.
            for (0..4) |bit| {
                const base: u3 = @intCast(bit);
                if (!isOn(self, target, base)) continue;
                clearBit(self, target, base);
                clearBit(self, target, base + 4);
                setModifier(self, target, base, index == 1);
            }
        }
    }
}

fn modifierToggles(self: *Context, target: editing.ModifierTarget, x: f32, y: f32) void {
    const t = self.theme;
    const part: usize = @backingInt(target);
    const right = rightSide(self, target, if (target == .hold) 1 else 0);
    const arena = dvui.currentWindow().arena();
    for (host_order, 0..) |bit, order| {
        const on = isOn(self, target, bit);
        const tag = std.fmt.allocPrint(arena, "key.editor.modifier.{s}.{d}", .{ @tagName(target), bit }) catch "key.editor.modifier";
        var symbol: [32]u8 = undefined;
        const caption = labels.keycapModifiers(labels.running_host, @as(u8, 1) << bit, &symbol);
        const tint = if (on) ui.color(0xFFFFFF) else t.text;
        if (ui.richButton(@src(), caption, .{ .color = tint, .secondary = tint, .size = 16, .id_extra = part * 8 + order }, .{
            .tag = tag,
            .id_extra = part * 8 + order,
            .rect = .{ .x = x + @as(f32, @floatFromInt(order)) * 48, .y = y, .w = 42, .h = 38 },
            .background = true,
            .border = .all(1),
            .color_border = .{ .color = if (on) t.accent else t.border },
            .color_fill = .{ .color = if (on) t.accent else t.control },
            .corners = .all(8),
            .padding = .{},
            .margin = .{},
        })) {
            if (on) {
                clearBit(self, target, bit);
                clearBit(self, target, bit + 4);
            } else setModifier(self, target, bit, right);
        }
    }
}

test "typed characters and shortcut keys map to the OS keyboard's usages" {
    const t = std.testing;
    const Us = struct {
        pub fn keyToText(_: *@This(), input: @import("zkeymap").KeyCodeFire) @import("zkeymap").TextResult {
            var result: @import("zkeymap").TextResult = .{};
            if (input.tap_keycode >= 4 and input.tap_keycode <= 29) {
                result.data[0] = (if (input.tap_modifiers.left_shift) @as(u8, 'A') else 'a') + input.tap_keycode - 4;
                result.len = 1;
            }
            if (input.tap_keycode == 30) {
                result.data[0] = if (input.tap_modifiers.left_shift) '!' else '1';
                result.len = 1;
            }
            return result;
        }
    };
    var translator: Us = .{};
    var host = try desktop.host_palette.Cache.init(t.allocator, .macos, "fixture", 1, &translator);
    defer host.deinit();
    try t.expectEqual(Found{ .code = 4 }, find(&host, "a", true).?);
    try t.expectEqual(Found{ .code = 4, .shift = true }, find(&host, "A", true).?);
    try t.expectEqual(Found{ .code = 30, .shift = true }, find(&host, "!", true).?);
    try t.expectEqual(Found{ .code = 6 }, find(&host, &.{character(.c).?}, false).?);
    try t.expectEqual(@as(u8, 40), fixedUsage(.enter).?.code);
    try t.expectEqual(@as(u8, 69), fixedUsage(.f12).?.code);
    try t.expectEqual(@as(?Found, null), fixedUsage(.a));
}
