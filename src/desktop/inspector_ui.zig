//! The inspector edits a session; only its fixed Apply control commits a snapshot.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const p = @import("project");
const ui = @import("editor-ui");
const labels = desktop.labels;
const catalog = desktop.action_catalog;
const editing = desktop.inspector_session;
const forms = desktop.action_form;
const fonts = @import("editor-fonts");
const Symbol = labels.keycap_symbols.Symbol;

pub const State = struct {
    target: catalog.Target = .tap,
    category: catalog.Category = .all,
    advanced: bool = false,
    conversion: bool = false,
    removal_summary: []const u8 = "",
};

pub const Intent = desktop.inspector_action.Intent;
pub const Action = desktop.inspector_action.Action;

pub const View = struct {
    state: State = .{},
    search: [128]u8 = @splat(0),
    diagnostic: [128]u8 = @splat(0),
    pending: bool = false,
    close_requested: bool = false,
    drag_chord: ?desktop.assignment.Chord = null,
};

/// Borrowed copies exist only during one frame. Their arenas/documents are never
/// allocated, freed or committed here; mutation touches the shared owned drafts.
const Context = struct {
    model: desktop.model.Model,
    edit_session: editing.Session,
    state: State,
    search: [128]u8,
    diagnostic: [128]u8,
    pending: bool,
    close_requested: bool,
    theme: ui.Theme,
    drag_chord: ?desktop.assignment.Chord,
    intent: Intent = .none,

    /// Keeps the first intent requested during the frame.
    fn choose(self: *Context, intent: Intent) void {
        if (self.intent == .none) self.intent = intent;
    }

    fn keycap(self: *Context, value: ?p.Action, buffer: []u8) []const u8 {
        return labels.keycap(value, self.model.document(), buffer);
    }

    fn report(self: *Context, failure: anyerror) void {
        @memset(&self.diagnostic, 0);
        const name = @errorName(failure);
        const count = @min(name.len, self.diagnostic.len - 1);
        @memcpy(self.diagnostic[0..count], name[0..count]);
    }

    /// The selection's primary action, or the inherited action when unassigned.
    fn primaryAction(self: *Context) ?p.Action {
        const session = &self.edit_session;
        return session.first() orelse session.resolved[session.primary];
    }

    /// Accepts a host-palette chord dropped on the Tap or Hold header. A hold
    /// accepts only modifier usages.
    fn chordDrop(self: *Context, data: *dvui.WidgetData, held: bool) void {
        const chord = self.drag_chord orelse return;
        if (!dvui.dragName("key_chord")) return;
        for (dvui.events()) |*event| {
            if (!dvui.eventMatch(event, .{ .id = data.id, .r = data.borderRectScale().r, .drag_name = "key_chord" })) continue;
            if (event.evt != .mouse) continue;
            const mouse = event.evt.mouse;
            if (mouse.action == .position) data.focusBorder();
            if (mouse.action == .release and mouse.button == .left) {
                event.handle(@src(), data);
                dvui.dragEnd();
                self.drag_chord = null;
                if (!held) {
                    self.edit_session.mutate(.{ .tap_key = chord });
                } else if (chord.tap_keycode < 224 or chord.tap_keycode > 231) {
                    self.report(error.HoldRequiresModifier);
                    return;
                } else {
                    self.edit_session.toggleModifier(.hold, @intCast(chord.tap_keycode - 224));
                }
            }
        }
    }
};

pub fn draw(session: *editing.Session, model: *const desktop.model.Model, view: *View, theme: ui.Theme, light: bool) !?Action {
    if (try session.stale(model)) return error.StaleSession;
    var context: Context = .{
        .model = model.*,
        .edit_session = session.*,
        .state = view.state,
        .search = view.search,
        .diagnostic = view.diagnostic,
        .pending = view.pending,
        .close_requested = view.close_requested,
        .theme = ui.Theme.get(light),
        .drag_chord = view.drag_chord,
    };
    defer {
        view.state = context.state;
        view.search = context.search;
        view.diagnostic = context.diagnostic;
        view.pending = context.pending;
        view.close_requested = context.close_requested;
        view.drag_chord = context.drag_chord;
    }
    try drawPanel(&context, theme);
    return if (context.intent == .none) null else try Action.capture(session, model, context.intent);
}

fn caption(text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{ .expand = .horizontal, .font = fonts.font(text, 13), .id_extra = std.hash.Wyhash.hash(0, text) });
}

/// Whether the selected keys disagree on one field of their action forms.
fn fieldMixed(self: *Context, comptime part: []const u8, comptime field: []const u8) bool {
    const session = &self.edit_session;
    const primary = forms.Draft.from(self.primaryAction());
    const value = @field(@field(primary, part), field);
    for (session.selected, session.drafts, session.resolved) |selected, action, resolved| {
        if (!selected) continue;
        const draft = forms.Draft.from(action orelse resolved);
        if (!std.meta.eql(value, @field(@field(draft, part), field))) return true;
    }
    return false;
}

/// One assigned component with a button that removes it.
fn chip(self: *Context, text: []const u8, tag: []const u8, operation: editing.Operation) void {
    const id = std.hash.Wyhash.hash(0, tag);
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = id, .padding = .all(2) });
    defer row.deinit();
    ui.richLabel(text, .{
        .color = self.theme.text,
        .secondary = self.theme.text,
        .size = 16,
        .align_x = 0,
        .id_extra = id,
    }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = self.theme.panel },
        .padding = .all(5),
        .corners = .all(5),
    });
    if (dvui.button(@src(), "×", .{}, .{ .tag = tag, .min_size_content = .{ .w = 28, .h = 28 }, .id_extra = id })) {
        self.edit_session.mutate(operation);
    }
}

fn modifierButtons(self: *Context, target: editing.ModifierTarget) void {
    const names = switch (labels.running_host) {
        .macos => [_][]const u8{
            "L " ++ Symbol.literal(.control),
            "L " ++ Symbol.literal(.shift),
            "L " ++ Symbol.literal(.option),
            "L " ++ Symbol.literal(.command),
            "R " ++ Symbol.literal(.control),
            "R " ++ Symbol.literal(.shift),
            "R " ++ Symbol.literal(.option),
            "R " ++ Symbol.literal(.command),
        },
        .windows => [_][]const u8{ "L Ctrl", "L Shift", "L Alt", "L Win", "R Ctrl", "R Shift", "R Alt", "R Win" },
        .linux => [_][]const u8{ "L Ctrl", "L Shift", "L Alt", "L Super", "R Ctrl", "R Shift", "R Alt", "R Super" },
    };
    const arena = dvui.currentWindow().arena();
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{}, .padding = .{} });
    defer row.deinit();
    inline for (0..8) |bit| {
        const state = self.edit_session.modifierState(target, bit);
        const text = if (state == .mixed) std.fmt.allocPrint(arena, "− {s}", .{names[bit]}) catch unreachable else names[bit];
        const tag = std.fmt.allocPrint(arena, "inspector.modifier.{s}.{d}", .{ @tagName(target), bit }) catch unreachable;
        const tint = if (state == .on) ui.color(0xFFFFFF) else self.theme.text;
        if (ui.richButton(@src(), text, .{ .color = tint, .secondary = tint, .size = 15, .id_extra = bit }, .{
            .tag = tag,
            .id_extra = bit,
            .expand = .horizontal,
            .padding = .all(4),
            .margin = .all(1),
            .color_fill = .{ .color = if (state == .on) self.theme.accent else self.theme.control },
        })) self.edit_session.toggleModifier(target, bit);
    }
}

/// The Tap or Hold card: a drop target header, component chips and modifiers.
fn card(self: *Context, held: bool) void {
    const session = &self.edit_session;
    const target: catalog.Target = if (held) .hold else .tap;
    const box = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .id_extra = if (held) 2 else 1,
        .background = true,
        .color_fill = .{ .color = self.theme.control },
        .border = .all(1),
        .corners = .all(9),
        .padding = .all(7),
        .margin = .{ .h = 8 },
    });
    defer box.deinit();
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        var data: dvui.WidgetData = undefined;
        const header_tag = if (held) "inspector.hold" else "inspector.tap";
        const title = if (held) "Hold" else "Tap";
        // The title is the drop target for host-palette chords and selects
        // which part the search adds to; the chosen part is outlined.
        const targeted = self.state.target == target;
        if (ui.richButton(@src(), title, .{
            .color = self.theme.text,
            .secondary = self.theme.text,
            .size = 17,
            .align_x = 0,
            .id_extra = if (held) 2 else 1,
        }, .{
            .tag = header_tag,
            .data_out = &data,
            .expand = .horizontal,
            .background = targeted,
            .color_fill = .{ .color = self.theme.panel },
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        })) {
            self.state.target = target;
        }
        self.chordDrop(&data, held);
        const link: dvui.Options = .{
            .background = false,
            .font = fonts.font("Clear", 13),
            .color_text = .{ .color = self.theme.muted },
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        };
        var clear = link;
        clear.tag = if (held) "inspector.clear.hold" else "inspector.clear.tap";
        if (dvui.button(@src(), "Clear", .{}, clear)) {
            session.mutate(if (held) .clear_hold else .clear_tap);
        }
        var add_link = link;
        add_link.tag = if (held) "inspector.add.hold" else "inspector.add.tap";
        if (dvui.button(@src(), "+ Add", .{}, add_link)) {
            self.state.target = target;
        }
    }
    const draft = mergedDraft(self);
    if (held) holdChips(self, draft.hold) else tapChips(self, draft.tap);
    modifierButtons(self, if (held) .hold else .tap);
}

/// The primary draft with every component populated on any selected key, so
/// each populated schema field is displayed even when the primary key lacks it.
fn mergedDraft(self: *Context) forms.Draft {
    const session = &self.edit_session;
    var draft = forms.Draft.from(self.primaryAction());
    for (session.selected, session.drafts, session.resolved) |selected, action, resolved| {
        if (!selected) continue;
        const other = forms.Draft.from(action orelse resolved);
        inline for (.{ "key_press", "one_shot", "media_key", "mouse_action", "custom" }) |field| {
            if (@field(draft.tap, field) == null) @field(draft.tap, field) = @field(other.tap, field);
        }
        inline for (.{ "layer_id", "custom" }) |field| {
            if (@field(draft.hold, field) == null) @field(draft.hold, field) = @field(other.hold, field);
        }
        draft.hold.hold_modifiers = @bitCast(draft.hold.hold_modifiers.toByte() | other.hold.hold_modifiers.toByte());
    }
    return draft;
}

fn holdChips(self: *Context, value: anytype) void {
    var buffer: [512]u8 = undefined;
    const document = self.model.document();
    const mods = value.hold_modifiers.toByte();
    if (mods != 0) {
        const text = if (fieldMixed(self, "hold", "hold_modifiers"))
            "Mixed modifiers"
        else
            labels.hostModifierNames(labels.runningHost(), mods, &buffer);
        chip(self, text, "inspector.remove.hold.modifiers", .{ .hold_modifiers = .{} });
    }
    if (value.layer_id) |id| {
        const text = if (fieldMixed(self, "hold", "layer_id")) "Mixed layers" else catalog.label(.{ .layer = id }, document, &buffer);
        chip(self, text, "inspector.remove.hold.layer", .{ .hold_layer = null });
    }
    if (value.custom) |id| {
        const text = if (fieldMixed(self, "hold", "custom")) "Mixed callbacks" else labels.signal(id, &buffer);
        chip(self, text, "inspector.remove.hold.callback", .{ .hold_custom = null });
    }
    if (mods == 0 and value.layer_id == null and value.custom == null) caption("No hold");
}

fn tapChips(self: *Context, value: anytype) void {
    var buffer: [512]u8 = undefined;
    if (value.key_press) |key| {
        const text = if (fieldMixed(self, "tap", "key_press"))
            "Mixed key / chord"
        else
            labels.tap(.{ .key_press = key }, &buffer);
        chip(self, text, "inspector.remove.tap.key", .{ .tap_key = null });
    }
    if (value.one_shot) |one| {
        const text = if (fieldMixed(self, "tap", "one_shot"))
            "Mixed one-shot"
        else
            std.fmt.allocPrint(
                dvui.currentWindow().arena(),
                "One-shot · {s}",
                .{labels.hold(one, self.model.document(), &buffer)},
            ) catch unreachable;
        chip(self, text, "inspector.remove.tap.one_shot", .{ .tap_one_shot = null });
    }
    if (value.media_key) |media| {
        const text = if (fieldMixed(self, "tap", "media_key")) "Mixed media" else @tagName(media);
        chip(self, text, "inspector.remove.tap.media", .{ .tap_media = null });
    }
    if (value.mouse_action) |mouse| {
        const text = if (fieldMixed(self, "tap", "mouse_action")) "Mixed mouse" else @tagName(mouse);
        chip(self, text, "inspector.remove.tap.mouse", .{ .tap_mouse = null });
    }
    if (value.custom) |id| {
        const text = if (fieldMixed(self, "tap", "custom")) "Mixed callbacks" else labels.signal(id, &buffer);
        chip(self, text, "inspector.remove.tap.callback", .{ .tap_custom = null });
    }
    const empty = value.key_press == null and value.one_shot == null and value.media_key == null and
        value.mouse_action == null and value.custom == null;
    if (empty) caption("No tap");
}

fn number(self: *Context, comptime T: type, title: []const u8, value: *T, comptime operation: []const u8) void {
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = std.hash.Wyhash.hash(0, title) });
    defer row.deinit();
    dvui.labelNoFmt(@src(), title, .{}, .{ .expand = .horizontal });
    if (dvui.textEntryNumber(@src(), T, .{ .value = value }, .{ .min_size_content = .{ .w = 100, .h = 30 } }).changed) {
        self.edit_session.mutate(@unionInit(editing.Operation, operation, value.*));
    }
}

/// Adds a search result to the current target.
fn add(self: *Context, entry: catalog.Entry) void {
    const session = &self.edit_session;
    const held = self.state.target == .hold;
    switch (entry) {
        .key => |code| session.mutate(.{ .tap_usage = code }),
        .modifier => |bit| session.toggleModifier(if (held) .hold else .tap, @intCast(bit)),
        .layer => |id| session.mutate(.{ .hold_layer = id }),
        .media => |value| session.mutate(.{ .tap_media = value }),
        .mouse => |value| session.mutate(.{ .tap_mouse = value }),
        .callback => |id| session.mutate(if (held) .{ .hold_custom = id } else .{ .tap_custom = id }),
        .signal => |id| session.mutate(if (held) .{ .hold_custom = id } else .{ .tap_custom = id }),
        .one_shot => session.mutate(.{ .tap_one_shot = .{} }),
    }
}

fn drawPanel(self: *Context, t: ui.Theme) !void {
    if (try self.edit_session.stale(&self.model)) return error.StaleSession;
    const box = ui.panel(t, .inspector);
    defer box.deinit();
    const session = &self.edit_session;
    const before = try dvui.currentWindow().arena().dupe(?p.Action, session.drafts);
    const count = try drawHeader(self, t);
    {
        const height: f32 = if (self.pending or self.close_requested) 589 else 653;
        const area = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 14, .y = 175, .w = 412, .h = height }, .padding = .all(4) });
        defer area.deinit();
        try drawEditor(self);
    }
    for (before, session.drafts) |old, staged| if (!std.meta.eql(old, staged)) {
        self.diagnostic = @splat(0);
        break;
    };
    for (session.selected, session.originals, session.drafts) |selected, original, staged| {
        if (!selected or original == null or staged == null) continue;
        if (original.? == .tap_with_autofire and staged.? != .tap_with_autofire) {
            self.state.conversion = true;
            self.state.removal_summary = "Mode change removes Repeat delay and interval";
        }
    }
    var valid = true;
    session.validate(&self.model) catch |err| {
        valid = false;
        self.report(err);
    };
    drawPrompt(self, t);
    try drawFooter(self, t, count, valid);
}

const Description = struct { tap: []const u8, hold: []const u8 };

/// Spells out what a key does when tapped and when held.
fn describe(value: ?p.Action, document: p.Document, tap_buffer: []u8, hold_buffer: []u8) Description {
    const action = value orelse return .{ .tap = "Inherited", .hold = "" };
    return switch (action) {
        .none => .{ .tap = "Does nothing", .hold = "" },
        .tap_only => |tap| .{ .tap = labels.tap(tap, tap_buffer), .hold = "" },
        .tap_with_autofire => |autofire| .{ .tap = labels.tap(autofire.tap, tap_buffer), .hold = "Repeats" },
        .tap_hold => |both| .{ .tap = labels.tap(both.tap, tap_buffer), .hold = labels.hold(both.hold, document, hold_buffer) },
        .hold_only => |hold| .{ .tap = "Hold only", .hold = labels.hold(hold, document, hold_buffer) },
    };
}

/// The keycap as the canvas draws it, on the edited layer's color.
fn drawPreview(self: *Context, t: ui.Theme, text: []const u8) void {
    const bounds: dvui.Rect = .{ .x = 18, .y = 60, .w = 80, .h = 72 };
    const box = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = t.keycap },
        .color_border = .{ .color = ui.layerColor(t, self.model.layer) },
        .border = .all(2),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "inspector.preview",
    });
    box.deinit();
    ui.caption(text, .{ .x = bounds.x + 7, .y = bounds.y + 7, .w = bounds.w - 14, .h = bounds.h - 14 }, .{
        .color = t.text,
        .secondary = t.muted,
        .size = 26,
        .id_extra = 3,
        .layers = t.layers,
    });
}

/// Title, clipboard buttons, keycap preview and assignment status. Returns the
/// number of selected keys.
fn drawHeader(self: *Context, t: ui.Theme) !usize {
    const session = &self.edit_session;
    const arena = dvui.currentWindow().arena();
    const document = self.model.document();
    ui.label(t, "Key inspector", .{ .x = 20, .y = 20, .w = 225, .h = 26 }, 19);
    if (ui.iconButton(t, ui.control_icons.copy, "", "edit.copy", .{ .x = 344, .y = 12, .w = 36, .h = 32 }, false)) self.choose(.copy);
    if (ui.iconButton(t, ui.control_icons.paste, "", "edit.paste", .{ .x = 386, .y = 12, .w = 36, .h = 32 }, false)) self.choose(.paste);
    var buffer: [512]u8 = undefined;
    drawPreview(self, t, self.keycap(self.primaryAction(), &buffer));
    var count: usize = 0;
    for (session.selected) |selected| {
        if (selected) count += 1;
    }
    // The keycap draws symbols; the description beside it spells them out.
    var tap_buffer: [512]u8 = undefined;
    var hold_buffer: [512]u8 = undefined;
    const described = describe(self.primaryAction(), document, &tap_buffer, &hold_buffer);
    ui.caption(described.tap, .{ .x = 111, .y = 62, .w = 310, .h = 24 }, .{
        .color = t.text,
        .secondary = t.text,
        .size = 19,
        .align_x = 0,
        .id_extra = 1,
    });
    if (described.hold.len != 0) {
        const hold_text = try std.fmt.allocPrint(arena, "Hold: {s}", .{described.hold});
        ui.caption(hold_text, .{ .x = 111, .y = 87, .w = 310, .h = 20 }, .{
            .color = t.muted,
            .secondary = t.muted,
            .size = 16,
            .align_x = 0,
            .id_extra = 2,
        });
    }
    const selection = try std.fmt.allocPrint(arena, "{s} · {s} · {d} selected", .{
        document.key_ids[self.model.primary],
        document.layers[self.model.layer].name,
        count,
    });
    var muted = t;
    muted.text = t.muted;
    ui.label(muted, selection, .{ .x = 111, .y = 110, .w = 310, .h = 20 }, 12);
    var mixed = false;
    for (session.selected, session.drafts) |selected, action| {
        if (selected and !std.meta.eql(action, session.first())) mixed = true;
    }
    const stored = session.first();
    const status = if (mixed)
        "Mixed assignments"
    else if (stored == null)
        if (session.source_layers[session.primary]) |id|
            try std.fmt.allocPrint(arena, "Inherited · source layer {d}", .{id})
        else
            "Inherited · no lower assignment"
    else if (stored.? == .none)
        "Unassigned · do nothing"
    else
        "Custom assignment";
    ui.label(t, status, .{ .x = 18, .y = 141, .w = 405, .h = 22 }, 13);
    return count;
}

/// The scrolling editor: mode, Tap and Hold cards, timing, advanced fields and search.
fn drawEditor(self: *Context) !void {
    const draft = forms.Draft.from(self.primaryAction());
    drawModeSelector(self, draft);
    card(self, false);
    card(self, true);
    if (draft.mode == 4) {
        var value = draft.term;
        number(self, u16, "Tapping term (ms)", &value, "tapping_term");
    }
    if (draft.mode == 5) {
        var initial = draft.initial;
        var interval = draft.repeat;
        number(self, u16, "Initial delay (ms)", &initial, "initial_delay");
        number(self, u16, "Repeat interval (ms)", &interval, "repeat_interval");
    }
    const advanced_label = if (self.state.advanced) "Advanced -" else "Advanced +";
    if (dvui.button(@src(), advanced_label, .{}, .{ .expand = .horizontal, .tag = "inspector.advanced" })) {
        self.state.advanced = !self.state.advanced;
    }
    if (self.state.advanced) drawAdvanced(self, draft);
    try drawSearch(self);
}

fn drawModeSelector(self: *Context, draft: forms.Draft) void {
    const session = &self.edit_session;
    const unassigned = session.first() == null or session.first().? == .none;
    var mode: usize = if (unassigned) 0 else switch (draft.mode) {
        2 => 1,
        3 => 2,
        4 => 3,
        5 => 4,
        else => 0,
    };
    const modes: []const []const u8 = &.{ "Add an action…", "Tap", "Hold", "Tap / Hold", "Repeat" };
    mutedCaption(self, "Behaviour");
    if (!dvui.dropdown(@src(), modes, .{ .choice = &mode }, .{}, .{
        .expand = .horizontal,
        .tag = "inspector.mode",
        .margin = .{ .h = 8 },
    })) return;
    if (mode == 0) return;
    // Warn when the new mode drops components of any selected key.
    var removes = false;
    for (session.selected, 0..) |selected, index| if (selected) {
        const action = session.drafts[index] orelse session.resolved[index];
        const drops_hold = (mode == 1 or mode == 4) and !editing.holdEmpty(editing.holdPart(action));
        const drops_tap = mode == 2 and !editing.tapEmpty(editing.tapPart(action));
        removes = removes or drops_hold or drops_tap;
    };
    self.state.conversion = removes;
    self.state.removal_summary = if (mode == 2) "Mode change removes Tap components" else "Mode change removes Hold components";
    session.mutate(.{ .mode = @fromBackingInt(@intCast(mode - 1)) });
}

/// Raw HID usage, dead keys, retro tapping, one-shot details and callback IDs.
fn drawAdvanced(self: *Context, draft: forms.Draft) void {
    const session = &self.edit_session;
    if (draft.tap.key_press) |previous| {
        var code = previous.tap_keycode;
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        caption("HID usage");
        if (dvui.textEntryNumber(@src(), u8, .{ .value = &code }, .{ .min_size_content = .{ .w = 90, .h = 30 } }).changed) {
            session.mutate(.{ .tap_usage = code });
        }
        row.deinit();
        var dead = previous.dead;
        if (dvui.checkbox(@src(), &dead, "Dead-key chord", .{})) session.mutate(.{ .tap_dead = dead });
    }
    if (draft.mode == 4) {
        var retro = draft.retro;
        if (dvui.checkbox(@src(), &retro, "Retro tapping", .{})) session.mutate(.{ .retro_tapping = retro });
    }
    if (draft.tap.one_shot) |previous| drawOneShot(self, previous);
    caption("Callback IDs come from attached sources. Reserved signals remain available in search.");
    if (draft.tap.custom) |id| {
        var value = id;
        number(self, u8, "Tap callback / signal ID", &value, "tap_custom");
    }
    if (draft.hold.custom) |id| {
        var value = id;
        number(self, u8, "Hold callback ID", &value, "hold_custom");
    }
}

fn drawOneShot(self: *Context, previous: anytype) void {
    const session = &self.edit_session;
    const layers = self.model.document().layers;
    caption("One-shot modifiers");
    modifierButtons(self, .one_shot);
    var names: [16][]const u8 = undefined;
    names[0] = "No one-shot layer";
    var selected: usize = 0;
    for (layers, 0..) |layer, index| {
        names[index + 1] = layer.name;
        if (previous.layer_id == layer.id) selected = index + 1;
    }
    if (dvui.dropdown(@src(), names[0 .. layers.len + 1], .{ .choice = &selected }, .{}, .{ .expand = .horizontal })) {
        session.mutate(.{ .one_shot_layer = if (selected == 0) null else layers[selected - 1].id });
    }
    var custom = previous.custom != null;
    if (dvui.checkbox(@src(), &custom, "One-shot callback", .{})) session.mutate(.{ .one_shot_custom = if (custom) 1 else null });
    if (previous.custom) |id| {
        var value = id;
        number(self, u8, "One-shot callback ID", &value, "one_shot_custom");
    }
}

fn mutedCaption(self: *Context, text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{
        .expand = .horizontal,
        .font = fonts.font(text, 13),
        .color_text = .{ .color = self.theme.muted },
        .id_extra = std.hash.Wyhash.hash(1, text),
        .padding = .{ .x = 2, .y = 6, .w = 2, .h = 4 },
    });
}

/// Search categories as wrapping chips; the chosen one is raised.
fn drawCategories(self: *Context) !void {
    const categories = [_][]const u8{ "All", "Keys", "Modifiers", "Layers", "Media", "Mouse", "Callbacks", "One-shot", "Signals" };
    const chips = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .tag = "inspector.category", .margin = .{ .y = 6, .h = 6 } });
    defer chips.deinit();
    const current: usize = @backingInt(self.state.category);
    for (categories, 0..) |name, index| {
        const chosen = index == current;
        const tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "inspector.category.{d}", .{index});
        if (dvui.button(@src(), name, .{}, .{
            .tag = tag,
            .id_extra = index,
            .font = fonts.font(name, 13),
            .corners = .all(13),
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 6 },
            .background = true,
            .color_fill = .{ .color = if (chosen) ui.mix(self.theme.control, self.theme.text, 0.18) else self.theme.control },
            .color_text = .{ .color = if (chosen) self.theme.text else self.theme.muted },
        })) self.state.category = @fromBackingInt(@intCast(index));
    }
}

fn drawSearch(self: *Context) !void {
    const arena = dvui.currentWindow().arena();
    const document = self.model.document();
    mutedCaption(self, if (self.state.target == .tap) "Add to Tap" else "Add to Hold");
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &self.search }, .placeholder = "Search keys, symbols, layers…" }, .{
        .expand = .horizontal,
        .tag = "inspector.search",
        .padding = .all(8),
    });
    entry.deinit();
    try drawCategories(self);
    const results = dvui.scrollArea(@src(), .{}, .{
        .min_size_content = .{ .w = 370, .h = 210 },
        .max_size_content = .{ .w = 400, .h = 210 },
        .expand = .horizontal,
    });
    defer results.deinit();
    var entries: [48]catalog.Entry = undefined;
    const found = catalog.search(document, self.state.target, self.state.category, std.mem.sliceTo(&self.search, 0), &entries);
    var buffer: [512]u8 = undefined;
    for (entries[0..found], 0..) |result, index| {
        const tag = try std.fmt.allocPrint(arena, "inspector.result.{d}", .{index});
        const text = catalog.label(result, document, &buffer);
        if (ui.richButton(@src(), text, .{
            .color = self.theme.text,
            .secondary = self.theme.text,
            .size = 16,
            .align_x = 0,
            .id_extra = index,
        }, .{
            .tag = tag,
            .id_extra = index,
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .margin = .{ .h = 4 },
            .corners = .all(6),
        })) add(self, result);
    }
    if (found == 0) caption("No matching actions for this target");
}

/// Resolves a pending editor request or a close request before continuing.
fn drawPrompt(self: *Context, t: ui.Theme) void {
    if (self.pending) {
        ui.label(t, "Pending edits · resolve before continuing", .{ .x = 18, .y = 769, .w = 400, .h = 23 }, 13);
        if (ui.button(t, "Apply", "pending.apply", .{ .x = 18, .y = 797, .w = 110, .h = 32 })) self.choose(.resolve_apply);
        if (ui.button(t, "Discard", "pending.discard", .{ .x = 140, .y = 797, .w = 110, .h = 32 })) self.choose(.resolve_discard);
        if (ui.button(t, "Keep editing", "pending.keep", .{ .x = 262, .y = 797, .w = 156, .h = 32 })) {
            self.choose(.keep_editing);
            self.pending = false;
        }
    } else if (self.close_requested) {
        ui.label(t, "Unsaved project · save before closing", .{ .x = 18, .y = 769, .w = 400, .h = 23 }, 13);
        if (ui.button(t, "Save and close", "close.save", .{ .x = 18, .y = 797, .w = 125, .h = 32 })) self.choose(.save_close);
        if (ui.button(t, "Close", "close.discard", .{ .x = 150, .y = 797, .w = 100, .h = 32 })) self.choose(.discard_close);
        if (ui.button(t, "Keep editing", "close.keep", .{ .x = 262, .y = 797, .w = 156, .h = 32 })) {
            self.choose(.keep_close);
            self.close_requested = false;
        }
    }
}

fn drawFooter(self: *Context, t: ui.Theme, count: usize, valid: bool) !void {
    const session = &self.edit_session;
    if (self.state.conversion) ui.label(t, self.state.removal_summary, .{ .x = 18, .y = 839, .w = 405, .h = 20 }, 11);
    if (self.diagnostic[0] != 0) ui.label(t, std.mem.sliceTo(&self.diagnostic, 0), .{ .x = 18, .y = 839, .w = 405, .h = 24 }, 11);
    if (ui.button(t, "Unassign", "inspector.unassign", .{ .x = 18, .y = 869, .w = 94, .h = 35 })) session.mutate(.unassign);
    const inherit: dvui.Rect = .{ .x = 119, .y = 869, .w = 85, .h = 35 };
    if (ui.buttonEnabled(t, "Inherit", "inspector.inherit", inherit, self.model.layer > 0)) session.mutate(.inherit);
    if (ui.button(t, "Cancel", "advanced.cancel", .{ .x = 211, .y = 869, .w = 82, .h = 35 })) self.choose(.cancel);
    const apply_caption = try std.fmt.allocPrint(dvui.currentWindow().arena(), "Apply ({d})", .{count});
    const apply: dvui.Rect = .{ .x = 300, .y = 869, .w = 122, .h = 35 };
    if (ui.buttonEnabled(t, apply_caption, "advanced.apply", apply, session.dirty() and valid)) self.choose(.apply);
    ui.label(t, "Do nothing", .{ .x = 18, .y = 909, .w = 95, .h = 16 }, 10);
    const lower = if (self.model.layer == 0) "Base has no lower layer" else "Lower active layer";
    ui.label(t, lower, .{ .x = 119, .y = 909, .w = 180, .h = 16 }, 10);
}
