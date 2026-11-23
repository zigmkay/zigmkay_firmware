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

const control = desktop.practice_controller;
const storage = desktop.practice_storage;

pub const Sheet = sheets_ui.Sheet;

pub const Frame = struct {
    /// Live frames must come from the coherent identity-checked session adapter.
    source: enum { draft, simulated, live },
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
};

pub const Input = struct {
    now_us: u64,
    window_focused: bool = false,
    owns_input: bool = false,
    prepared_snapshot: ?control.Digest = null,
    frame: ?Frame = null,
    resources: geometry.Resources = .{},
    fixture: bool = false,
    diagnostic: []const u8 = "",
    event_times: []const desktop.practice.EventTime = &.{},
    runs: []const storage.RunRecord = &.{},
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
    custom_text_buf: [256]u8 = @splat(0),
    custom_text_seeded: bool = false,
    last_pressed_error_key: ?usize = null,
    last_error_flash_us: u64 = 0,
    same_hand_shift_until_us: u64 = 0,
};

pub const DrawResult = struct {
    leave: bool = false,
    input_effect: control.Effect = .{},
    action: ?control.Action = null,
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

fn insertText(owner: *control.Controller, effect: *control.Effect, text: []const u8, at: u64, paste: bool) !void {
    const inserted = try owner.insertOs(true, text, at, paste);
    effect.reset_text = inserted.reset_text or effect.reset_text;
}

/// Continue keys arriving this soon after the last keystroke of a round are ignored.
const rundown_settle_us: u64 = 300_000;

fn consumeInput(
    owner: *control.Controller,
    view: *View,
    data: *dvui.WidgetData,
    input: Input,
    pending: *?control.Intent,
) !control.Effect {
    var effect: control.Effect = .{};
    if (!input.owns_input or !input.window_focused) return effect;
    if (view.sheet != .none or view.settings_open) {
        // Esc closes any open sheet or settings popover cleanly.
        for (dvui.events()) |*event| {
            if (event.handled) continue;
            if (event.evt == .key and event.evt.key.action != .up and event.evt.key.code == .escape) {
                view.sheet = .none;
                view.settings_open = false;
                view.confirm_reset = false;
                event.handle(@src(), data);
            }
        }
        return effect;
    }

    if (owner.config.mode == .test_keys) {
        dvui.wantTextInput(data.borderRectScale().r.toNatural());
        for (dvui.events()) |*event| {
            if (event.handled) continue;
            switch (event.evt) {
                .text => |text| {
                    if (text.action == .value and !text.action.value.selected) {
                        owner.test_keys.setLastText(text.action.value.txt);
                        owner.test_keys.appendScratchpad(text.action.value.txt);
                        event.handle(@src(), data);
                    }
                },
                .key => |key| {
                    if (key.action != .up) {
                        if (key.matchBind("paste")) {
                            const clip = dvui.clipboardText();
                            if (clip.len > 0) {
                                owner.test_keys.setLastText(clip);
                                owner.test_keys.appendScratchpad(clip);
                            }
                            event.handle(@src(), data);
                        } else if (!key.mod.control() and !key.mod.command()) {
                            switch (key.code) {
                                .backspace => {
                                    owner.test_keys.backspaceScratchpad();
                                    event.handle(@src(), data);
                                },
                                .enter => {
                                    owner.test_keys.appendScratchpad("\n");
                                    event.handle(@src(), data);
                                },
                                .tab => {
                                    owner.test_keys.appendScratchpad("    ");
                                    event.handle(@src(), data);
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
        }
        return effect;
    }

    // Inline Rundown keyboard-only continuation: Enter or Space starts the next
    // round. A habitual trailing Space right after the last letter is swallowed
    // so the rundown stays visible.
    if (owner.session.state == .complete) {
        const completed_at = owner.session.last_event_us orelse 0;
        const settled = input.now_us -| completed_at >= rundown_settle_us;
        for (dvui.events()) |*event| {
            if (event.handled) continue;
            switch (event.evt) {
                .key => |key| {
                    if (key.action != .up and (key.code == .enter or key.code == .space)) {
                        if (settled and pending.* == null) pending.* = .next_round;
                        event.handle(@src(), data);
                    }
                },
                .text => |text| {
                    if (text.action == .value and std.mem.eql(u8, text.action.value.txt, " ")) {
                        if (settled and pending.* == null) pending.* = .next_round;
                        event.handle(@src(), data);
                    }
                },
                else => {},
            }
        }
        return effect;
    }

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
        return effect;
    }

    if (!owner.acceptingOsText(true)) return effect;
    dvui.wantTextInput(data.borderRectScale().r.toNatural());
    const prev_errors = owner.session.error_count;
    for (dvui.events()) |*event| {
        if (event.handled) continue;
        const at = nativeEventTime(input.event_times, event.num) orelse input.now_us;
        switch (event.evt) {
            .text => |text| {
                if (text.action == .value and !text.action.value.selected) {
                    try insertText(owner, &effect, text.action.value.txt, at, false);
                }
                event.handle(@src(), data);
            },
            .key => |key| {
                if (key.action != .up) try handleKey(owner, &effect, key, at, pending);
                event.handle(@src(), data);
            },
            else => {},
        }
    }

    // Track physical mis-key flash when Live-HID has a pressed key on mismatch.
    if (owner.session.error_count > prev_errors) {
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
    return effect;
}

fn handleKey(
    owner: *control.Controller,
    effect: *control.Effect,
    key: dvui.Event.Key,
    at: u64,
    pending: *?control.Intent,
) !void {
    if (key.matchBind("paste")) return insertText(owner, effect, dvui.clipboardText(), at, true);
    if (key.mod.control() or key.mod.command()) return;
    const is_zig = owner.config.stage == .free_text and owner.config.stage6_source == .zig_code;
    switch (key.code) {
        .backspace => owner.session.backspace(),
        .tab => {
            if (is_zig) {
                try insertText(owner, effect, "    ", at, false);
            } else if (pending.* == null) {
                pending.* = .new_exercise;
            }
        },
        .enter => try insertText(owner, effect, "\n", at, false),
        .escape => effect.reset_text = owner.pause(at).reset_text or effect.reset_text,
        else => {},
    }
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

    const focus_effect = trackWindowFocus(owner, view, input);
    var pending: ?control.Intent = null;
    var input_effect = try consumeInput(owner, view, root.data(), input, &pending);
    if (focus_effect.runner != .none or focus_effect.reset_text) input_effect = focus_effect;

    // 1. Unified Editor-style Top Bar (64px height matching Editor toolbar scale)
    const topbar_h: f32 = 64;
    const leave = try drawTopBar(owner, view, theme, .{ .x = 0, .y = 0, .w = size.w, .h = topbar_h }, input, &pending);

    // 2. Centered Workspace (Editor-proportioned width for readable fonts & full keyboard)
    const max_content_w: f32 = 1440;
    const pad_x: f32 = @max(18.0, (size.w - max_content_w) * 0.5);
    const content_w = @max(280.0, size.w - pad_x * 2);
    const work_top = topbar_h + 14;
    const work_h = @max(200.0, size.h - work_top - 16);

    if (owner.config.mode == .test_keys) {
        try drawTestKeysWorkspace(owner, view, theme, .{ .x = pad_x, .y = work_top, .w = content_w, .h = work_h }, input, &pending);
    } else {
        try drawTutorWorkspace(owner, view, theme, .{ .x = pad_x, .y = work_top, .w = content_w, .h = work_h }, input, &pending);
    }

    // 3. Secondary Sheets (Stages / Progress) and compact Settings popover
    try sheets_ui.drawSheet(owner, &view.sheet, theme, .{
        .board_name = if (input.frame) |f| f.board_name else "",
        .profile_name = if (input.frame) |f| f.profile else "",
        .labels = if (input.frame) |f| f.labels else null,
        .runs = input.runs,
        .custom_text_buf = &view.custom_text_buf,
        .custom_text_seeded = &view.custom_text_seeded,
    }, &pending);
    try sheets_ui.drawSettingsPopover(owner, &view.settings_open, &view.confirm_reset, theme, size.w - 16, topbar_h + 6, &pending);

    view.drawn_len = owner.session.len;
    return .{
        .leave = leave,
        .input_effect = input_effect,
        .action = if (pending) |intent| owner.action(intent) else null,
    };
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
    const right_fixed_w: f32 = if (owner.config.mode == .tutor) 18 + 38 + 130 + 104 + 12 else 18 + 38 + 104 + 12;
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
    if (rx - status_pill_w - 14 >= lx) {
        const is_live = input.frame != null and input.frame.?.source == .live and !input.frame.?.stale;
        rx -= status_pill_w + 10;
        if (is_live) {
            ui.runningBadge(theme, .{ .x = rx, .y = y + 6, .w = status_pill_w, .h = 26 }, 0x9100);
        } else {
            const pill_text = if (owner.config.source == .draft) "Unflashed draft" else "Draft preview";
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
    try presentation.confidenceStrip(owner, theme, .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = conf_h });

    // Resolve active hint once for both typing-card footer and keyboard overlay
    var resolved_hint: ?desktop.practice.Hint = null;
    if (input.frame) |frame| {
        if (running(owner) and focus < owner.session.reference_len) {
            const layer = @min(frame.layer, frame.labels.layer_count - 1);
            resolved_hint = try desktop.practice.hintWithProfile(
                if (owner.profile_bound) &owner.profile else null,
                frame.labels.practiceLabels(),
                layer,
                frame.modifiers.toByte(),
                owner.session.reference[focus],
                frame.active_layers,
            );
        }
    }

    // 2. Calm Typing Card (middle) + Physical Tap/Hold Keyboard (bottom)
    const rem_y = bounds.y + conf_h + gap;
    const rem_h = @max(180.0, bounds.h - conf_h - gap);
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
        runnerStatus(owner, input),
        shift_nudge,
        pending,
    );

    if (show_kb) {
        const kb_y = rem_y + card_h + gap;
        const kb_h = @max(110.0, bounds.y + bounds.h - kb_y);
        try drawKeyboardArea(owner, view, theme, .{ .x = bounds.x, .y = kb_y, .w = bounds.w, .h = kb_h }, focus, resolved_hint, input);
    }
}

fn drawTestKeysWorkspace(
    owner: *control.Controller,
    view: *View,
    theme: ui.Theme,
    bounds: dvui.Rect,
    input: Input,
    pending: *?control.Intent,
) !void {
    const gap: f32 = 12;
    const bar_h: f32 = 54;
    const layer = if (input.frame) |f| f.layer else owner.test_keys.highest_layer;
    const layer_name = if (input.frame) |f| f.layer_name else "";
    const mods = if (input.frame) |f| f.modifiers.toByte() else owner.test_keys.modifiers;

    try presentation.testKeysTelemetryBar(
        owner,
        theme,
        .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bar_h },
        layer,
        layer_name,
        mods,
        pending,
    );

    const rem_y = bounds.y + bar_h + gap;
    const rem_h = @max(220.0, bounds.h - bar_h - gap);
    const scratch_h: f32 = std.math.clamp(rem_h * 0.24, 124.0, 168.0);
    try presentation.testLayoutScratchpad(
        owner,
        theme,
        .{ .x = bounds.x, .y = rem_y, .w = bounds.w, .h = scratch_h },
    );

    const kb_y = rem_y + scratch_h + gap;
    const kb_h = @max(160.0, bounds.y + bounds.h - kb_y);
    try drawKeyboardArea(owner, view, theme, .{ .x = bounds.x, .y = kb_y, .w = bounds.w, .h = kb_h }, 0, null, input);
}

fn drawKeyboardArea(
    owner: *const control.Controller,
    view: *View,
    theme: ui.Theme,
    bounds: dvui.Rect,
    focus: usize,
    resolved_hint: ?desktop.practice.Hint,
    input: Input,
) !void {
    view.drawn_keyboard = input.frame != null;
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
        presentation.caption("Waiting for verified keyboard layout telemetry…", .{ .x = 16, .y = 0, .w = bounds.w - 32, .h = bounds.h }, 15, theme.muted, "practice.keyboard.source");
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
        if (frame.source == .draft or h.layer != layer) {
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
        .simulated => "Draft simulation",
        .draft => if (is_test_keys) "Draft layout" else "Layout guide",
    };
    const src_caption = try std.fmt.allocPrint(arena, "{s} · {s}", .{ source_title, frame.profile });
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
        .source_caption = src_caption,
        .layer_name = frame.layer_name,
    });
}

/// Pauses a run when the window loses focus.
fn trackWindowFocus(owner: *control.Controller, view: *View, input: Input) control.Effect {
    var effect: control.Effect = .{};
    if (running(owner)) if (view.was_focused) |previous| {
        if (previous and !input.window_focused) effect = owner.pause(input.now_us);
    };
    view.was_focused = input.window_focused;
    return effect;
}

fn runnerStatus(owner: *const control.Controller, input: Input) []const u8 {
    const diagnostic = if (owner.failure) |failure| switch (failure) {
        error.PracticeContextChanged => "Input source changed · start a fresh exercise",
        error.DraftChangedRestartPractice => "Draft changed · restart the exercise",
        error.DraftPreparationFailed => "Draft preparation failed · retry with Resume",
        error.RunnerArtifactNotPrepared => "Build the current draft before starting practice",
        error.StaleBuild => "Build the current draft before starting practice",
        error.RunnerArtifactChanged => "The prepared draft runner changed · rebuild the draft",
        error.RunnerHostMismatch => "This draft runner was built for another system",
        error.HostMappingUnavailable => "Draft practice has no host key mapping for this board",
        else => input.diagnostic,
    } else input.diagnostic;
    if (owner.config.source != .draft or !owner.active) return diagnostic;
    return switch (owner.runner_state) {
        .preparing => "Preparing the current draft…",
        .prepared => "Draft ready · press Resume",
        .stopping => "Stopping draft practice…",
        .idle => "Build the current draft, then press Resume",
        .failed => if (diagnostic.len != 0) diagnostic else "Draft practice failed · build or retry",
        .stale => "Draft changed · restart the exercise",
        .running => diagnostic,
    };
}

pub fn apply(owner: *control.Controller, view: *View, rendered: control.Action, input: Input) !control.Effect {
    const effect = try owner.dispatch(rendered, input.prepared_snapshot, input.now_us);
    switch (rendered.intent) {
        .start, .new_exercise, .next_round, .set_stage, .start_weak_spot, .reset_progress => {
            view.scroll.at = null;
            view.drawn_len = 0;
            view.sheet = .none;
        },
        .set_mode => {
            view.sheet = .none;
            view.settings_open = false;
        },
        else => {},
    }
    return effect;
}
