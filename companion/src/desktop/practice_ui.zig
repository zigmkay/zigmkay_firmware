//! Redesigned main Tutor & Test keys screen matching the Companion Editor visual
//! language: unified top bar, Tutor | Test keys segmented control, key-confidence
//! strip, calm 3-line text stage, inline rundown, and Tap/Hold keyboard canvas.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const model = @import("layout-model");
const geometry = @import("physical-ui");
const keyboard_view = @import("practice_keyboard_ui.zig");
const presentation = @import("practice_presentation.zig");
const sheets_ui = @import("practice_sheets_ui.zig");
const tap_hold_ui = @import("practice_tap_hold_ui.zig");
const people_ui = @import("practice_people_ui.zig");

const control = desktop.practice_controller;
const storage = desktop.practice_storage;
const scratchpad = desktop.practice_scratchpad;

pub const Sheet = sheets_ui.Sheet;
pub const Picks = sheets_ui.Picks;
pub const BoardInfo = sheets_ui.BoardInfo;
pub const BoardLookup = sheets_ui.BoardLookup;
pub const EditKey = tap_hold_ui.EditKey;
pub const PersonEntry = people_ui.Entry;
pub const PeopleAction = people_ui.Action;

pub const Frame = struct {
    /// Live frames must come from the coherent identity-checked session adapter.
    /// `guide` shows the editor layout without a verified keyboard.
    source: enum { guide, live },
    labels: *const desktop.label_cache.LabelCache,
    geometry: []const model.physical_layout.Key,
    metadata: ?[]const desktop.practice.KeyMetadata = null,
    board_name: []const u8 = "",
    profile: []const u8,
    layer_name: []const u8 = "",
    layer: usize = 0,
    active_layers: u16 = 1,
    modifiers: model.Modifiers = .{},
    pressed: []const bool,
    stale: bool = false,
    /// Why typed text may not match the keys shown. Practice always types on
    /// the connected keyboard, never on an unflashed editor layout.
    layout_notice: LayoutNotice = .none,
    /// Whether the keyboard reports its tap/hold decisions (Test layout).
    tap_hold_support: control.TapHoldSupport = .unknown,
};

pub const LayoutNotice = enum {
    none,
    /// No keyboard verified this layout; the editor layout is only a guide.
    unverified,
    /// The verified keyboard runs a layout the editor has since changed.
    editor_changed,

    pub fn text(self: LayoutNotice) ?[]const u8 {
        return switch (self) {
            .none => null,
            .unverified => "Your keyboard may run a different layout than the one shown · flash this layout to practise it",
            .editor_changed => "The editor has changes your keyboard does not run yet · flash them to practise the new layout",
        };
    }
};

pub const Input = struct {
    now_us: u64,
    window_focused: bool = false,
    owns_input: bool = false,
    frame: ?Frame = null,
    resources: geometry.Resources = .{},
    fixture: bool = false,
    diagnostic: []const u8 = "",
    event_times: []const desktop.practice.EventTime = &.{},
    runs: []const storage.RunRecord = &.{},
    /// Finds a keyboard of the catalog by id, for where a key used to be.
    board_lookup: ?BoardLookup = null,
    /// The practised keyboard is the one the editor shows, so a key can be
    /// opened there.
    editor_board: bool = false,
    /// The people who practise on this computer, for the person chip; empty
    /// hides it.
    people: []const PersonEntry = &.{},
};

pub const View = struct {
    scroll: presentation.Scroll = .{},
    drawn_len: usize = 0,
    drawn_keyboard: bool = false,
    drawn_panel: bool = false,
    was_focused: ?bool = null,
    /// Secondary sheets & settings popover state (expanded in M4).
    sheet: Sheet = .none,
    settings_open: bool = false,
    confirm_reset: bool = false,
    /// Characters chosen in the layout-changes and reset sheets.
    picks: Picks = .{},
    custom_text_buf: [256]u8 = @splat(0),
    custom_text_seeded: bool = false,
    last_pressed_error_key: ?usize = null,
    last_error_flash_us: u64 = 0,
    same_hand_shift_until_us: u64 = 0,
    /// Where the Progress sheet is scrolled.
    progress_scroll: dvui.ScrollInfo = .{},
    /// The Progress sheet scrolls to its tap/hold section once it can.
    focus_tap_hold: bool = false,
    /// Shows this key's hover card without the pointer (gallery fixtures).
    forced_tooltip: ?u21 = null,
    /// Test layout's text field: whether it holds the keys, and its size.
    test_field: presentation.TestField = .{},
    /// The person menu and the new-profile and rename dialog.
    people: people_ui.State = .{},
};

pub const DrawResult = struct {
    leave: bool = false,
    action: ?control.Action = null,
    /// The Progress sheet asked to open this key in the editor.
    edit_key: ?EditKey = null,
    /// A person to switch to, create, rename or delete.
    people: ?PeopleAction = null,
};

fn running(owner: *const control.Controller) bool {
    return owner.config.mode == .tutor and owner.active and owner.session.state != .complete;
}

/// Free typing observes only the verified live presenter.
pub fn drawFreeCompanion(
    frame: desktop.live_keyboard.Frame,
    physical: []const model.physical_layout.Key,
    theme: ui.Theme,
    bounds: dvui.Rect,
    resources: geometry.Resources,
) !void {
    const panel = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .corners = .all(12),
        .padding = .{},
        .tag = "free.keyboard",
    });
    defer panel.deinit();
    const title: dvui.Rect = .{ .x = 8, .y = 0, .w = bounds.w - 16, .h = 28 };
    const notice: dvui.Rect = .{ .x = 8, .y = 38, .w = bounds.w - 16, .h = 48 };
    const labels = frame.labels orelse {
        presentation.caption("Companion · no verified keyboard layout", title, 18, theme.text, "free.keyboard.source");
        const waiting = "Waiting for matching keyboard telemetry. Native typing remains available.";
        presentation.caption(waiting, notice, 16, theme.muted, "free.keyboard.unavailable");
        return;
    };
    const source = try std.fmt.allocPrint(dvui.currentWindow().arena(), "Live companion · {s} · {s} · layer {d}", .{
        std.mem.sliceTo(&frame.profile, 0),
        if (frame.stale) "stale / reconnecting" else "verified keyboard",
        frame.layer,
    });
    presentation.caption(source, title, 18, theme.text, "free.keyboard.source");
    if (physical.len == 0) {
        presentation.caption("Keyboard view unavailable", notice, 16, theme.muted, "free.keyboard.unavailable");
        return;
    }
    const output = try dvui.currentWindow().arena().alloc(desktop.physical_view.DrawKey, physical.len);
    const area: desktop.physical_view.Rect = .{ .x = 18, .y = 34, .w = @max(0, bounds.w - 36), .h = @max(0, bounds.h - 44) };
    const plan = try desktop.physical_view.plan(output, physical, labels, frame.layer, frame.modifiers, area, .{
        .pressed = frame.pressed,
        .active_layers = frame.active,
        .stale = frame.stale,
    });
    try geometry.draw(frame.layer, plan, resources);
}

fn nativeEventTime(times: []const desktop.practice.EventTime, number: u16) ?u64 {
    for (times) |time| if (time.number == number) return time.now_us;
    return null;
}

fn insertText(owner: *control.Controller, text: []const u8, at: u64, paste: bool) !void {
    try owner.insertOs(true, text, at, paste);
}

fn consumeInput(
    owner: *control.Controller,
    view: *View,
    data: *dvui.WidgetData,
    input: Input,
    pending: *?control.Intent,
) !void {
    if (!input.owns_input or !input.window_focused) return;
    // The person menu and dialog take the keys; nothing reaches the lesson.
    if (view.people.open()) return;
    if (view.sheet != .none or view.settings_open) {
        // Esc closes any open sheet or settings popover cleanly.
        for (dvui.events()) |*event| {
            if (event.handled) continue;
            if (event.evt == .key and event.evt.key.action != .up and event.evt.key.code == .escape) {
                view.sheet = .none;
                view.settings_open = false;
                view.confirm_reset = false;
                view.picks.confirm = false;
                event.handle(@src(), data);
            }
        }
        return;
    }

    if (owner.config.mode == .test_keys) return consumeFieldInput(owner, view, data);

    // Paused state: Esc or Enter resumes cleanly.
    if (owner.session.state == .paused) {
        for (dvui.events()) |*event| {
            if (event.handled) continue;
            if (event.evt == .key and event.evt.key.action != .up) {
                if (event.evt.key.code == .escape or event.evt.key.code == .enter) {
                    if (pending.* == null) pending.* = .resume_run;
                    event.handle(@src(), data);
                } else if (event.evt.key.code == .tab) {
                    if (pending.* == null) pending.* = .new_exercise;
                    event.handle(@src(), data);
                }
            }
        }
        return;
    }

    if (!owner.acceptingOsText(true)) return;
    dvui.wantTextInput(data.borderRectScale().r.toNatural());
    const prev_errors = owner.session.error_count;
    for (dvui.events()) |*event| {
        if (event.handled) continue;
        const at = nativeEventTime(input.event_times, event.num) orelse input.now_us;
        switch (event.evt) {
            .text => |text| {
                if (text.action == .value and !text.action.value.selected) {
                    try insertText(owner, text.action.value.txt, at, false);
                }
                event.handle(@src(), data);
            },
            .key => |key| {
                if (key.action != .up) try handleKey(owner, key, at, pending);
                event.handle(@src(), data);
            },
            else => {},
        }
    }

    // Track physical mis-key flash when Live-HID has a pressed key on mismatch;
    // forgiving input keeps typos quiet.
    if (owner.session.error_count > prev_errors and owner.session.error_mode != .forgive) {
        if (input.frame) |frame| {
            for (frame.pressed, 0..) |is_down, kidx| {
                if (is_down) {
                    view.last_pressed_error_key = kidx;
                    view.last_error_flash_us = input.now_us;
                    break;
                }
            }
        }
    }
}

/// Test layout's field. Captured, it takes every key and text event before
/// the controls and dvui's focus navigation see them; shortcuts that are no
/// editor command only show as the last key. Released, the keyboard steers
/// the app, and Enter takes the keys back while no control has focus.
fn consumeFieldInput(owner: *control.Controller, view: *View, data: *dvui.WidgetData) void {
    const field = &view.test_field;
    if (!field.captured) {
        const focused = dvui.focusedWidgetId();
        if (focused != null and focused.? != data.id) return;
        for (dvui.events()) |*event| {
            if (event.handled or event.evt != .key) continue;
            const key = event.evt.key;
            if (key.action == .down and key.code == .enter and !key.mod.control() and !key.mod.command() and !key.mod.alt()) {
                captureField(view, data.id);
                event.handle(@src(), data);
                break;
            }
        }
        return;
    }
    // The field holds the focus, so no control shows it or reacts to keys.
    if (dvui.focusedWidgetId() != data.id) dvui.focusWidget(data.id, null, null);
    dvui.wantTextInput(data.borderRectScale().r.toNatural());
    const editor = &owner.test_keys.field;
    for (dvui.events()) |*event| {
        if (event.handled) continue;
        switch (event.evt) {
            .text => |text| {
                event.handle(@src(), data);
                if (text.action == .value and !text.action.value.selected) {
                    owner.test_keys.typeText(text.action.value.txt);
                    editor.reveal(field.cells);
                }
            },
            .key => |key| {
                event.handle(@src(), data);
                if (key.action != .up) fieldKey(owner, view, key);
                // Esc let go: the next keys belong to the app again.
                if (!field.captured) return;
            },
            else => {},
        }
    }
}

fn captureField(view: *View, root: dvui.Id) void {
    view.test_field.captured = true;
    dvui.focusWidget(root, null, null);
}

fn releaseField(view: *View) void {
    view.test_field.captured = false;
    dvui.focusWidget(null, null, null);
}

/// Runs the field command of `key` and shows the key in the telemetry.
fn fieldKey(owner: *control.Controller, view: *View, key: dvui.Event.Key) void {
    if (key.code.isModifier()) return;
    const platform = scratchpad.Platform.native();
    const pressed: scratchpad.Key = .{ .code = fieldCode(key.code), .mods = .{
        .shift = key.mod.shift(),
        .alt = key.mod.alt(),
        .control = key.mod.control(),
        .command = key.mod.command(),
    } };
    const command = scratchpad.commandFor(pressed, platform);
    // Characters arrive as text right after their key, and the text names them.
    const types = !pressed.mods.control and !pressed.mods.command and (platform == .mac or !pressed.mods.alt);
    if (command == null and types and printable(key.code)) return;
    var name: [16]u8 = undefined;
    var combo: [48]u8 = undefined;
    const shown = scratchpad.comboText(&combo, pressed, keyName(&name, key.code), platform);
    const run = command orelse return owner.test_keys.setLastKey(shown, "");
    owner.test_keys.setLastKey(shown, if (run.op == .release) "" else run.label());
    const editor = &owner.test_keys.field;
    switch (run.op) {
        .release => return releaseField(view),
        .copy, .cut => if (editor.hasSelection()) dvui.clipboardTextSet(editor.selected()),
        else => {},
    }
    editor.run(run, view.test_field.cells, if (run.op == .paste) dvui.clipboardText() else "");
}

fn fieldCode(code: dvui.enums.Key) scratchpad.Code {
    return switch (code) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .backspace => .backspace,
        .delete => .delete,
        .enter, .kp_enter => .enter,
        .tab => .tab,
        .escape => .escape,
        .insert => .insert,
        .a => .a,
        .c => .c,
        .v => .v,
        .x => .x,
        .y => .y,
        .z => .z,
        else => .other,
    };
}

/// Keys whose press types a character.
fn printable(code: dvui.enums.Key) bool {
    return switch (code) {
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => true,
        .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => true,
        .space, .minus, .equal, .left_bracket, .right_bracket, .backslash, .semicolon, .apostrophe, .comma, .period, .slash, .grave => true,
        .kp_divide, .kp_multiply, .kp_subtract, .kp_add, .kp_decimal, .kp_equal => true,
        .kp_0, .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7, .kp_8, .kp_9 => true,
        else => false,
    };
}

/// How the telemetry names a key the field has no glyph for, such as "D".
fn keyName(buffer: []u8, code: dvui.enums.Key) []const u8 {
    const tag = @tagName(code);
    const value = @backingInt(code);
    if (value >= @backingInt(dvui.enums.Key.a) and value <= @backingInt(dvui.enums.Key.z)) {
        buffer[0] = std.ascii.toUpper(tag[0]);
        return buffer[0..1];
    }
    if (value >= @backingInt(dvui.enums.Key.zero) and value <= @backingInt(dvui.enums.Key.nine)) {
        buffer[0] = '0' + @as(u8, @intCast(value - @backingInt(dvui.enums.Key.zero)));
        return buffer[0..1];
    }
    if (value >= @backingInt(dvui.enums.Key.f1) and value <= @backingInt(dvui.enums.Key.f25))
        return std.fmt.bufPrint(buffer, "F{d}", .{value - @backingInt(dvui.enums.Key.f1) + 1}) catch tag;
    return switch (code) {
        .space => "Space",
        .minus => "-",
        .equal => "=",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .grave => "`",
        else => tag,
    };
}

fn handleKey(
    owner: *control.Controller,
    key: dvui.Event.Key,
    at: u64,
    pending: *?control.Intent,
) !void {
    if (key.matchBind("paste")) return insertText(owner, dvui.clipboardText(), at, true);
    if (key.mod.control() or key.mod.command()) {
        if (stuckShortcut(owner, key.code)) |intent| {
            if (pending.* == null) pending.* = intent;
        }
        return;
    }
    const is_zig = owner.config.stage == .free_text and owner.config.stage6_source == .zig_code;
    switch (key.code) {
        .backspace => owner.session.backspace(),
        .tab => {
            if (is_zig) {
                try insertText(owner, "    ", at, false);
            } else if (pending.* == null) {
                pending.* = .new_exercise;
            }
        },
        .enter => try insertText(owner, "\n", at, false),
        .escape => owner.pause(at),
        else => {},
    }
}

/// The stuck help's buttons as Ctrl (or Cmd) shortcuts, so typing never has to
/// leave the keyboard: Down lowers the target, P practises the letter and
/// Backspace dismisses the help.
fn stuckShortcut(owner: *const control.Controller, code: dvui.enums.Key) ?control.Intent {
    const help = presentation.stuckHelp(owner) orelse return null;
    return switch (code) {
        .down => if (help.lower_target) |lower| .{ .set_target_wpm = lower } else null,
        .p => .{ .practise_key = .{ .cp = help.cp, .slow = help.reason == .hits } },
        .backspace => .{ .dismiss_stuck = help.cp },
        else => null,
    };
}

pub fn draw(owner: *control.Controller, view: *View, theme: ui.Theme, bounds: dvui.Rect, input: Input) !DrawResult {
    view.drawn_keyboard = false;
    view.drawn_panel = false;

    const root = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .padding = .{},
        .margin = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .tag = "practice.inline",
    });
    defer root.deinit();

    const size: dvui.Rect = .{ .w = bounds.w, .h = root.data().rect.h };
    if (size.h < 300 or size.w < 300) {
        if (input.fixture) std.log.err("Practice bounds height={d} width={d} requested={d}", .{ size.h, size.w, bounds.h });
        return .{};
    }
    view.drawn_panel = true;

    trackWindowFocus(owner, view, input);
    // Test layout opens with its field holding the keys.
    if (owner.config.mode == .test_keys) {
        if (view.test_field.capture_on_show) {
            view.test_field.capture_on_show = false;
            view.test_field.captured = true;
        }
    } else view.test_field.capture_on_show = true;
    var pending: ?control.Intent = null;
    try consumeInput(owner, view, root.data(), input, &pending);

    // 1. Unified Editor-style Top Bar (64px height matching Editor toolbar scale)
    const topbar_h: f32 = 64;
    var people_action: ?PeopleAction = null;
    const leave = try drawTopBar(owner, view, theme, .{ .x = 0, .y = 0, .w = size.w, .h = topbar_h }, input, &pending, &people_action);

    // 2. Centered Workspace (Editor-proportioned width for readable fonts & full keyboard)
    const max_content_w: f32 = 1440;
    const pad_x: f32 = @max(18.0, (size.w - max_content_w) * 0.5);
    const content_w = @max(280.0, size.w - pad_x * 2);
    const work_top = topbar_h + 14;
    const work_h = @max(200.0, size.h - work_top - 16);

    if (owner.config.mode == .test_keys) {
        if (try drawTestKeysWorkspace(owner, view, theme, .{ .x = pad_x, .y = work_top, .w = content_w, .h = work_h }, input)) captureField(view, root.data().id);
    } else {
        try drawTutorWorkspace(owner, view, theme, .{ .x = pad_x, .y = work_top, .w = content_w, .h = work_h }, input, &pending);
    }

    // 3. Secondary Sheets (Stages / Progress) and compact Settings popover
    var edit_key: ?EditKey = null;
    try sheets_ui.drawSheet(owner, &view.sheet, theme, .{
        .board_name = if (input.frame) |f| f.board_name else "",
        .profile_name = if (input.frame) |f| f.profile else "",
        .person_name = for (input.people) |p| {
            if (p.current) break p.name;
        } else "",
        .labels = if (input.frame) |f| f.labels else null,
        .runs = input.runs,
        .custom_text_buf = &view.custom_text_buf,
        .custom_text_seeded = &view.custom_text_seeded,
        .geometry = if (input.frame) |f| f.geometry else &.{},
        .board_lookup = input.board_lookup,
        .picks = &view.picks,
        .progress_scroll = &view.progress_scroll,
        .focus_tap_hold = &view.focus_tap_hold,
        .edit_key = &edit_key,
        .can_edit = input.editor_board and !input.fixture,
    }, &pending);
    if (try sheets_ui.drawSettingsPopover(owner, &view.settings_open, &view.confirm_reset, theme, size.w - 16, topbar_h + 6, &pending))
        sheets_ui.openSheet(&view.sheet, &view.picks, .reset_keys);
    if (people_ui.dialog(&view.people, theme, input.people)) |action| people_action = action;

    view.drawn_len = owner.session.len;
    return .{
        .leave = leave,
        .action = if (pending) |intent| owner.action(intent) else null,
        .edit_key = edit_key,
        .people = people_action,
    };
}

/// Opens the Progress sheet scrolled to its tap/hold section.
fn openTapHoldDetails(view: *View) void {
    view.sheet = .progress;
    view.settings_open = false;
    view.focus_tap_hold = true;
}

/// Unified Editor-style top bar:
/// Left: ← Back to editor, Breadcrumb, Tutor | Test keys segmented switch, Stage pill.
/// Right: Live/Draft pill, Progress button, Guidance selector, Settings ⚙.
fn drawTopBar(
    owner: *const control.Controller,
    view: *View,
    theme: ui.Theme,
    bounds: dvui.Rect,
    input: Input,
    pending: *?control.Intent,
    people_action: *?PeopleAction,
) !bool {
    const bar = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .{ .h = 1 },
        .padding = .{},
        .margin = .{},
        .tag = "practice.topbar",
    });
    defer bar.deinit();

    const arena = dvui.currentWindow().arena();
    const ctrl_h: f32 = 38;
    const y: f32 = (bounds.h - ctrl_h) * 0.5;
    var lx: f32 = 18;

    // ← Back to editor
    const leave = ui.iconButton(theme, ui.control_icons.back, "Back to editor", "practice.back", .{ .x = lx, .y = y, .w = 152, .h = ctrl_h }, false);
    lx += 164;

    // Board › Profile breadcrumb (shown when viewport >= 1120px)
    if (bounds.w >= 1120) {
        if (input.frame) |frame| {
            const crumb = if (frame.board_name.len > 0)
                try std.fmt.allocPrint(arena, "{s} › {s}", .{ frame.board_name, frame.profile })
            else
                frame.profile;
            const cw: f32 = @min(220.0, ui.editorFont(crumb, 14).textSize(crumb).w + 10);
            presentation.label(crumb, .{ .x = lx, .y = y, .w = cw, .h = ctrl_h }, 14, theme.muted, null);
            lx += cw + 14;
        }
    }

    // Test layout | Tutor segmented control (Test layout first, matching "Try it out" default)
    const seg_w: f32 = 194;
    const seg_track = dvui.box(@src(), .{}, .{
        .rect = .{ .x = lx, .y = y, .w = seg_w, .h = ctrl_h },
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(9),
        .padding = .{},
        .margin = .{},
    });
    seg_track.deinit();

    const seg_items = [_]struct { mode: control.Mode, label: []const u8, tag: []const u8, w: f32 }{
        .{ .mode = .test_keys, .label = "Test layout", .tag = "practice.mode.test_keys", .w = 108 },
        .{ .mode = .tutor, .label = "Tutor", .tag = "practice.mode.tutor", .w = 78 },
    };
    var sx = lx + 3;
    for (seg_items, 0..) |item, i| {
        const active = owner.config.mode == item.mode;
        var opts = ui.options(theme, .{ .x = sx, .y = y + 3, .w = item.w, .h = ctrl_h - 6 }, 14.5);
        opts.id_extra = 0x9000 + i;
        opts.tag = item.tag;
        opts.corners = .all(6);
        opts.padding = .{};
        opts.background = active;
        opts.color_fill = .{ .color = theme.control };
        opts.color_text = .{ .color = if (active) theme.text else theme.muted };
        if (dvui.button(@src(), item.label, .{}, opts) and !active and pending.* == null) {
            pending.* = .{ .set_mode = item.mode };
        }
        sx += item.w + 2;
    }
    lx += seg_w + 12;

    // Stage pill (Tutor mode only) — reserve exact width for right-hand controls so items never overlap.
    // The person chip shows in the Tutor only; Test layout is shared and unscored.
    const current_person: ?*const PersonEntry = if (owner.config.mode == .tutor) for (input.people) |*p| {
        if (p.current) break p;
    } else null else null;
    const base_right_w: f32 = if (owner.config.mode == .tutor) 18 + 38 + 130 + 104 + 12 else 18 + 38 + 104 + 12;
    // Where the stage pill would be squeezed, the chip shows the avatar alone.
    const full_chip_w: f32 = if (current_person) |p| people_ui.chipWidth(p.name, false) else 0;
    const compact_chip = bounds.w - base_right_w - lx - 8 - (full_chip_w + 10) < 260;
    const chip_w: f32 = if (current_person) |p| people_ui.chipWidth(p.name, compact_chip) else 0;
    const chip_room: f32 = if (current_person != null) chip_w + 10 else 0;
    const right_fixed_w = base_right_w + chip_room;
    if (owner.config.mode == .tutor) {
        const st = owner.config.stage;
        const stage_lbl = if (st == .all_letters or st == .home_row)
            try std.fmt.allocPrint(arena, "{s} ({d}/{d})", .{ st.title(), owner.learning.unlocked_count, owner.learning.unlock_len })
        else
            st.title();
        const max_pill_w = @max(@as(f32, 0), bounds.w - right_fixed_w - lx - 8);
        const desired_w = @min(@as(f32, 310), @max(@as(f32, 180), ui.editorFont(stage_lbl, 14.5).textSize(stage_lbl).w + 54));
        const pill_w = @min(desired_w, max_pill_w);
        if (pill_w >= 130) {
            var sopts = ui.options(theme, .{ .x = lx, .y = y, .w = pill_w, .h = ctrl_h }, 14.5);
            sopts.tag = "practice.stage_pill";
            sopts.background = true;
            sopts.border = .all(1);
            sopts.corners = .all(8);
            sopts.padding = .{ .x = 12, .w = 28 };
            sopts.color_fill = .{ .color = ui.mix(theme.panel, theme.accent, 0.16) };
            sopts.color_border = .{ .color = ui.mix(theme.panel, theme.accent, 0.5) };
            sopts.color_text = .{ .color = theme.accent };
            if (dvui.button(@src(), stage_lbl, .{}, sopts)) {
                view.sheet = if (view.sheet == .stages) .none else .stages;
                view.settings_open = false;
            }
            dvui.icon(@src(), "stage_chevron", ui.control_icons.expand, .{}, .{
                .color_text = .{ .color = theme.accent },
                .rect = .{ .x = lx + pill_w - 22, .y = y + (ctrl_h - 15) * 0.5, .w = 15, .h = 15 },
                .padding = .{},
                .margin = .{},
            });
            lx += pill_w + 10;
        }
    }

    // Right group (right-to-left placement)
    var rx: f32 = bounds.w - 18;

    // Settings gear button
    rx -= 38;
    if (ui.iconButton(theme, ui.control_icons.settings, "", "practice.settings_btn", .{ .x = rx, .y = y, .w = 38, .h = ctrl_h }, false)) {
        view.settings_open = !view.settings_open;
        view.confirm_reset = false;
        view.people.close();
        if (view.settings_open) view.sheet = .none;
    }

    // Guidance selector pill (Tutor mode)
    if (owner.config.mode == .tutor) {
        rx -= 130;
        const g_lbl: []const u8 = switch (owner.config.guidance) {
            .guided => "Guided",
            .on_hesitation => "Hesitation",
            .free => "Free",
        };
        var gopts = ui.options(theme, .{ .x = rx, .y = y, .w = 122, .h = ctrl_h }, 14.5);
        gopts.tag = "practice.assistance";
        gopts.background = true;
        gopts.border = .all(1);
        gopts.corners = .all(8);
        gopts.padding = .{ .x = 12, .w = 26 };
        gopts.color_fill = .{ .color = theme.control };
        gopts.color_border = .{ .color = theme.border };
        gopts.color_text = .{ .color = theme.text };
        if (dvui.button(@src(), g_lbl, .{}, gopts) and pending.* == null) {
            const next_g: storage.GuidanceMode = switch (owner.config.guidance) {
                .guided => .on_hesitation,
                .on_hesitation => .free,
                .free => .guided,
            };
            pending.* = .{ .set_guidance = next_g };
        }
        dvui.icon(@src(), "guidance_chevron", ui.control_icons.expand, .{}, .{
            .color_text = .{ .color = theme.muted },
            .rect = .{ .x = rx + 122 - 22, .y = y + (ctrl_h - 15) * 0.5, .w = 15, .h = 15 },
            .padding = .{},
            .margin = .{},
        });
    }

    // Progress sheet button
    rx -= 104;
    if (ui.button(theme, "Progress", "practice.progress_btn", .{ .x = rx, .y = y, .w = 96, .h = ctrl_h })) {
        view.sheet = if (view.sheet == .progress) .none else .progress;
        view.settings_open = false;
    }

    // Live / Draft status pill (only shown when guaranteed not to collide with left controls)
    const status_pill_w: f32 = 126;
    if (rx - status_pill_w - 14 - chip_room >= lx) {
        const is_live = input.frame != null and input.frame.?.source == .live and !input.frame.?.stale;
        rx -= status_pill_w + 10;
        if (is_live) {
            ui.runningBadge(theme, .{ .x = rx, .y = y + 6, .w = status_pill_w, .h = 26 }, 0x9100);
        } else {
            const pill_text = "Layout guide";
            const pill = dvui.box(@src(), .{}, .{
                .rect = .{ .x = rx, .y = y + 6, .w = status_pill_w, .h = 26 },
                .background = true,
                .color_fill = .{ .color = theme.control },
                .color_border = .{ .color = theme.border },
                .border = .all(1),
                .corners = .all(13),
                .padding = .{},
                .margin = .{},
            });
            pill.deinit();
            presentation.caption(pill_text, .{ .x = rx, .y = y + 6, .w = status_pill_w, .h = 26 }, 13, theme.muted, null);
        }
    }

    // Person chip and its menu
    if (current_person != null) {
        rx -= chip_w + 10;
        const was_open = view.people.menu_open;
        if (people_ui.chipAndMenu(&view.people, theme, .{ .x = rx, .y = y + 2, .w = chip_w, .h = ctrl_h - 4 }, input.people, compact_chip)) |action| people_action.* = action;
        if (view.people.menu_open and !was_open) {
            view.settings_open = false;
            view.sheet = .none;
        }
    }

    return leave;
}

fn drawTutorWorkspace(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    bounds: dvui.Rect,
    input: Input,
    pending: *?control.Intent,
) !void {
    const focus = desktop.practice_view.focus(&owner.session);
    const gap: f32 = 10;

    // 1. Key-Confidence Strip (top)
    const conf_h: f32 = 84;
    const labels = if (input.frame) |f| f.labels else null;
    if (try presentation.confidenceStrip(owner, theme, .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = conf_h }, .{
        .labels = labels,
        .forced_tooltip = view.forced_tooltip,
    })) openTapHoldDetails(view);

    // The layout-change question sits between the strip and the card, so it
    // shows with any guidance, and only before a lesson starts.
    var top_h = conf_h;
    if (presentation.showsLayoutChangeStrip(owner)) {
        const strip_h = presentation.layout_change_strip_h;
        const choice = try presentation.layoutChangeStrip(owner, theme, .{ .x = bounds.x, .y = bounds.y + conf_h + gap, .w = bounds.w, .h = strip_h }, pending);
        if (choice == .review) sheets_ui.openSheet(&view.sheet, &view.picks, .layout_changes);
        top_h += gap + strip_h;
    } else if (presentation.stuckHelp(owner)) |help| {
        const strip_h = presentation.help_strip_h;
        try presentation.stuckStrip(owner, theme, .{ .x = bounds.x, .y = bounds.y + conf_h + gap, .w = bounds.w, .h = strip_h }, help, pending);
        top_h += gap + strip_h;
    }

    // Resolve active hint once for both typing-card footer and keyboard overlay
    var resolved_hint: ?desktop.practice.Hint = null;
    if (input.frame) |frame| {
        if (running(owner) and focus < owner.session.reference_len) {
            const layer = @min(frame.layer, frame.labels.layer_count - 1);
            resolved_hint = try desktop.practice.hintForDrill(
                if (owner.profile_bound) &owner.profile else null,
                frame.labels.practiceLabels(),
                layer,
                frame.modifiers.toByte(),
                owner.session.reference[focus],
                frame.active_layers,
                owner.drillsCombos(),
            );
        }
    }

    // 2. Calm Typing Card (middle) + Physical Tap/Hold Keyboard (bottom)
    const rem_y = bounds.y + top_h + gap;
    const rem_h = @max(180.0, bounds.h - top_h - gap);
    const show_kb = owner.config.guidance != .free;
    const card_h: f32 = if (show_kb)
        std.math.clamp(rem_h * 0.34, 196.0, 260.0)
    else
        @min(rem_h, 360.0);

    // Detect optional subtle opposite-hand Shift nudge in Stage 3 on Live-HID.
    if (owner.config.stage == .shift and owner.profile_bound) {
        if (input.frame) |frame| {
            if (frame.source == .live) {
                if (resolved_hint) |h| {
                    if ((h.modifiers & 0x22) != 0 and h.key < owner.profile.key_count) {
                        const target_hand = owner.profile.keys[h.key].hand;
                        const same_left = target_hand == .left and frame.modifiers.left_shift and !frame.modifiers.right_shift;
                        const same_right = target_hand == .right and frame.modifiers.right_shift and !frame.modifiers.left_shift;
                        if (same_left or same_right) {
                            view.same_hand_shift_until_us = input.now_us + 2_000_000;
                        }
                    }
                }
            }
        }
    }
    const shift_nudge = owner.config.stage == .shift and input.now_us < view.same_hand_shift_until_us;

    try presentation.typingCard(
        owner,
        theme,
        .{ .x = bounds.x, .y = rem_y, .w = bounds.w, .h = card_h },
        focus,
        resolved_hint,
        if (input.frame) |f| f.labels else null,
        input.now_us,
        statusNote(owner, input),
        shift_nudge,
        pending,
    );

    if (show_kb) {
        const kb_y = rem_y + card_h + gap;
        const kb_h = @max(110.0, bounds.y + bounds.h - kb_y);
        try drawKeyboardArea(owner, view, theme, .{ .x = bounds.x, .y = kb_y, .w = bounds.w, .h = kb_h }, focus, resolved_hint, input);
        if (try presentation.lessonNotices(owner, theme, .{ .x = bounds.x, .y = kb_y, .w = bounds.w, .h = kb_h }, input.now_us, labels))
            openTapHoldDetails(view);
    } else {
        if (try presentation.lessonNotices(owner, theme, .{ .x = bounds.x, .y = rem_y, .w = bounds.w, .h = card_h }, input.now_us, labels))
            openTapHoldDetails(view);
    }
}

/// Returns true when a click into the text field asks to capture it.
fn drawTestKeysWorkspace(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    bounds: dvui.Rect,
    input: Input,
) !bool {
    const gap: f32 = 12;
    const layer = if (input.frame) |f| f.layer else owner.test_keys.highest_layer;
    const layer_name = if (input.frame) |f| f.layer_name else "";
    const mods = if (input.frame) |f| f.modifiers.toByte() else owner.test_keys.modifiers;
    // A second row shows the keyboard's tap/hold decisions when the layout
    // has keys that tap and hold.
    const tap_holds: ?presentation.TelemetryTapHolds = if (tap_hold_ui.layoutHasTapHolds(owner)) .{
        .labels = if (input.frame) |f| f.labels else null,
        .support = if (input.frame) |f| f.tap_hold_support else .unknown,
    } else null;
    const bar_h: f32 = presentation.telemetry_row_h + if (tap_holds != null) tap_hold_ui.test_row_h - 4 else 0;

    try presentation.testKeysTelemetryBar(
        owner,
        theme,
        .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bar_h },
        layer,
        layer_name,
        mods,
        tap_holds,
    );

    const rem_y = bounds.y + bar_h + gap;
    const rem_h = @max(220.0, bounds.h - bar_h - gap);
    // About six rows of text on a roomy window, at least three.
    const scratch_h: f32 = std.math.clamp(rem_h * 0.36, presentation.testFieldHeight(3), presentation.testFieldHeight(presentation.test_field_rows));
    const clicked = try presentation.testLayoutScratchpad(
        owner,
        theme,
        .{ .x = bounds.x, .y = rem_y, .w = bounds.w, .h = scratch_h },
        &view.test_field,
    );

    const kb_y = rem_y + scratch_h + gap;
    const kb_h = @max(160.0, bounds.y + bounds.h - kb_y);
    try drawKeyboardArea(owner, view, theme, .{ .x = bounds.x, .y = kb_y, .w = bounds.w, .h = kb_h }, 0, null, input);
    return clicked;
}

fn drawKeyboardArea(
    owner: *const control.Controller,
    view: *View,
    theme: ui.Theme,
    area: dvui.Rect,
    focus: usize,
    resolved_hint: ?desktop.practice.Hint,
    input: Input,
) !void {
    view.drawn_keyboard = input.frame != null;
    var bounds = area;
    if (input.frame) |shown| if (shown.layout_notice.text()) |notice| {
        const notice_h: f32 = 30;
        const strip = dvui.box(@src(), .{}, .{
            .rect = .{ .x = area.x, .y = area.y, .w = area.w, .h = notice_h },
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, theme.accent, 0.14) },
            .color_border = .{ .color = ui.mix(theme.panel, theme.accent, 0.45) },
            .border = .all(1),
            .corners = .all(8),
            .padding = .{},
            .margin = .{},
        });
        defer strip.deinit();
        presentation.caption(notice, .{ .x = 12, .y = 0, .w = @max(0, area.w - 24), .h = notice_h }, 13, theme.text, "practice.keyboard.notice");
        bounds.y += notice_h + 8;
        bounds.h = @max(0, bounds.h - notice_h - 8);
    };
    const frame = input.frame orelse {
        const panel = dvui.box(@src(), .{}, .{
            .rect = bounds,
            .background = true,
            .color_fill = .{ .color = theme.panel },
            .color_border = .{ .color = theme.border },
            .border = .all(1),
            .corners = .all(12),
            .padding = .{},
            .margin = .{},
            .tag = "practice.keyboard",
        });
        defer panel.deinit();
        presentation.caption("Waiting for a keyboard that runs this layout · flash it from the editor if yours runs another one", .{ .x = 16, .y = 0, .w = bounds.w - 32, .h = bounds.h }, 15, theme.muted, "practice.keyboard.source");
        return;
    };

    const arena = dvui.currentWindow().arena();
    const labels = frame.labels;
    const is_test_keys = owner.config.mode == .test_keys;
    const guided = !is_test_keys and owner.shouldShowKeyboardGuidance(input.now_us);

    var layer = @min(frame.layer, labels.layer_count - 1);
    var active = frame.active_layers;
    var mods = frame.modifiers;

    const tap = try arena.alloc(bool, labels.key_count);
    const hold = try arena.alloc(bool, labels.key_count);
    const one_shot = try arena.alloc(bool, labels.key_count);
    @memset(tap, false);
    @memset(hold, false);
    @memset(one_shot, false);

    if (guided and resolved_hint != null) {
        try desktop.practice.guidanceWithProfile(
            if (owner.profile_bound) &owner.profile else null,
            labels.practiceLabels(),
            frame.metadata,
            layer,
            mods.toByte(),
            resolved_hint,
            .{ .tap = tap, .hold = hold, .one_shot = one_shot },
        );
    }

    const hold_source_layer = layer;
    if (guided) if (resolved_hint) |h| {
        if (frame.source == .guide or h.layer != layer) {
            layer = h.layer;
            mods = @bitCast(h.modifiers);
            active = 1 | (@as(u16, 1) << @intCast(layer));
        }
    };

    const flash_key: ?usize = if (!is_test_keys and view.last_pressed_error_key != null and
        input.now_us -| view.last_error_flash_us < 280_000)
        view.last_pressed_error_key
    else
        null;

    const source_title = switch (frame.source) {
        .live => if (frame.stale) "Live keyboard · stale" else "Live keyboard",
        .guide => "Layout guide",
    };
    const heat = try lessonHeat(arena, owner, labels.key_count, layer);
    // Tap/hold marks: the last lesson's mistaken holds and taps beside the
    // heatmap, or the keys of Test layout's newest hold.
    const marks: []const keyboard_view.KeyMark = if (is_test_keys) marks: {
        if (tap_hold_ui.testMarksRefresh(owner, input.now_us)) |wait| dvui.timer(dvui.parentGet().data().id, @intCast(@max(@as(u64, 1), wait)));
        break :marks try tap_hold_ui.testMarks(arena, owner, theme, labels, input.now_us);
    } else if (heat.len > 0) try tap_hold_ui.lessonMarks(arena, owner, theme, labels.key_count) else &.{};
    var mark_holds = false;
    var mark_taps = false;
    if (marks.len > 0 and !is_test_keys) if (owner.last_lesson) |lesson| for (lesson.tapHoldKeySlice()) |key| {
        if (key.accidental_holds > 0) mark_holds = true else if (key.accidental_taps > 0) mark_taps = true;
    };
    const src_caption = if (heat.len > 0)
        try std.fmt.allocPrint(arena, "Last lesson: green clean · amber slow · red missed{s}{s} · clears on your first key", .{
            if (mark_holds) " · teal dashed became a hold" else "",
            if (mark_taps) " · amber dashed came as a tap" else "",
        })
    else
        try std.fmt.allocPrint(arena, "{s} · {s}", .{ source_title, frame.profile });
    const dim_locked = !is_test_keys and (owner.config.stage == .home_row or owner.config.stage == .all_letters);

    try keyboard_view.draw(theme, bounds, .{
        .mode = owner.config.mode,
        .profile = if (owner.profile_bound) &owner.profile else null,
        .geometry = frame.geometry,
        .labels = labels,
        .layer = layer,
        .active_layers = active,
        .modifiers = mods,
        .pressed = frame.pressed,
        .stale = frame.stale,
        .show_guidance = guided,
        .unlocked_mask = owner.learning.unlockedMask(),
        .dim_locked = dim_locked,
        .hint = if (guided) resolved_hint else null,
        .tap_targets = tap,
        .hold_targets = hold,
        .one_shot_targets = one_shot,
        .hold_source_layer = hold_source_layer,
        .combo_output_cp = if (guided and resolved_hint != null and resolved_hint.?.combo_key != null and focus < owner.session.reference_len)
            owner.session.reference[focus]
        else
            null,
        .error_flash_key = flash_key,
        .heat = heat,
        .marks = marks,
        .source_caption = src_caption,
        .layer_name = frame.layer_name,
        .wide_caption = mark_holds or mark_taps,
    });
}

/// How each key of the last lesson went, shown until the next lesson's first
/// keystroke: missed at least once, slower than the target, or clean.
fn lessonHeat(arena: std.mem.Allocator, owner: *const control.Controller, key_count: usize, layer: usize) ![]const keyboard_view.HeatKey {
    if (owner.config.mode != .tutor or owner.session.state != .ready or !owner.profile_bound) return &.{};
    const lesson = owner.last_lesson orelse return &.{};
    const target_ms = 12_000.0 / owner.config.target_wpm;
    var out: std.ArrayList(keyboard_view.HeatKey) = .empty;
    for (lesson.keySlice()) |key| {
        const route = owner.profile.routeFor(key.cp) orelse continue;
        if (route.layer != layer or route.key_index >= key_count) continue;
        const heat: keyboard_view.Heat = if (key.misses > 0)
            .missed
        else if (key.ms > target_ms)
            .slow
        else
            .clean;
        try out.append(arena, .{ .key_index = route.key_index, .heat = heat });
    }
    return out.items;
}

/// Call while the practice screen is not shown, so Test layout captures its
/// field again when it opens.
pub fn hidden(view: *View) void {
    view.test_field.capture_on_show = true;
}

/// Pauses a run when the window loses focus.
fn trackWindowFocus(owner: *control.Controller, view: *View, input: Input) void {
    if (running(owner)) if (view.was_focused) |previous| {
        if (previous and !input.window_focused) owner.pause(input.now_us);
    };
    view.was_focused = input.window_focused;
}

/// What the typing card says instead of the generic pause note.
fn statusNote(owner: *const control.Controller, input: Input) []const u8 {
    if (owner.failure) |failure| if (failure == error.PracticeContextChanged)
        return "Input source changed · start a fresh exercise";
    return input.diagnostic;
}

pub fn apply(owner: *control.Controller, view: *View, rendered: control.Action, input: Input) !void {
    try owner.dispatch(rendered, input.now_us);
    switch (rendered.intent) {
        .start, .new_exercise, .set_stage, .start_weak_spot, .reset_progress, .reset_keys, .resolve_layout_changes, .practise_key => {
            view.scroll.at = null;
            view.drawn_len = 0;
            view.sheet = .none;
            view.picks = .{};
        },
        .keep_moved_keys => {
            if (view.sheet == .layout_changes) view.sheet = .none;
            view.picks = .{};
        },
        .set_mode => {
            view.sheet = .none;
            view.settings_open = false;
            view.people.close();
        },
        else => {},
    }
}
