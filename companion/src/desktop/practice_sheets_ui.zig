//! Secondary Tutor sheets (6-Stage Learning Path & Progress with native vector
//! WPM trend chart) plus compact Settings popover. Strictly 2 sheets max.
//! Uses 100% `ui.Theme` / `ui.layerColor` / `ui.mix` tokens.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");

const control = desktop.practice_controller;
const generator = desktop.practice_generator;
const storage = desktop.practice_storage;
const lp = desktop.practice_layout_profile;
const model = desktop.practice_model;
const presentation = @import("practice_presentation.zig");
const key_change = @import("practice_key_change_ui.zig");
const tap_hold_ui = @import("practice_tap_hold_ui.zig");
const layout = @import("layout-model");

/// A keyboard of the board catalog, for showing where a key used to be.
pub const BoardInfo = struct {
    name: []const u8,
    geometry: []const layout.physical_layout.Key,
};

pub const BoardLookup = *const fn (board_id: []const u8) ?BoardInfo;

pub const Sheet = enum { none, stages, progress, layout_changes, reset_keys };

pub const SheetContext = struct {
    board_name: []const u8 = "",
    profile_name: []const u8 = "",
    labels: ?*const desktop.label_cache.LabelCache = null,
    runs: []const storage.RunRecord = &.{},
    custom_text_buf: *[256]u8,
    custom_text_seeded: *bool,
    /// The current keyboard.
    geometry: []const layout.physical_layout.Key = &.{},
    board_lookup: ?BoardLookup = null,
    picks: *Picks,
    /// Where the Progress sheet is scrolled.
    progress_scroll: ?*dvui.ScrollInfo = null,
    /// Set to scroll the Progress sheet to its tap/hold section; cleared once done.
    focus_tap_hold: ?*bool = null,
    /// Receives the key a tapping term suggestion asks the editor to open.
    edit_key: ?*?tap_hold_ui.EditKey = null,
    /// Whether a suggestion may open the editor.
    can_edit: bool = false,
};

/// Draws whichever secondary sheet is open, if any.
pub fn drawSheet(
    owner: *control.Controller,
    sheet: *Sheet,
    theme: ui.Theme,
    ctx: SheetContext,
    pending: *?control.Intent,
) !void {
    switch (sheet.*) {
        .none => return,
        .stages => try drawStagesSheet(owner, sheet, theme, ctx, pending),
        .progress => try drawProgressSheet(owner, sheet, theme, ctx, pending),
        .layout_changes => try drawLayoutChangesSheet(owner, sheet, theme, ctx, pending),
        .reset_keys => try drawResetKeysSheet(owner, sheet, theme, ctx, pending),
    }
}

/// Compact floating Settings popover anchored under the top-right gear button.
/// Returns whether the Reset characters sheet was asked for.
pub fn drawSettingsPopover(
    owner: *const control.Controller,
    open: *bool,
    confirm_reset: *bool,
    theme: ui.Theme,
    anchor_right: f32,
    anchor_top: f32,
    pending: *?control.Intent,
) !bool {
    if (!open.*) return false;
    const pop_w: f32 = 324;
    const pop_h: f32 = if (confirm_reset.*) 386 else 360;
    const screen = dvui.windowRect();
    const x = std.math.clamp(anchor_right - pop_w, 12.0, @max(12.0, screen.w - pop_w - 12.0));
    const y = std.math.clamp(anchor_top, 12.0, @max(12.0, screen.h - pop_h - 12.0));

    var fw = dvui.floatingWindow(@src(), .{ .modal = false, .open_flag = open }, .{
        .rect = .{ .x = x, .y = y, .w = pop_w, .h = pop_h },
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .tag = "practice.settings.popover",
    });
    defer fw.deinit();

    const arena = dvui.currentWindow().arena();
    const pad: f32 = 16;
    const inner_w = pop_w - pad * 2;

    // Header
    boldLabel("Tutor settings", .{ .x = pad, .y = 11, .w = inner_w - 30, .h = 22 }, 15, theme.text, 0xa000);
    if (ui.iconButton(theme, ui.control_icons.remove, "", "practice.settings.close", .{ .x = pop_w - 38, .y = 9, .w = 26, .h = 26 }, false)) {
        open.* = false;
        confirm_reset.* = false;
        return false;
    }
    ui.divider(theme, .{ .x = 0, .y = 42, .w = pop_w, .h = 1 }, 0xa001);

    // 1. Target speed (WPM presets)
    var cy: f32 = 52;
    const wpm_title = try std.fmt.allocPrint(arena, "Target speed: {d:.0} WPM", .{owner.config.target_wpm});
    presentation.label(wpm_title, .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 13, theme.muted, null);
    cy += 23;
    const wpm_presets = control.target_presets;
    const pw = (inner_w - 16) / 5.0;
    for (wpm_presets, 0..) |preset, i| {
        const active = @abs(owner.config.target_wpm - preset) < 0.5;
        const lbl = try std.fmt.allocPrint(arena, "{d:.0}", .{preset});
        if (pillButton(theme, lbl, .{ .x = pad + @as(f32, @floatFromInt(i)) * (pw + 4), .y = cy, .w = pw, .h = 28 }, active, 0xa100 + i) and pending.* == null) {
            pending.* = .{ .set_target_wpm = preset };
        }
    }
    cy += 38;

    // 2. Daily goal (minutes)
    presentation.label("Daily goal", .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 13, theme.muted, null);
    cy += 23;
    const goals = [_]u16{ 5, 10, 15, 30 };
    const gw = (inner_w - 12) / 4.0;
    for (goals, 0..) |mins, i| {
        const active = owner.config.daily_goal_minutes == mins;
        const lbl = try std.fmt.allocPrint(arena, "{d} min", .{mins});
        if (pillButton(theme, lbl, .{ .x = pad + @as(f32, @floatFromInt(i)) * (gw + 4), .y = cy, .w = gw, .h = 28 }, active, 0xa200 + i) and pending.* == null) {
            pending.* = .{ .set_daily_goal = mins };
        }
    }
    cy += 38;

    // 3. Guidance mode
    presentation.label("Keyboard guidance", .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 13, theme.muted, null);
    cy += 23;
    const gmodes = [_]struct { m: storage.GuidanceMode, lbl: []const u8 }{
        .{ .m = .guided, .lbl = "Guided" },
        .{ .m = .on_hesitation, .lbl = "On hesitation" },
        .{ .m = .free, .lbl = "Free" },
    };
    const gmw = (inner_w - 8) / 3.0;
    for (gmodes, 0..) |gm, i| {
        const active = owner.config.guidance == gm.m;
        if (pillButton(theme, gm.lbl, .{ .x = pad + @as(f32, @floatFromInt(i)) * (gmw + 4), .y = cy, .w = gmw, .h = 28 }, active, 0xa300 + i) and pending.* == null) {
            pending.* = .{ .set_guidance = gm.m };
        }
    }
    cy += 38;

    // 4. How typos are handled
    presentation.label("Typos", .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 13, theme.muted, null);
    cy += 23;
    const emodes = [_]struct { m: control.ErrorMode, lbl: []const u8 }{
        .{ .m = .forgive, .lbl = "Forgiving" },
        .{ .m = .stop_on_error, .lbl = "Stop on error" },
    };
    const emw = (inner_w - 4) / 2.0;
    for (emodes, 0..) |em, i| {
        const active = owner.config.error_mode == em.m;
        if (pillButton(theme, em.lbl, .{ .x = pad + @as(f32, @floatFromInt(i)) * (emw + 4), .y = cy, .w = emw, .h = 28 }, active, 0xa400 + i) and pending.* == null) {
            pending.* = .{ .set_error_mode = em.m };
        }
    }
    cy += 38;

    // 5. Reset single characters, then the whole profile (two-step confirmation)
    ui.divider(theme, .{ .x = pad, .y = cy - 6, .w = inner_w, .h = 1 }, 0xa002);
    var reset_keys = false;
    if (ui.button(theme, "Reset characters…", "practice.settings.reset_keys", .{ .x = pad, .y = cy + 4, .w = inner_w, .h = 30 })) {
        reset_keys = true;
        open.* = false;
        confirm_reset.* = false;
    }
    cy += 40;
    if (!confirm_reset.*) {
        if (ui.dangerButton(theme, null, "Reset profile progress", "practice.settings.reset", .{ .x = pad, .y = cy + 4, .w = inner_w, .h = 30 })) {
            confirm_reset.* = true;
        }
    } else {
        presentation.label("Clear all stats & round history?", .{ .x = pad, .y = cy + 1, .w = inner_w, .h = 18 }, 12.5, theme.danger, null);
        const bw = (inner_w - 6) / 2.0;
        if (ui.dangerButton(theme, null, "Confirm reset", "practice.settings.confirm_reset", .{ .x = pad, .y = cy + 24, .w = bw, .h = 30 }) and pending.* == null) {
            pending.* = .reset_progress;
            confirm_reset.* = false;
            open.* = false;
        }
        if (ui.button(theme, "Cancel", "practice.settings.cancel_reset", .{ .x = pad + bw + 6, .y = cy + 24, .w = bw, .h = 30 })) {
            confirm_reset.* = false;
        }
    }
    return reset_keys;
}

fn drawStagesSheet(
    owner: *control.Controller,
    sheet: *Sheet,
    theme: ui.Theme,
    ctx: SheetContext,
    pending: *?control.Intent,
) !void {
    const screen = dvui.windowRect();
    const w: f32 = @min(@as(f32, 920), screen.w - 40);
    const pad: f32 = 24;
    const grid_top: f32 = 120;
    const narrow = w < 680;
    const cols: usize = if (narrow) 2 else 3;
    const rows: usize = if (narrow) 3 else 2;
    const gap: f32 = 12;
    const card_w = (w - pad * 2 - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const card_h: f32 = 124;

    const show_s5 = owner.config.stage == .layers_combos;
    const show_s6 = owner.config.stage == .free_text;
    const footer_h: f32 = if (show_s6) 106 else if (show_s5) 60 else 44;
    const grid_h = @as(f32, @floatFromInt(rows)) * card_h + @as(f32, @floatFromInt(rows - 1)) * gap;
    const content_h = grid_top + grid_h + 16 + footer_h;
    const h: f32 = @min(content_h, screen.h - 40);

    var fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .rect = .{ .x = (screen.w - w) * 0.5, .y = (screen.h - h) * 0.5, .w = w, .h = h },
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(14),
        .tag = "practice.sheet.stages",
    });
    defer fw.deinit();

    // Elevated header strip matching Mockup 3 surface hierarchy
    const header_bg = dvui.box(@src(), .{}, .{
        .id_extra = 0xb090,
        .rect = .{ .x = 1, .y = 1, .w = w - 2, .h = 99 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .corners = ui.topCorners(13),
        .padding = .{},
        .margin = .{},
    });
    header_bg.deinit();

    const arena = dvui.currentWindow().arena();
    const subtitle = try std.fmt.allocPrint(arena, "Derived from {s} · Any stage freely selectable", .{
        if (ctx.profile_name.len > 0) ctx.profile_name else "your active layout",
    });
    if (ui.sheetHeader(theme, w, "6-Stage Learning Path", subtitle, "practice.sheet.close")) {
        sheet.* = .none;
        return;
    }

    const lm = &owner.learning;
    const prof = if (owner.profile_bound) &owner.profile else null;
    const home_mastered = isHomeRowMastered(owner);
    const all_letters_mastered = lm.unlock_len > 0 and lm.unlocked_count >= lm.unlock_len and
        (lm.focus_cp == null or lm.confidenceFor(lm.focus_cp.?) >= 1.0);
    const recommended: generator.Stage = if (!home_mastered)
        .home_row
    else if (!all_letters_mastered)
        .all_letters
    else
        .shift;

    const all_stages = [_]generator.Stage{
        .home_row, .all_letters, .shift, .punctuation_numbers, .layers_combos, .free_text,
    };

    for (all_stages, 0..) |st, i| {
        const col = i % cols;
        const row = i / cols;
        const rx = pad + @as(f32, @floatFromInt(col)) * (card_w + gap);
        const ry = grid_top + @as(f32, @floatFromInt(row)) * (card_h + gap);
        const rect: dvui.Rect = .{ .x = rx, .y = ry, .w = card_w, .h = card_h };

        const is_active = owner.config.stage == st and !owner.config.weak_spot_active;
        const is_done = (st == .home_row and home_mastered) or (st == .all_letters and all_letters_mastered);
        const is_rec = (st == recommended and !is_active);
        const accent_col = stageAccentColor(theme, st);

        const fill = if (is_active)
            ui.mix(theme.panel, theme.accent, 0.15)
        else if (is_done)
            ui.mix(theme.panel, theme.success, 0.09)
        else
            theme.panel;
        const border = if (is_active)
            theme.accent
        else if (is_done)
            ui.mix(theme.panel, theme.success, 0.50)
        else
            theme.border;

        const clicked = dvui.button(@src(), "", .{}, .{
            .id_extra = 0xb000 + i,
            .tag = try std.fmt.allocPrint(arena, "practice.stage.{d}", .{st.number()}),
            .rect = rect,
            .background = true,
            .color_fill = .{ .color = fill },
            .color_fill_hover = .{ .color = ui.mix(fill, theme.text, 0.05) },
            .color_fill_press = .{ .color = ui.mix(fill, theme.text, 0.11) },
            .color_border = .{ .color = border },
            .border = .all(if (is_active) 1.6 else 1),
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        if (clicked and pending.* == null) {
            pending.* = .{ .set_stage = st };
            sheet.* = .none;
        }

        const cx = rx + 14;
        const cw = card_w - 28;

        // Top row: STAGE N + right-aligned status badge
        const num_str = try std.fmt.allocPrint(arena, "STAGE {d}", .{st.number()});
        boldLabel(num_str, .{ .x = cx, .y = ry + 11, .w = 78, .h = 16 }, 11.5, theme.muted, 0xb080 + i);

        const state_str: []const u8 = if (is_active and st == .all_letters and lm.unlock_len > 0)
            try std.fmt.allocPrint(arena, "● Active · {d}/{d}", .{ lm.unlocked_count, lm.unlock_len })
        else if (is_active)
            "● Active"
        else if (is_done)
            "✓ Mastered"
        else if (is_rec)
            "★ Recommended"
        else
            "Ready";
        const state_col: dvui.Color = if (is_active)
            theme.accent
        else if (is_done)
            theme.success
        else if (is_rec)
            theme.warning
        else
            theme.muted;
        dvui.labelNoFmt(@src(), state_str, .{ .align_x = 1, .align_y = 0.5 }, .{
            .id_extra = 0xb100 + i,
            .rect = .{ .x = cx + 78, .y = ry + 11, .w = @max(40, cw - 78), .h = 16 },
            .font = ui.editorFont(state_str, 11.5).withWeight(.bold),
            .color_text = .{ .color = state_col },
            .padding = .{},
            .margin = .{},
        });

        // Stage title + wrapped 2-line layout-derived description
        boldLabel(st.shortName(), .{ .x = cx, .y = ry + 32, .w = cw, .h = 22 }, 15.5, theme.text, 0xb140 + i);
        const desc = try stageDescription(arena, owner, prof, ctx.labels, st);
        drawWrappedTwoLines(desc, .{ .x = cx, .y = ry + 57, .w = cw, .h = 34 }, 12.5, theme.muted, 17, 0xb180 + i * 2);

        // Sleek bottom progress bar
        const prog = stageProgress(owner, st, home_mastered);
        const bar_y = ry + card_h - 15;
        const track = dvui.box(@src(), .{}, .{
            .id_extra = 0xb200 + i,
            .rect = .{ .x = cx, .y = bar_y, .w = cw, .h = 4.5 },
            .background = true,
            .color_fill = .{ .color = theme.control },
            .corners = .all(2.25),
            .padding = .{},
            .margin = .{},
        });
        track.deinit();
        if (prog > 0.01) {
            const pfill = dvui.box(@src(), .{}, .{
                .id_extra = 0xb300 + i,
                .rect = .{ .x = cx, .y = bar_y, .w = @max(6.0, cw * prog), .h = 4.5 },
                .background = true,
                .color_fill = .{ .color = if (is_done) theme.success else accent_col },
                .corners = .all(2.25),
                .padding = .{},
                .margin = .{},
            });
            pfill.deinit();
        }
    }

    // Contextual footer: compact hint for Stages 1-4, targeted controls when Stage 5 or Stage 6 is active.
    const foot_top = grid_top + grid_h + 16;
    ui.divider(theme, .{ .x = pad, .y = foot_top, .w = w - pad * 2, .h = 1 }, 0xb400);

    if (show_s5) {
        const opt_y = foot_top + 14;
        presentation.label("Stage 5 mode:", .{ .x = pad, .y = opt_y + 2, .w = 100, .h = 26 }, 13, theme.muted, null);
        var px = pad + 104;
        if (pillButton(theme, "Mixed", .{ .x = px, .y = opt_y, .w = 68, .h = 28 }, owner.config.stage5_filter == .mixed, 0xb501) and pending.* == null) {
            pending.* = .{ .set_stage5_filter = .{ .filter = .mixed, .layer = null } };
            sheet.* = .none;
        }
        px += 74;
        if (pillButton(theme, "Combos", .{ .x = px, .y = opt_y, .w = 78, .h = 28 }, owner.config.stage5_filter == .combos_only, 0xb502) and pending.* == null) {
            pending.* = .{ .set_stage5_filter = .{ .filter = .combos_only, .layer = null } };
            sheet.* = .none;
        }
        px += 84;

        var layers_buf: [4]usize = undefined;
        const sym_layers = collectSymbolLayers(prof, &layers_buf);
        const display_layers: []const usize = if (sym_layers.len > 0) sym_layers else &.{1};
        for (display_layers, 0..) |layer_idx, li| {
            const lbl = try std.fmt.allocPrint(arena, "Layer {d}", .{layer_idx});
            const active = owner.config.stage5_filter == .specific_layer and owner.config.stage5_layer == layer_idx;
            if (px + 74 > w - pad) break;
            if (pillButton(theme, lbl, .{ .x = px, .y = opt_y, .w = 74, .h = 28 }, active, 0xb510 + li) and pending.* == null) {
                pending.* = .{ .set_stage5_filter = .{ .filter = .specific_layer, .layer = @intCast(layer_idx) } };
                sheet.* = .none;
            }
            px += 80;
        }
    } else if (show_s6) {
        const opt_y = foot_top + 14;
        presentation.label("Stage 6 source:", .{ .x = pad, .y = opt_y + 2, .w = 108, .h = 26 }, 13, theme.muted, null);
        const sx = pad + 112;
        if (pillButton(theme, "Prose", .{ .x = sx, .y = opt_y, .w = 68, .h = 28 }, owner.config.stage6_source == .english_prose, 0xb601) and pending.* == null) {
            pending.* = .{ .set_stage6_source = .{ .source = .english_prose } };
            sheet.* = .none;
        }
        if (pillButton(theme, "Zig code", .{ .x = sx + 74, .y = opt_y, .w = 82, .h = 28 }, owner.config.stage6_source == .zig_code, 0xb602) and pending.* == null) {
            pending.* = .{ .set_stage6_source = .{ .source = .zig_code, .zig_lesson = owner.config.zig_lesson_index } };
            sheet.* = .none;
        }
        if (pillButton(theme, "Custom", .{ .x = sx + 162, .y = opt_y, .w = 76, .h = 28 }, owner.config.stage6_source == .custom_text, 0xb603) and pending.* == null) {
            if (ctx.custom_text_buf[0] != 0) {
                owner.setCustomText(std.mem.sliceTo(ctx.custom_text_buf, 0));
            }
            pending.* = .{ .set_stage6_source = .{ .source = .custom_text } };
            sheet.* = .none;
        }

        const custom_y = opt_y + 40;
        if (!ctx.custom_text_seeded.*) {
            ctx.custom_text_buf.* = @splat(0);
            const n = @min(owner.custom_text_len, ctx.custom_text_buf.len - 1);
            @memcpy(ctx.custom_text_buf[0..n], owner.custom_text[0..n]);
            ctx.custom_text_seeded.* = true;
        }
        const btn_w: f32 = 122;
        var te_opts = ui.options(theme, .{ .x = pad, .y = custom_y, .w = @max(120, w - pad * 2 - btn_w - 8), .h = 32 }, 13);
        te_opts.border = .all(1);
        te_opts.corners = .all(7);
        te_opts.color_fill = .{ .color = theme.panel };
        te_opts.tag = "practice.sheet.custom_text";
        const te = dvui.textEntry(@src(), .{ .text = .{ .buffer = ctx.custom_text_buf }, .placeholder = "Paste custom text for Stage 6…" }, te_opts);
        const submitted = te.enter_pressed;
        te.deinit();
        const use_clicked = ui.button(theme, "Practice text", "practice.sheet.use_custom", .{ .x = w - pad - btn_w, .y = custom_y, .w = btn_w, .h = 32 });
        if ((submitted or use_clicked) and pending.* == null) {
            owner.setCustomText(std.mem.sliceTo(ctx.custom_text_buf, 0));
            pending.* = .{ .set_stage6_source = .{ .source = .custom_text } };
            sheet.* = .none;
        }
    } else {
        // Which letters Stages 1 and 2 bring in first.
        const opt_y = foot_top + 10;
        presentation.label("Letter order:", .{ .x = pad, .y = opt_y + 1, .w = 96, .h = 26 }, 13, theme.muted, null);
        const ox = pad + 100;
        const words_w: f32 = 150;
        const home_w: f32 = 124;
        if (pillButton(theme, "Word-forming first", .{ .x = ox, .y = opt_y, .w = words_w, .h = 28 }, owner.config.letter_order == .word_forming, 0xb701) and pending.* == null) {
            pending.* = .{ .set_letter_order = .word_forming };
        }
        if (pillButton(theme, "Home row first", .{ .x = ox + words_w + 6, .y = opt_y, .w = home_w, .h = 28 }, owner.config.letter_order == .home_row, 0xb702) and pending.* == null) {
            pending.* = .{ .set_letter_order = .home_row };
        }
        const share = homeRowShare(owner);
        const hint = if (share.first > 0 and share.home * 3 >= share.first * 2)
            try std.fmt.allocPrint(arena, "Both suit this layout: {d} of the first {d} letters sit on its home row", .{ share.home, share.first })
        else
            "Word-forming first gives real words from the first lesson; letters stay unlocked when you switch";
        presentation.label(hint, .{ .x = ox + words_w + home_w + 18, .y = opt_y + 1, .w = @max(0, w - pad - (ox + words_w + home_w + 18)), .h = 26 }, 12.5, theme.muted, null);
    }
}

/// How many of the word-forming first letters sit on the layout's home row.
fn homeRowShare(owner: *const control.Controller) struct { home: usize, first: usize } {
    if (!owner.profile_bound) return .{ .home = 0, .first = 0 };
    var buf: [26]u8 = undefined;
    const order = control.orderFor(&owner.profile, .word_forming, &buf);
    const first = order[0..control.firstCountFor(&owner.profile, .word_forming, order.len)];
    var home: usize = 0;
    for (first) |ch| home += @intFromBool(std.mem.indexOfScalar(u8, owner.profile.zone1Letters(), ch) != null);
    return .{ .home = home, .first = first.len };
}

fn drawProgressSheet(
    owner: *const control.Controller,
    sheet: *Sheet,
    theme: ui.Theme,
    ctx: SheetContext,
    pending: *?control.Intent,
) !void {
    const screen = dvui.windowRect();
    const w: f32 = @min(@as(f32, 920), screen.w - 40);
    const h: f32 = @min(@as(f32, 780), screen.h - 40);

    var fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .rect = .{ .x = (screen.w - w) * 0.5, .y = (screen.h - h) * 0.5, .w = w, .h = h },
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(14),
        .tag = "practice.sheet.progress",
    });
    defer fw.deinit();

    // Elevated header strip matching Mockup 3 surface hierarchy
    const header_bg = dvui.box(@src(), .{}, .{
        .id_extra = 0xc090,
        .rect = .{ .x = 1, .y = 1, .w = w - 2, .h = 99 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .corners = ui.topCorners(13),
        .padding = .{},
        .margin = .{},
    });
    header_bg.deinit();

    const arena = dvui.currentWindow().arena();
    const cont_lbl = try std.fmt.allocPrint(arena, "Continue Stage {d}", .{owner.config.stage.number()});
    const cta_w = @max(@as(f32, 154), ui.editorFont(cont_lbl, 15).textSize(cont_lbl).w + 34);
    const close_x = w - 58;
    const cta_x = close_x - 12 - cta_w;

    const title = try std.fmt.allocPrint(arena, "Progress · {s}", .{
        if (ctx.profile_name.len > 0) ctx.profile_name else "Active layout",
    });
    const subtitle = try std.fmt.allocPrint(arena, "Profile-scoped · {d} lessons · {d}-day streak · Local storage (ZON)", .{
        owner.learning.total_rounds,
        storage.dailyView(owner.persisted, owner.utc_now_sec).streak_days,
    });

    boldLabel(title, .{ .x = 24, .y = 22, .w = @max(120, cta_x - 36), .h = 30 }, 21, theme.text, 0xc091);
    presentation.label(subtitle, .{ .x = 24, .y = 58, .w = w - 48, .h = 22 }, 13.5, theme.muted, null);
    ui.divider(theme, .{ .x = 0, .y = 100, .w = w, .h = 1 }, 0xc092);

    if (ui.iconButton(theme, null, cont_lbl, "practice.sheet.continue", .{ .x = cta_x, .y = 21, .w = cta_w, .h = 34 }, true)) {
        sheet.* = .none;
        return;
    }
    if (ui.iconButton(theme, ui.control_icons.remove, "", "practice.sheet.close", .{ .x = close_x, .y = 23, .w = 30, .h = 30 }, false)) {
        sheet.* = .none;
        return;
    }

    // The body scrolls below the header once the tap/hold section makes it
    // taller than the sheet.
    const scroll_top: f32 = 101;
    const pad: f32 = 24;
    const body_top: f32 = 118 - scroll_top;
    const body_w = w - pad * 2;
    const body_h = h - 118 - 22;
    const tap_holds = tap_hold_ui.hasProgressData(owner);
    const th_h = if (tap_holds) tap_hold_ui.progressHeight(owner, body_w) else 0;
    const content_h = h - scroll_top - 1 + if (tap_holds) th_h + 12 else 0;
    const kpi_h: f32 = 84;
    const recent_h = std.math.clamp((body_h - kpi_h) * 0.36, 128.0, 236.0);
    const lower_y = body_top + kpi_h + 14;
    const lower_h = @max(180.0, body_h - kpi_h - 14 - recent_h - 12);
    const th_y = lower_y + lower_h + 12;
    var fallback_scroll: dvui.ScrollInfo = .{};
    const scroll_info = ctx.progress_scroll orelse &fallback_scroll;
    // Asked from a hover card or a notice: show the tap/hold section. The
    // offset holds until the scroll area has measured the content.
    if (ctx.focus_tap_hold) |focus| if (focus.*) {
        if (tap_holds) {
            const view_h = h - scroll_top - 1;
            scroll_info.viewport.y = @max(0, @min(th_y - 12, content_h - view_h));
            if (scroll_info.virtual_size.h >= content_h - 1) focus.* = false else dvui.refresh(null, @src(), null);
        } else focus.* = false;
    };
    const scroll = dvui.scrollArea(@src(), .{ .scroll_info = scroll_info }, .{
        .rect = .{ .x = 0, .y = scroll_top, .w = w, .h = h - scroll_top - 1 },
        .background = false,
        .padding = .{},
        .margin = .{},
    });
    defer scroll.deinit();
    const content = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = w - 12, .h = content_h },
        .padding = .{},
        .margin = .{},
    });
    defer content.deinit();

    // 1. Three elevated KPI cards across top
    const kpi_gap: f32 = 12;
    const kpi_w = (body_w - kpi_gap * 2) / 3.0;

    const stats = summarizeRuns(ctx.runs);
    const avg_wpm_str = if (stats.count > 0)
        try std.fmt.allocPrint(arena, "{d:.0} WPM", .{stats.recent_wpm})
    else
        "— WPM";
    const delta_str = if (stats.delta_wpm) |d|
        try std.fmt.allocPrint(arena, "{s}{d:.1} WPM trend", .{ if (d >= 0) "+" else "", d })
    else
        "Finish lessons to track the trend";
    drawKpiCard(theme, .{ .x = pad, .y = body_top, .w = kpi_w, .h = kpi_h }, "Recent average", avg_wpm_str, delta_str, if (stats.delta_wpm != null and stats.delta_wpm.? >= 0) theme.success else theme.muted, 0xc001);

    const acc_str = if (stats.count > 0)
        try std.fmt.allocPrint(arena, "{d:.1}%", .{stats.recent_acc})
    else
        "—";
    drawKpiCard(theme, .{ .x = pad + kpi_w + kpi_gap, .y = body_top, .w = kpi_w, .h = kpi_h }, "Accuracy", acc_str, "Target ≥ 95%", if (stats.recent_acc >= 95.0 or stats.count == 0) theme.success else theme.warning, 0xc002);

    const unlock_str = try std.fmt.allocPrint(arena, "{d} / {d}", .{ owner.learning.unlocked_count, owner.learning.unlock_len });
    const target_sub = try std.fmt.allocPrint(arena, "Target {d:.0} WPM", .{owner.config.target_wpm});
    drawKpiCard(theme, .{ .x = pad + (kpi_w + kpi_gap) * 2, .y = body_top, .w = kpi_w, .h = kpi_h }, "Unlocked keys", unlock_str, target_sub, theme.accent, 0xc003);

    // 2. Lower 2-column grid: WPM Trend Chart (left) + Weakest Keys & Transitions + Weak-spot CTA (right),
    // then the recent lessons with what each one changed.
    const stacked = body_w < 640;
    const left_w = if (stacked) body_w else body_w * 0.56;
    const right_w = if (stacked) body_w else body_w - left_w - 14;
    const chart_h = if (stacked) lower_h * 0.48 else lower_h;
    const weak_y = if (stacked) lower_y + chart_h + 10 else lower_y;
    const weak_h = if (stacked) lower_h - chart_h - 10 else lower_h;

    try drawWpmTrendPanel(owner, theme, .{ .x = pad, .y = lower_y, .w = left_w, .h = chart_h }, ctx.runs);
    try drawWeakSpotsPanel(owner, sheet, ctx.picks, theme, .{ .x = if (stacked) pad else pad + left_w + 14, .y = weak_y, .w = right_w, .h = weak_h }, pending);
    var recent_y = lower_y + lower_h + 12;
    if (tap_holds) {
        const asked = try tap_hold_ui.progressSection(owner, theme, .{ .x = pad, .y = th_y, .w = body_w, .h = th_h }, ctx.labels, ctx.geometry, ctx.can_edit);
        if (asked) |key| if (ctx.edit_key) |out| {
            out.* = key;
        };
        recent_y += th_h + 12;
    }
    try drawRecentLessons(owner, theme, .{ .x = pad, .y = recent_y, .w = body_w, .h = recent_h }, ctx.runs, ctx.labels);
}

/// The last lessons, newest first: speed and its change, accuracy, and what
/// each lesson brought: a new letter, keys that turned green, a weak-spot pair
/// and the keys that were weakest after it.
fn drawRecentLessons(owner: *const control.Controller, theme: ui.Theme, rect: dvui.Rect, runs: []const storage.RunRecord, labels: ?*const desktop.label_cache.LabelCache) !void {
    const panel = dvui.box(@src(), .{}, .{
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.recent_lessons",
    });
    defer panel.deinit();
    const arena = dvui.currentWindow().arena();
    boldLabel("Recent lessons", .{ .x = 14, .y = 10, .w = rect.w - 28, .h = 20 }, 14, theme.text, 0xe000);
    const every = try std.fmt.allocPrint(arena, "Every {d}th lesson practises the slowest letter pair", .{control.weak_spot_every});
    dvui.labelNoFmt(@src(), every, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = rect.w * 0.4, .y = 10, .w = rect.w * 0.6 - 14, .h = 20 },
        .font = ui.editorFont(every, 12.5),
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
    if (runs.len == 0) {
        presentation.label("Finished lessons appear here.", .{ .x = 14, .y = 40, .w = rect.w - 28, .h = 22 }, 13, theme.muted, null);
        return;
    }
    const row_h: f32 = 34;
    const rows: usize = @intFromFloat(@max(1.0, @floor((rect.h - 40) / row_h)));
    var shown: usize = 0;
    var i = runs.len;
    while (i > 0 and shown < rows) : (shown += 1) {
        i -= 1;
        const run = runs[i];
        const y = 38 + @as(f32, @floatFromInt(shown)) * row_h;
        ui.divider(theme, .{ .x = 14, .y = y, .w = rect.w - 28, .h = 1 }, 0xe100 + shown);
        const age = agoText(arena, owner.utc_now_sec, run.utc_timestamp) catch "";
        presentation.label(age, .{ .x = 14, .y = y + 6, .w = 70, .h = 22 }, 12.5, theme.muted, null);
        const delta: ?f32 = if (i > 0) run.wpm - runs[i - 1].wpm else null;
        const speed = try std.fmt.allocPrint(arena, "{d:.0} WPM", .{run.wpm});
        boldLabel(speed, .{ .x = 90, .y = y + 6, .w = 70, .h = 22 }, 14, theme.text, 0xe200 + shown);
        if (delta) |d| {
            const dt = try std.fmt.allocPrint(arena, "{s}{d:.1}", .{ if (d >= 0) "+" else "", d });
            presentation.label(dt, .{ .x = 160, .y = y + 6, .w = 44, .h = 22 }, 12.5, if (d >= 0) theme.success else theme.danger, null);
        }
        const acc = try std.fmt.allocPrint(arena, "{d:.1}%", .{run.accuracy});
        presentation.label(acc, .{ .x = 210, .y = y + 6, .w = 60, .h = 22 }, 13, theme.text, null);

        var px: f32 = 280;
        const limit = rect.w - 14;
        var slot: usize = shown * 16;
        if (run.unlocked_char) |ch| if (ch < 128) {
            px = lessonPill(theme, try std.fmt.allocPrint(arena, "New letter: {c}", .{std.ascii.toUpper(@intCast(ch))}), theme.success, px, y + 6, limit, nextSlot(&slot));
        };
        for (run.newly_green) |cp| if (cp < 128) {
            px = lessonPill(theme, try std.fmt.allocPrint(arena, "{c} green", .{std.ascii.toUpper(@intCast(cp))}), theme.success, px, y + 6, limit, nextSlot(&slot));
        };
        if (run.weak_spot) |pair| if (pair[0] < 128 and pair[1] < 128) {
            px = lessonPill(theme, try std.fmt.allocPrint(arena, "Weak spot: {c}{c}", .{ @as(u8, @intCast(pair[0])), @as(u8, @intCast(pair[1])) }), theme.warning, px, y + 6, limit, nextSlot(&slot));
        };
        const tags = try tap_hold_ui.lessonTags(arena, run, if (owner.profile_bound) &owner.profile else null, labels);
        if (tags.hold) |tag| px = lessonPill(theme, tag, tap_hold_ui.holdColor(theme), px, y + 6, limit, nextSlot(&slot));
        if (tags.tap) |tag| px = lessonPill(theme, tag, theme.warning, px, y + 6, limit, nextSlot(&slot));
        if (run.top_weak_keys.len > 0) {
            var names: std.ArrayList(u8) = .empty;
            try names.appendSlice(arena, "Weakest:");
            for (run.top_weak_keys) |cp| if (cp < 128) {
                try names.append(arena, ' ');
                try names.append(arena, std.ascii.toUpper(@intCast(cp)));
            };
            _ = lessonPill(theme, names.items, theme.muted, px, y + 6, limit, nextSlot(&slot));
        }
    }
}

fn nextSlot(slot: *usize) usize {
    slot.* += 1;
    return slot.*;
}

/// A small rounded label at `x`; returns where the next one starts.
fn lessonPill(theme: ui.Theme, text: []const u8, color: dvui.Color, x: f32, y: f32, limit: f32, id: usize) f32 {
    const w = ui.editorFont(text, 12).textSize(text).w + 18;
    if (x + w > limit) return x;
    const pill = dvui.box(@src(), .{}, .{
        .id_extra = 0xe400 + id,
        .rect = .{ .x = x, .y = y, .w = w, .h = 22 },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, color, 0.14) },
        .color_border = .{ .color = ui.mix(theme.panel, color, 0.55) },
        .border = .all(1),
        .corners = .all(11),
        .padding = .{},
        .margin = .{},
    });
    pill.deinit();
    presentation.caption(text, .{ .x = x, .y = y, .w = w, .h = 22 }, 12, color, null);
    return x + w + 6;
}

fn agoText(arena: std.mem.Allocator, now: u64, then: u64) ![]const u8 {
    if (now == 0 or then == 0 or then > now) return "";
    const secs = now - then;
    if (secs < 60) return "just now";
    if (secs < 3600) return std.fmt.allocPrint(arena, "{d} min ago", .{secs / 60});
    if (secs < 86_400) return std.fmt.allocPrint(arena, "{d} h ago", .{secs / 3600});
    return std.fmt.allocPrint(arena, "{d} d ago", .{secs / 86_400});
}

fn drawKpiCard(
    theme: ui.Theme,
    rect: dvui.Rect,
    title: []const u8,
    value: []const u8,
    sub: []const u8,
    sub_color: dvui.Color,
    id: usize,
) void {
    const box = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
    presentation.label(title, .{ .x = rect.x + 14, .y = rect.y + 10, .w = rect.w - 28, .h = 18 }, 13, theme.muted, null);
    boldLabel(value, .{ .x = rect.x + 14, .y = rect.y + 30, .w = rect.w - 28, .h = 26 }, 22, theme.text, id + 0x10);
    presentation.label(sub, .{ .x = rect.x + 14, .y = rect.y + 59, .w = rect.w - 28, .h = 18 }, 12.5, sub_color, null);
}

fn drawWpmTrendPanel(
    owner: *const control.Controller,
    theme: ui.Theme,
    rect: dvui.Rect,
    runs: []const storage.RunRecord,
) !void {
    const panel = dvui.box(@src(), .{}, .{
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.chart.wpm",
    });
    defer panel.deinit();

    const arena = dvui.currentWindow().arena();
    boldLabel("WPM trend & unlocks", .{ .x = 14, .y = 12, .w = rect.w - 140, .h = 20 }, 14, theme.text, 0xc101);
    const target_tag = try std.fmt.allocPrint(arena, "Target {d:.0} WPM", .{owner.config.target_wpm});
    dvui.labelNoFmt(@src(), target_tag, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = rect.w - 134, .y = 12, .w = 120, .h = 20 },
        .font = ui.editorFont(target_tag, 12.5).withWeight(.bold),
        .color_text = .{ .color = theme.warning },
        .padding = .{},
        .margin = .{},
    });

    if (runs.len < 2) {
        presentation.caption("Finish at least 2 lessons to plot your WPM curve", .{ .x = 16, .y = 44, .w = rect.w - 32, .h = rect.h - 60 }, 13.5, theme.muted, null);
        return;
    }

    // Downsample to at most 60 recent points for smooth rendering even at 1000+ rounds.
    const max_pts: usize = 60;
    const start_idx = if (runs.len > max_pts) runs.len - max_pts else 0;
    const slice = runs[start_idx..];

    var min_wpm: f32 = owner.config.target_wpm;
    var max_wpm: f32 = owner.config.target_wpm + 10.0;
    for (slice) |r| {
        min_wpm = @min(min_wpm, r.wpm);
        max_wpm = @max(max_wpm, r.wpm);
    }
    const y_min = @max(0.0, @floor((min_wpm - 5.0) / 10.0) * 10.0);
    const y_max = @max(y_min + 20.0, @ceil((max_wpm + 5.0) / 10.0) * 10.0);
    const y_span = y_max - y_min;

    const plot_x: f32 = 44;
    const plot_y: f32 = 42;
    const plot_w = @max(40.0, rect.w - plot_x - 16);
    const plot_h = @max(40.0, rect.h - plot_y - 30);
    const parent = dvui.parentGet();

    // Horizontal gridlines & Y-axis labels (4 ticks)
    for (0..4) |ti| {
        const frac = @as(f32, @floatFromInt(ti)) / 3.0;
        const val = y_max - frac * y_span;
        const gy = plot_y + frac * plot_h;
        ui.divider(theme, .{ .x = plot_x, .y = gy, .w = plot_w, .h = 1 }, 0xc200 + ti);
        const ylbl = try std.fmt.allocPrint(arena, "{d:.0}", .{val});
        dvui.labelNoFmt(@src(), ylbl, .{ .align_x = 1, .align_y = 0.5 }, .{
            .id_extra = 0xc220 + ti,
            .rect = .{ .x = 4, .y = gy - 8, .w = plot_x - 10, .h = 16 },
            .font = dvui.Font.theme(.mono).withSize(11.5),
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
    }

    // Dashed amber target-WPM line
    const target_frac = std.math.clamp((y_max - owner.config.target_wpm) / y_span, 0.0, 1.0);
    const ty = plot_y + target_frac * plot_h;
    var dx: f32 = plot_x;
    while (dx < plot_x + plot_w) : (dx += 10.0) {
        const p0 = parent.screenRectScale(.{ .x = dx, .y = ty }).r.topLeft();
        const p1 = parent.screenRectScale(.{ .x = @min(dx + 5.0, plot_x + plot_w), .y = ty }).r.topLeft();
        var seg: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
        defer seg.deinit();
        seg.addPoint(p0);
        seg.addPoint(p1);
        seg.build().stroke(.{ .thickness = 1.4, .color = .{ .color = theme.warning.opacity(0.85) } });
    }

    // Compute EMA-smoothed curve + draw raw dots, subtle area fill, EMA polyline, and unlock markers
    var ema_pts: [max_pts]dvui.Point.Physical = undefined;
    var ema_val: f32 = slice[0].wpm;
    const denom: f32 = @floatFromInt(slice.len - 1);

    for (slice, 0..) |r, i| {
        if (i == 0) {
            ema_val = r.wpm;
        } else {
            ema_val = ema_val * 0.72 + r.wpm * 0.28;
        }
        const px = plot_x + (@as(f32, @floatFromInt(i)) / denom) * plot_w;
        const raw_y = plot_y + std.math.clamp((y_max - r.wpm) / y_span, 0.0, 1.0) * plot_h;
        const ema_y = plot_y + std.math.clamp((y_max - ema_val) / y_span, 0.0, 1.0) * plot_h;
        ema_pts[i] = parent.screenRectScale(.{ .x = px, .y = ema_y }).r.topLeft();

        // Raw round dot
        const dot = dvui.box(@src(), .{}, .{
            .id_extra = 0xc300 + i,
            .rect = .{ .x = px - 3, .y = raw_y - 3, .w = 6, .h = 6 },
            .background = true,
            .color_fill = .{ .color = if (r.unlocked_char != null) theme.success else theme.accent.opacity(0.45) },
            .corners = .all(3),
            .padding = .{},
            .margin = .{},
        });
        dot.deinit();

        // Unlock event marker (+X)
        if (r.unlocked_char) |ucp| {
            if (ucp <= 127) {
                const tag = try std.fmt.allocPrint(arena, "+{c}", .{std.ascii.toUpper(@intCast(ucp))});
                dvui.labelNoFmt(@src(), tag, .{ .align_x = 0.5, .align_y = 0.5 }, .{
                    .id_extra = 0xc400 + i,
                    .rect = .{ .x = px - 14, .y = @max(plot_y - 4, raw_y - 19), .w = 28, .h = 15 },
                    .font = dvui.Font.theme(.mono).withSize(11).withWeight(.bold),
                    .color_text = .{ .color = theme.success },
                    .padding = .{},
                    .margin = .{},
                });
            }
        }
    }

    // Subtle translucent area fill under the EMA curve (one convex quad per segment)
    const base_y = parent.screenRectScale(.{ .x = plot_x, .y = plot_y + plot_h }).r.y;
    for (0..slice.len - 1) |i| {
        var quad: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
        defer quad.deinit();
        quad.addPoint(ema_pts[i]);
        quad.addPoint(ema_pts[i + 1]);
        quad.addPoint(.{ .x = ema_pts[i + 1].x, .y = base_y });
        quad.addPoint(.{ .x = ema_pts[i].x, .y = base_y });
        quad.build().fillConvex(.{ .color = .{ .color = theme.accent.opacity(0.11) } });
    }

    // Smoothed EMA polyline
    var line: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer line.deinit();
    for (ema_pts[0..slice.len]) |pt| line.addPoint(pt);
    line.build().stroke(.{ .thickness = 2.4, .color = .{ .color = theme.accent } });

    // Subtle X-axis start/end labels
    const first_lbl = try std.fmt.allocPrint(arena, "Lesson {d}", .{start_idx + 1});
    const last_lbl = try std.fmt.allocPrint(arena, "Lesson {d}", .{runs.len});
    presentation.label(first_lbl, .{ .x = plot_x, .y = plot_y + plot_h + 6, .w = 90, .h = 16 }, 11, theme.muted, null);
    dvui.labelNoFmt(@src(), last_lbl, .{ .align_x = 1, .align_y = 0.5 }, .{
        .id_extra = 0xc490,
        .rect = .{ .x = plot_x + plot_w - 90, .y = plot_y + plot_h + 6, .w = 90, .h = 16 },
        .font = ui.editorFont(last_lbl, 11),
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
}

fn drawWeakSpotsPanel(
    owner: *const control.Controller,
    sheet: *Sheet,
    picks: *Picks,
    theme: ui.Theme,
    rect: dvui.Rect,
    pending: *?control.Intent,
) !void {
    const panel = dvui.box(@src(), .{}, .{
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.sheet.weak_panel",
    });
    defer panel.deinit();

    const arena = dvui.currentWindow().arena();
    const pad: f32 = 14;
    const link = "Reset characters…";
    const link_w = ui.editorFont(link, 12.5).textSize(link).w + 8;
    boldLabel("Weakest keys & transitions", .{ .x = pad, .y = 12, .w = @max(0, rect.w - pad * 2 - link_w - 8), .h = 20 }, 14, theme.text, 0xd090);
    if (linkButton(theme, link, .{ .x = rect.w - pad - link_w, .y = 12, .w = link_w, .h = 20 }, "practice.sheet.reset_keys")) {
        openSheet(sheet, picks, .reset_keys);
        return;
    }

    var wk_buf: [4]model.KeySummary = undefined;
    const weak_keys = owner.learning.weakestKeys(&wk_buf);
    var wb_buf: [3]model.BigramStat = undefined;
    const weak_bigrams = owner.learning.slowestBigrams(2, &wb_buf);

    const cta_h: f32 = 54;
    const cta_y = rect.h - cta_h - 12;
    const list_limit = cta_y - (if (weak_bigrams.len > 0) @as(f32, 30) else @as(f32, 10));

    var cy: f32 = 40;
    if (weak_keys.len == 0 and weak_bigrams.len == 0) {
        drawWrappedTwoLines(
            "Complete a round to identify your slowest keys and transitions.",
            .{ .x = pad, .y = cy + 4, .w = rect.w - pad * 2, .h = 38 },
            13,
            theme.muted,
            18,
            0xd095,
        );
    } else {
        const max_rows: usize = @min(weak_keys.len, 4);
        for (weak_keys[0..max_rows], 0..) |wk, i| {
            const row_h: f32 = 42;
            if (cy + row_h > list_limit) break;
            const row = dvui.box(@src(), .{}, .{
                .id_extra = 0xd000 + i,
                .rect = .{ .x = pad, .y = cy, .w = rect.w - pad * 2, .h = row_h },
                .background = true,
                .color_fill = .{ .color = theme.bg },
                .color_border = .{ .color = theme.border },
                .border = .all(1),
                .corners = .all(8),
                .padding = .{},
                .margin = .{},
            });
            row.deinit();

            var cbuf: [4]u8 = undefined;
            const clen = std.unicode.utf8Encode(wk.cp, &cbuf) catch 0;
            if (clen == 1) cbuf[0] = std.ascii.toUpper(cbuf[0]);
            const kbadge: dvui.Rect = .{ .x = pad + 8, .y = cy + 7, .w = 28, .h = 28 };
            const kb = dvui.box(@src(), .{}, .{
                .id_extra = 0xd100 + i,
                .rect = kbadge,
                .background = true,
                .color_fill = .{ .color = ui.mix(theme.panel, theme.warning, 0.22) },
                .corners = .all(6),
                .padding = .{},
                .margin = .{},
            });
            kb.deinit();
            dvui.labelNoFmt(@src(), cbuf[0..clen], .{ .align_x = 0.5, .align_y = 0.5 }, .{
                .id_extra = 0xd140 + i,
                .rect = kbadge,
                .font = dvui.Font.theme(.mono).withSize(14).withWeight(.bold),
                .color_text = .{ .color = theme.warning },
                .padding = .{},
                .margin = .{},
            });

            const key_wpm: f32 = if (wk.ema_ms > 0) 12_000.0 / wk.ema_ms else 0;
            const finger_str: []const u8 = if (owner.profile_bound) blk: {
                if (owner.profile.routeFor(wk.cp)) |r| break :blk owner.profile.fingerFor(r.key_index).name();
                break :blk "";
            } else "";
            const meta = if (finger_str.len > 0)
                try std.fmt.allocPrint(arena, "{d:.0} WPM · {d:.0}% · {s}", .{ key_wpm, wk.ema_acc * 100.0, finger_str })
            else
                try std.fmt.allocPrint(arena, "{d:.0} WPM · {d:.0}%", .{ key_wpm, wk.ema_acc * 100.0 });
            const bar_w: f32 = 62;
            const bx = rect.w - pad - bar_w - 10;
            presentation.label(meta, .{ .x = pad + 44, .y = cy + 11, .w = @max(0, bx - (pad + 50)), .h = 20 }, 12.5, theme.muted, null);

            // Percentage readout directly above mini confidence bar
            const pct_str = try std.fmt.allocPrint(arena, "{d:.0}%", .{wk.confidence * 100.0});
            const bar_col = if (wk.confidence >= 1.0) theme.success else theme.warning;
            dvui.labelNoFmt(@src(), pct_str, .{ .align_x = 1, .align_y = 0.5 }, .{
                .id_extra = 0xd180 + i,
                .rect = .{ .x = bx, .y = cy + 6, .w = bar_w, .h = 14 },
                .font = ui.editorFont(pct_str, 11.5).withWeight(.bold),
                .color_text = .{ .color = bar_col },
                .padding = .{},
                .margin = .{},
            });

            const tr = dvui.box(@src(), .{}, .{
                .id_extra = 0xd200 + i,
                .rect = .{ .x = bx, .y = cy + 25, .w = bar_w, .h = 6 },
                .background = true,
                .color_fill = .{ .color = theme.control },
                .corners = .all(3),
                .padding = .{},
                .margin = .{},
            });
            tr.deinit();
            const bf = dvui.box(@src(), .{}, .{
                .id_extra = 0xd300 + i,
                .rect = .{ .x = bx, .y = cy + 25, .w = @max(3.0, bar_w * wk.confidence), .h = 6 },
                .background = true,
                .color_fill = .{ .color = bar_col },
                .corners = .all(3),
                .padding = .{},
                .margin = .{},
            });
            bf.deinit();
            cy += row_h + 7;
        }

        if (weak_bigrams.len > 0 and cy + 20 < cta_y - 4) {
            const bg = weak_bigrams[0];
            var b1: [4]u8 = undefined;
            var b2: [4]u8 = undefined;
            const n1 = std.unicode.utf8Encode(bg.prev, &b1) catch 0;
            const n2 = std.unicode.utf8Encode(bg.cur, &b2) catch 0;
            const bg_text = try std.fmt.allocPrint(arena, "Slowest transition: {s}{s} ({d:.0} ms avg)", .{ b1[0..n1], b2[0..n2], bg.ema_ms });
            presentation.label(bg_text, .{ .x = pad, .y = cy + 1, .w = rect.w - pad * 2, .h = 20 }, 12.5, theme.muted, null);
        }
    }

    // 1-click Weak-spot drill CTA pinned cleanly at bottom of panel
    const cta_box = dvui.box(@src(), .{}, .{
        .rect = .{ .x = pad, .y = cta_y, .w = rect.w - pad * 2, .h = cta_h },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, theme.accent, 0.14) },
        .color_border = .{ .color = ui.mix(theme.panel, theme.accent, 0.45) },
        .border = .all(1),
        .corners = .all(9),
        .padding = .{},
        .margin = .{},
    });
    cta_box.deinit();

    const start_w: f32 = 96;
    const text_w = @max(0.0, rect.w - pad * 2 - start_w - 28);
    boldLabel("Weak-spot drill", .{ .x = pad + 12, .y = cta_y + 8, .w = text_w, .h = 19 }, 13.5, theme.text, 0xd401);
    presentation.label("Target bottlenecks (~20 words)", .{ .x = pad + 12, .y = cta_y + 28, .w = text_w, .h = 18 }, 12, theme.muted, null);
    if (ui.iconButton(theme, null, "Start →", "practice.sheet.weak_spot", .{ .x = rect.w - pad - start_w - 10, .y = cta_y + 10, .w = start_w, .h = 34 }, true) and pending.* == null) {
        pending.* = .start_weak_spot;
        sheet.* = .none;
    }
}

const RunSummary = struct {
    count: usize = 0,
    recent_wpm: f32 = 0.0,
    recent_acc: f32 = 0.0,
    delta_wpm: ?f32 = null,
};

pub fn summarizeRuns(runs: []const storage.RunRecord) RunSummary {
    if (runs.len == 0) return .{};
    const recent_n = @min(runs.len, 10);
    var sum_wpm: f32 = 0;
    var sum_acc: f32 = 0;
    for (runs[runs.len - recent_n ..]) |r| {
        sum_wpm += r.wpm;
        sum_acc += r.accuracy;
    }
    const recent_wpm = sum_wpm / @as(f32, @floatFromInt(recent_n));
    const recent_acc = sum_acc / @as(f32, @floatFromInt(recent_n));

    var delta: ?f32 = null;
    if (runs.len >= 4) {
        const split = runs.len / 2;
        var early_sum: f32 = 0;
        for (runs[0..split]) |r| early_sum += r.wpm;
        const early_avg = early_sum / @as(f32, @floatFromInt(split));
        delta = recent_wpm - early_avg;
    }
    return .{
        .count = runs.len,
        .recent_wpm = recent_wpm,
        .recent_acc = recent_acc,
        .delta_wpm = delta,
    };
}

/// Stage 1 is done once all first letters are green.
fn isHomeRowMastered(owner: *const control.Controller) bool {
    const first = owner.learning.firstLetters();
    if (first.len == 0) return false;
    for (first) |ch| {
        if (!owner.learning.isGreen(ch)) return false;
    }
    return true;
}

fn stageAccentColor(theme: ui.Theme, st: generator.Stage) dvui.Color {
    return switch (st) {
        .home_row => theme.success,
        .all_letters => theme.accent,
        .shift => ui.mix(ui.layerColor(theme, 5), theme.accent, 0.35),
        .punctuation_numbers => theme.warning,
        .layers_combos => ui.layerColor(theme, 3),
        .free_text => ui.layerColor(theme, 4),
    };
}

fn stageProgress(owner: *const control.Controller, st: generator.Stage, home_mastered: bool) f32 {
    return switch (st) {
        .home_row => if (home_mastered) 1.0 else blk: {
            const first = owner.learning.firstLetters();
            if (first.len == 0) break :blk 0.0;
            var sum: f32 = 0;
            for (first) |ch| sum += if (owner.learning.isGreen(ch)) 1.0 else owner.learning.confidenceFor(ch);
            break :blk sum / @as(f32, @floatFromInt(first.len));
        },
        .all_letters => if (owner.learning.unlock_len == 0)
            0.0
        else
            @as(f32, @floatFromInt(owner.learning.unlocked_count)) / @as(f32, @floatFromInt(owner.learning.unlock_len)),
        else => if (owner.config.stage == st) 0.5 else 0.0,
    };
}

fn stageDescription(
    arena: std.mem.Allocator,
    owner: *const control.Controller,
    prof: ?*const lp.LayoutProfile,
    labels: ?*const desktop.label_cache.LabelCache,
    st: generator.Stage,
) ![]const u8 {
    return switch (st) {
        .home_row => try describeHomeRow(arena, owner, prof),
        .all_letters => try describeAllLetters(arena, owner),
        .shift => try describeShift(arena, prof, labels),
        .punctuation_numbers => try describePunctuationNumbers(arena, prof),
        .layers_combos => try describeLayersCombos(arena, prof),
        .free_text => "English prose, Zig code snippets & custom text",
    };
}

fn describeHomeRow(
    arena: std.mem.Allocator,
    owner: *const control.Controller,
    prof: ?*const lp.LayoutProfile,
) ![]const u8 {
    const p = prof orelse return "The first letters + thumb Space";
    const z1 = owner.learning.firstLetters();
    if (z1.len == 0) return "The first letters + thumb Space";

    var left_buf: [24]u8 = undefined;
    var left_len: usize = 0;
    var right_buf: [24]u8 = undefined;
    var right_len: usize = 0;
    var wpm_sum: f32 = 0;
    var wpm_count: usize = 0;

    for (z1) |ch| {
        const up = std.ascii.toUpper(ch);
        const hand: lp.Hand = if (p.routeFor(ch)) |r| p.handFor(r.key_index) else .neutral;
        if (hand == .right) {
            if (right_len > 0 and right_len + 1 < right_buf.len) {
                right_buf[right_len] = ' ';
                right_len += 1;
            }
            if (right_len < right_buf.len) {
                right_buf[right_len] = up;
                right_len += 1;
            }
        } else {
            if (left_len > 0 and left_len + 1 < left_buf.len) {
                left_buf[left_len] = ' ';
                left_len += 1;
            }
            if (left_len < left_buf.len) {
                left_buf[left_len] = up;
                left_len += 1;
            }
        }
        if (owner.learning.getStat(ch)) |ks| {
            const w = ks.wpm();
            if (ks.samples > 0 and w > 0) {
                wpm_sum += w;
                wpm_count += 1;
            }
        }
    }

    const keys_part = if (left_len > 0 and right_len > 0)
        try std.fmt.allocPrint(arena, "{s} · {s} + thumb Space", .{ left_buf[0..left_len], right_buf[0..right_len] })
    else if (left_len > 0)
        try std.fmt.allocPrint(arena, "{s} + thumb Space", .{left_buf[0..left_len]})
    else
        try std.fmt.allocPrint(arena, "{s} + thumb Space", .{right_buf[0..right_len]});

    if (wpm_count > 0) {
        const avg = wpm_sum / @as(f32, @floatFromInt(wpm_count));
        return try std.fmt.allocPrint(arena, "{s} · {d:.0} WPM avg", .{ keys_part, avg });
    }
    return keys_part;
}

fn describeAllLetters(arena: std.mem.Allocator, owner: *const control.Controller) ![]const u8 {
    const lm = &owner.learning;
    if (lm.unlock_len == 0) return "Adaptive letter unlock · layout-ordered";
    if (lm.unlocked_count >= lm.unlock_len) {
        return try std.fmt.allocPrint(arena, "All {d}/{d} letters unlocked · Speed & accuracy polish", .{ lm.unlocked_count, lm.unlock_len });
    }

    const focus_c: u8 = if (lm.focus_cp) |f| (if (f <= 127) std.ascii.toUpper(@intCast(f)) else '?') else '-';
    const rem = lm.unlock_order[lm.unlocked_count..lm.unlock_len];
    var next_buf: [16]u8 = undefined;
    var next_len: usize = 0;
    const take = @min(rem.len, 3);
    for (rem[0..take], 0..) |ch, idx| {
        if (idx > 0 and next_len + 2 <= next_buf.len) {
            next_buf[next_len] = ',';
            next_buf[next_len + 1] = ' ';
            next_len += 2;
        }
        if (next_len < next_buf.len) {
            next_buf[next_len] = std.ascii.toUpper(ch);
            next_len += 1;
        }
    }
    if (next_len > 0) {
        return try std.fmt.allocPrint(arena, "Adaptive · Focus: {c} · Next: {s}", .{ focus_c, next_buf[0..next_len] });
    }
    return try std.fmt.allocPrint(arena, "{d}/{d} unlocked · Focus: {c}", .{ lm.unlocked_count, lm.unlock_len, focus_c });
}

fn describeShift(
    arena: std.mem.Allocator,
    prof: ?*const lp.LayoutProfile,
    labels: ?*const desktop.label_cache.LabelCache,
) ![]const u8 {
    const p = prof orelse return "Capitalization with opposite-hand Shift";
    var left_sp: ?lp.ShiftProvider = null;
    var right_sp: ?lp.ShiftProvider = null;
    for (p.shiftSlice()) |sp| {
        if (sp.hand == .left) {
            if (left_sp == null or shiftRank(sp.kind) > shiftRank(left_sp.?.kind)) left_sp = sp;
        } else if (sp.hand == .right) {
            if (right_sp == null or shiftRank(sp.kind) > shiftRank(right_sp.?.kind)) right_sp = sp;
        }
    }

    if (left_sp != null and right_sp != null) {
        const home_row = left_sp.?.kind == .home_row_hold and right_sp.?.kind == .home_row_hold;
        const l_lbl = try shortKeyLabel(arena, labels, left_sp.?.key_index);
        const r_lbl = try shortKeyLabel(arena, labels, right_sp.?.key_index);
        if (l_lbl != null and r_lbl != null) {
            if (home_row) {
                return try std.fmt.allocPrint(arena, "Opposite-hand home-row Shift ({s}/{s})", .{ l_lbl.?, r_lbl.? });
            }
            return try std.fmt.allocPrint(arena, "Balanced opposite-hand Shift ({s}/{s})", .{ l_lbl.?, r_lbl.? });
        }
        if (home_row) return "Opposite-hand home-row Shift (50/50 balanced)";
        return "50/50 balanced opposite-hand Shift";
    }
    return "Capitalization with opposite-hand Shift";
}

fn shiftRank(kind: lp.ShiftKind) u8 {
    return switch (kind) {
        .home_row_hold => 5,
        .thumb_hold => 4,
        .one_shot => 3,
        .dedicated => 2,
        .hold => 1,
    };
}

fn shortKeyLabel(arena: std.mem.Allocator, labels: ?*const desktop.label_cache.LabelCache, key_index: usize) !?[]const u8 {
    const cache = labels orelse return null;
    if (cache.layer_count == 0 or key_index >= cache.key_count) return null;
    const raw = cache.lookup(0, key_index, .{}).label orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or trimmed.len > 6) return null;
    for (trimmed) |c| {
        if (c < 0x21 or c > 0x7e) return null;
    }
    if (trimmed.len == 1 and std.ascii.isAlphabetic(trimmed[0])) {
        const up = try arena.alloc(u8, 1);
        up[0] = std.ascii.toUpper(trimmed[0]);
        return up;
    }
    return trimmed;
}

fn describePunctuationNumbers(arena: std.mem.Allocator, prof: ?*const lp.LayoutProfile) ![]const u8 {
    const p = prof orelse return "Punctuation groups & number patterns";
    const punc = p.punctuationSlice();
    const digits = p.digitsSlice();

    var punc_sample: [16]u8 = undefined;
    var punc_len: usize = 0;
    const take = @min(punc.len, 4);
    for (punc[0..take], 0..) |ch, idx| {
        if (idx > 0 and punc_len < punc_sample.len) {
            punc_sample[punc_len] = ' ';
            punc_len += 1;
        }
        if (punc_len < punc_sample.len) {
            punc_sample[punc_len] = ch;
            punc_len += 1;
        }
    }

    var digit_layer: ?usize = null;
    for (digits) |d| {
        if (p.routeFor(d)) |r| {
            if (r.layer > 0) {
                digit_layer = r.layer;
                break;
            }
        }
    }

    if (punc_len > 0 and digit_layer != null) {
        return try std.fmt.allocPrint(arena, "Punctuation ({s}) & digits (Layer {d})", .{ punc_sample[0..punc_len], digit_layer.? });
    }
    if (punc_len > 0 and digits.len > 0) {
        return try std.fmt.allocPrint(arena, "Punctuation ({s}) & {d} digits", .{ punc_sample[0..punc_len], digits.len });
    }
    return try std.fmt.allocPrint(arena, "{d} punctuation & {d} digits reachable", .{ p.punctuation_len, p.digits_len });
}

fn describeLayersCombos(arena: std.mem.Allocator, prof: ?*const lp.LayoutProfile) ![]const u8 {
    const p = prof orelse return "Programming symbols & 2-key combos";
    var layers_buf: [4]usize = undefined;
    const sym_layers = collectSymbolLayers(p, &layers_buf);

    const syms = p.layerSymbolsSlice();
    var sample: [16]u8 = undefined;
    var sample_len: usize = 0;
    const take = @min(syms.len, 4);
    for (syms[0..take], 0..) |ch, idx| {
        if (idx > 0 and sample_len < sample.len) {
            sample[sample_len] = ' ';
            sample_len += 1;
        }
        if (sample_len < sample.len) {
            sample[sample_len] = ch;
            sample_len += 1;
        }
    }

    if (sym_layers.len == 1 and sample_len > 0) {
        if (p.combo_len > 0) {
            return try std.fmt.allocPrint(arena, "Layer {d} symbols ({s}) & {d} project combos", .{ sym_layers[0], sample[0..sample_len], p.combo_len });
        }
        return try std.fmt.allocPrint(arena, "Layer {d} symbols ({s}) · {d} reachable", .{ sym_layers[0], sample[0..sample_len], p.layer_symbols_len });
    }
    if (sym_layers.len > 1 and sample_len > 0) {
        if (p.combo_len > 0) {
            return try std.fmt.allocPrint(arena, "{d} symbols ({d} layers) & {d} project combos", .{ p.layer_symbols_len, sym_layers.len, p.combo_len });
        }
        return try std.fmt.allocPrint(arena, "{d} symbols across {d} layers ({s})", .{ p.layer_symbols_len, sym_layers.len, sample[0..sample_len] });
    }
    return try std.fmt.allocPrint(arena, "{d} layer symbols & {d} project combos", .{ p.layer_symbols_len, p.combo_len });
}

fn collectSymbolLayers(prof: ?*const lp.LayoutProfile, out: []usize) []usize {
    const p = prof orelse return out[0..0];
    var mask: u16 = 0;
    for (p.layerSymbolsSlice()) |ch| {
        if (p.routeFor(ch)) |r| {
            if (r.layer > 0 and r.layer < 16) {
                mask |= @as(u16, 1) << @intCast(r.layer);
            }
        }
    }
    var count: usize = 0;
    for (1..16) |layer_idx| {
        if ((mask & (@as(u16, 1) << @intCast(layer_idx))) != 0) {
            if (count >= out.len) break;
            out[count] = layer_idx;
            count += 1;
        }
    }
    return out[0..count];
}

fn boldLabel(text: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color, id: usize) void {
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0, .align_y = 0.5, .ellipsize = true }, .{
        .id_extra = id,
        .rect = bounds,
        .font = ui.editorFont(text, size).withWeight(.bold),
        .color_text = .{ .color = color },
        .padding = .{},
        .margin = .{},
    });
}

/// Renders `text` over 1 or 2 word-wrapped lines within `bounds.w`, ellipsizing only
/// if the second line still exceeds width.
fn drawWrappedTwoLines(
    text: []const u8,
    bounds: dvui.Rect,
    size: f32,
    color: dvui.Color,
    line_h: f32,
    id_base: usize,
) void {
    if (text.len == 0 or bounds.w <= 8) return;
    const font = ui.editorFont(text, size);
    if (font.textSize(text).w <= bounds.w) {
        dvui.labelNoFmt(@src(), text, .{ .align_x = 0, .align_y = 0, .ellipsize = true }, .{
            .id_extra = id_base,
            .rect = .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = line_h },
            .font = font,
            .color_text = .{ .color = color },
            .padding = .{},
            .margin = .{},
        });
        return;
    }

    var split: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == ' ') {
            if (font.textSize(text[0..i]).w <= bounds.w) {
                split = i;
            } else {
                break;
            }
        }
    }

    if (split == 0) {
        dvui.labelNoFmt(@src(), text, .{ .align_x = 0, .align_y = 0, .ellipsize = true }, .{
            .id_extra = id_base,
            .rect = .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = line_h },
            .font = font,
            .color_text = .{ .color = color },
            .padding = .{},
            .margin = .{},
        });
        return;
    }

    const line1 = std.mem.trimEnd(u8, text[0..split], " ");
    const line2 = std.mem.trimStart(u8, text[split + 1 ..], " ");
    dvui.labelNoFmt(@src(), line1, .{ .align_x = 0, .align_y = 0, .ellipsize = true }, .{
        .id_extra = id_base,
        .rect = .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = line_h },
        .font = font,
        .color_text = .{ .color = color },
        .padding = .{},
        .margin = .{},
    });
    if (line2.len > 0) {
        dvui.labelNoFmt(@src(), line2, .{ .align_x = 0, .align_y = 0, .ellipsize = true }, .{
            .id_extra = id_base + 1,
            .rect = .{ .x = bounds.x, .y = bounds.y + line_h, .w = bounds.w, .h = line_h },
            .font = font,
            .color_text = .{ .color = color },
            .padding = .{},
            .margin = .{},
        });
    }
}

fn pillButton(theme: ui.Theme, text: []const u8, rect: dvui.Rect, active: bool, id: usize) bool {
    var opts = ui.options(theme, rect, 12.5);
    opts.id_extra = id;
    opts.background = true;
    opts.border = .all(1);
    opts.corners = .all(7);
    opts.padding = .{};
    opts.color_fill = .{ .color = if (active) ui.mix(theme.panel, theme.accent, 0.24) else theme.control };
    opts.color_border = .{ .color = if (active) theme.accent else theme.border };
    opts.color_text = .{ .color = if (active) theme.text else theme.muted };
    return dvui.button(@src(), text, .{}, opts);
}

// ---------------------------------------------------------------------------
// Layout changes and per-character reset
// ---------------------------------------------------------------------------

/// The characters chosen in the layout-changes and reset sheets, as entries
/// (`key_change.groupOf`): a letter stands for both of its cases.
pub const Picks = struct {
    cps: [control.max_key_reset]u21 = undefined,
    len: usize = 0,
    /// The entry the layout-changes comparison shows.
    selected: ?u21 = null,
    /// Whether the reset sheet asks for confirmation.
    confirm: bool = false,

    pub fn slice(self: *const Picks) []const u21 {
        return self.cps[0..self.len];
    }

    pub fn has(self: *const Picks, cp: u21) bool {
        return std.mem.indexOfScalar(u21, self.slice(), cp) != null;
    }

    pub fn set(self: *Picks, cp: u21, on: bool) void {
        if (std.mem.indexOfScalar(u21, self.slice(), cp)) |i| {
            if (on) return;
            std.mem.copyForwards(u21, self.cps[i .. self.len - 1], self.cps[i + 1 .. self.len]);
            self.len -= 1;
        } else if (on and self.len < self.cps.len) {
            self.cps[self.len] = cp;
            self.len += 1;
        }
    }

    pub fn request(self: *const Picks, profile_hash: control.Digest) control.KeyReset {
        var out: control.KeyReset = .{ .profile_hash = profile_hash };
        for (self.slice()) |cp| out.add(cp);
        return out;
    }
};

/// Opens a sheet of this section with a clean choice.
pub fn openSheet(sheet: *Sheet, picks: *Picks, which: Sheet) void {
    sheet.* = which;
    picks.* = .{};
}

fn reviewGroups(owner: *const control.Controller, out: []u21) []u21 {
    return key_change.groups(owner.reviewSlice(), out);
}

/// The current position of `cp` with the keys of the current keyboard.
fn currentPosition(owner: *const control.Controller, cp: u21) ?model.KnownPosition {
    var buf: [lp.max_routes]model.KnownPosition = undefined;
    for (owner.currentPositions(&buf)) |entry| {
        if (entry.pos.cp == cp) return entry;
    }
    return null;
}

fn snapshotLabels(owner: *const control.Controller, board: u64, layer: u8) []const u21 {
    const snapshot = owner.boards.find(board) orelse return &.{};
    return snapshot.layerLabels(layer) orelse snapshot.layerLabels(0) orelse &.{};
}

fn modalFrame(theme: ui.Theme, w: f32, h: f32, tag: []const u8) *dvui.FloatingWindowWidget {
    const screen = dvui.windowRect();
    return dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .rect = .{ .x = (screen.w - w) * 0.5, .y = (screen.h - h) * 0.5, .w = w, .h = h },
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(14),
        .tag = tag,
    });
}

fn sheetHeader(theme: ui.Theme, w: f32, title: []const u8, subtitle: []const u8, close_tag: []const u8) bool {
    const header_bg = dvui.box(@src(), .{}, .{
        .id_extra = 0xe090,
        .rect = .{ .x = 1, .y = 1, .w = w - 2, .h = 83 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .corners = ui.topCorners(13),
        .padding = .{},
        .margin = .{},
    });
    header_bg.deinit();
    boldLabel(title, .{ .x = 24, .y = 16, .w = w - 96, .h = 28 }, 20, theme.text, 0xe091);
    presentation.label(subtitle, .{ .x = 24, .y = 48, .w = w - 96, .h = 22 }, 13.5, theme.muted, null);
    ui.divider(theme, .{ .x = 0, .y = 84, .w = w, .h = 1 }, 0xe092);
    return ui.iconButton(theme, ui.control_icons.remove, "", close_tag, .{ .x = w - 54, .y = 22, .w = 30, .h = 30 }, false);
}

fn statLine(arena: std.mem.Allocator, owner: *const control.Controller, cp: u21) ![]const u8 {
    const st = owner.learning.getStat(cp) orelse return "no data";
    return std.fmt.allocPrint(arena, "{d:.0}% · {d:.0} WPM", .{ st.confidence(owner.config.target_wpm) * 100.0, st.wpm() });
}

fn layerNote(arena: std.mem.Allocator, pos: lp.KeyPosition) ![]const u8 {
    if (pos.combo_slot != null and pos.layer != 0) return std.fmt.allocPrint(arena, "combo on layer {d}", .{pos.layer});
    if (pos.combo_slot != null) return "combo";
    if (pos.layer != 0) return std.fmt.allocPrint(arena, "layer {d} · hold the teal key", .{pos.layer});
    if (pos.shift) return "with Shift";
    return "layer 0";
}

/// Layout changes: one row per moved practised character with Keep or Reset,
/// and the selected one compared on the keyboard it was practised on and on
/// the current one.
fn drawLayoutChangesSheet(
    owner: *const control.Controller,
    sheet: *Sheet,
    theme: ui.Theme,
    ctx: SheetContext,
    pending: *?control.Intent,
) !void {
    var group_buf: [model.max_tracked_keys]u21 = undefined;
    const entries = reviewGroups(owner, &group_buf);
    if (entries.len == 0) {
        sheet.* = .none;
        return;
    }
    const picks = ctx.picks;

    const screen = dvui.windowRect();
    const w: f32 = @min(@as(f32, 1000), screen.w - 40);
    const h: f32 = @min(@as(f32, 600), screen.h - 40);
    var fw = modalFrame(theme, w, h, "practice.sheet.layout_changes");
    defer fw.deinit();

    const arena = dvui.currentWindow().arena();
    const board_name = if (ctx.board_name.len > 0) ctx.board_name else "this keyboard";
    const subtitle = try std.fmt.allocPrint(arena, "Practised characters that sit elsewhere on {s}. Keep their statistics or start them over.", .{board_name});
    if (sheetHeader(theme, w, "Layout changes", subtitle, "practice.layout_changes.close")) {
        sheet.* = .none;
        return;
    }

    const pad: f32 = 24;
    const body_top: f32 = 102;
    const footer_h: f32 = 58;
    const body_h = h - body_top - footer_h - 8;
    const list_w = std.math.clamp(w * 0.34, 250.0, 340.0);
    const visible_rows: usize = @max(2, @as(usize, @intFromFloat((body_h + 8) / 72.0)));
    const visible = entries[0..if (entries.len > visible_rows) visible_rows - 1 else entries.len];
    if (picks.selected == null or std.mem.indexOfScalar(u21, visible, picks.selected.?) == null) picks.selected = entries[0];

    // Left: one row per entry; a long list ends with a note about the rest.
    const row_h: f32 = 64;
    const max_rows: usize = @max(2, @as(usize, @intFromFloat((body_h + 8) / (row_h + 8))));
    const shown = if (entries.len > max_rows) max_rows - 1 else entries.len;
    var resets: usize = 0;
    for (entries[0..shown], 0..) |group, i| {
        const y = body_top + @as(f32, @floatFromInt(i)) * (row_h + 8);
        const reset = picks.has(group);
        if (reset) resets += 1;
        const selected = picks.selected.? == group;
        const row_rect: dvui.Rect = .{ .x = pad, .y = y, .w = list_w, .h = row_h };
        var row_opts = ui.options(theme, row_rect, 13);
        row_opts.id_extra = 0xe100 + i;
        row_opts.background = true;
        row_opts.border = .all(if (selected) 1.5 else 1);
        row_opts.corners = .all(9);
        row_opts.padding = .{};
        row_opts.color_fill = .{ .color = if (selected) ui.mix(theme.panel, theme.accent, 0.10) else theme.panel };
        row_opts.color_border = .{ .color = if (selected) theme.accent else theme.border };
        row_opts.tag = if (i == 0) "practice.layout_changes.row" else null;
        if (dvui.button(@src(), "", .{}, row_opts)) picks.selected = group;

        var text_buf: [4]u8 = undefined;
        const badge: dvui.Rect = .{ .x = pad + 10, .y = y + 14, .w = 36, .h = 36 };
        const tint = if (reset) theme.danger else theme.warning;
        const badge_box = dvui.box(@src(), .{}, .{
            .id_extra = 0xe200 + i,
            .rect = badge,
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, tint, 0.22) },
            .color_border = .{ .color = ui.mix(theme.panel, tint, 0.65) },
            .border = .all(1),
            .corners = .all(7),
            .padding = .{},
            .margin = .{},
        });
        badge_box.deinit();
        dvui.labelNoFmt(@src(), key_change.displayOf(group, &text_buf), .{ .align_x = 0.5, .align_y = 0.5 }, .{
            .id_extra = 0xe240 + i,
            .rect = badge,
            .font = dvui.Font.theme(.mono).withSize(17).withWeight(.bold),
            .color_text = .{ .color = tint },
            .padding = .{},
            .margin = .{},
        });

        const cp = key_change.representative(group, owner.reviewSlice());
        const reason = if (owner.learning.lastKnownPosition(cp)) |old|
            (if (currentPosition(owner, cp)) |now| try key_change.describe(arena, old.pos, now.pos) else "not on this layout")
        else
            "moved";
        const toggle_w: f32 = 116;
        const text_w = @max(0.0, list_w - 56 - toggle_w - 16);
        boldLabel(reason, .{ .x = pad + 56, .y = y + 12, .w = text_w, .h = 20 }, 13.5, theme.text, 0xe280 + i);
        presentation.label(try statLine(arena, owner, cp), .{ .x = pad + 56, .y = y + 34, .w = text_w, .h = 18 }, 12, theme.muted, null);

        const tx = pad + list_w - toggle_w - 10;
        if (pillButton(theme, "Keep", .{ .x = tx, .y = y + 18, .w = 54, .h = 28 }, !reset, 0xe300 + i)) {
            picks.set(group, false);
            picks.selected = group;
        }
        if (pillButton(theme, "Reset", .{ .x = tx + 58, .y = y + 18, .w = 58, .h = 28 }, reset, 0xe340 + i)) {
            picks.set(group, true);
            picks.selected = group;
        }
    }

    if (shown < entries.len) {
        const more = try std.fmt.allocPrint(arena, "{d} more keep their statistics unless you reset them under Settings → Reset characters…", .{entries.len - shown});
        drawWrappedTwoLines(more, .{ .x = pad + 4, .y = body_top + @as(f32, @floatFromInt(shown)) * (row_h + 8) + 8, .w = list_w - 8, .h = 40 }, 12.5, theme.muted, 18, 0xe3f0);
    }

    // Right: before and now keyboards of the selected entry.
    const right_x = pad + list_w + 18;
    const right_w = w - right_x - pad;
    const group = picks.selected.?;
    const cp = key_change.representative(group, owner.reviewSlice());
    const old = owner.learning.lastKnownPosition(cp);
    const now = currentPosition(owner, cp);
    var heading_buf: [4]u8 = undefined;
    const heading = if (old != null and now != null)
        try std.fmt.allocPrint(arena, "{s} · {s}", .{ key_change.displayOf(group, &heading_buf), try key_change.describe(arena, old.?.pos, now.?.pos) })
    else
        key_change.displayOf(group, &heading_buf);
    boldLabel(heading, .{ .x = right_x, .y = body_top, .w = right_w, .h = 22 }, 15, theme.text, 0xe400);

    const boards_top = body_top + 32;
    const boards_h = body_h - 32;
    const side_by_side = right_w >= 620;
    const board_w = if (side_by_side) (right_w - 14) / 2 else right_w;
    const board_h = if (side_by_side) boards_h - 26 else (boards_h - 26 * 2 - 12) / 2;

    // Before: the keyboard it was last practised on, from its saved snapshot.
    const before_info: ?BoardInfo = if (old) |o| if (o.seen) |seen| blk: {
        const snapshot = owner.boards.find(seen.board) orelse break :blk null;
        const lookup = ctx.board_lookup orelse break :blk null;
        break :blk lookup(snapshot.idSlice());
    } else null else null;
    const before_y = boards_top;
    const before_caption = if (before_info != null and old != null)
        try std.fmt.allocPrint(arena, "Before · {s} · {s}", .{ before_info.?.name, try layerNote(arena, old.?.pos) })
    else
        "Before";
    presentation.label(before_caption, .{ .x = right_x, .y = before_y, .w = board_w, .h = 20 }, 12.5, theme.warning, null);
    const before_rect: dvui.Rect = .{ .x = right_x, .y = before_y + 24, .w = board_w, .h = board_h };
    if (before_info) |info| {
        const seen = old.?.seen.?;
        var marks_buf: [3]key_change.Mark = undefined;
        key_change.draw(theme, before_rect, .{
            .geometry = info.geometry,
            .labels = snapshotLabels(owner, seen.board, old.?.pos.layer),
            .marks = key_change.marksFor(seen, .before, &marks_buf),
            .combo = if (seen.combo_key_index) |k| .{ seen.key_index, k } else null,
            .hold_layer = if (seen.layer_key_index != null) old.?.pos.layer else null,
        }, 0xe500, "practice.layout_changes.before");
    } else {
        const empty = dvui.box(@src(), .{}, .{
            .rect = before_rect,
            .background = true,
            .color_fill = .{ .color = theme.bg },
            .color_border = .{ .color = theme.border },
            .border = .all(1),
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        empty.deinit();
        const note = if (old) |o|
            try std.fmt.allocPrint(arena, "The keyboard it was practised on is not known here. It was on {s}.", .{try layerNote(arena, o.pos)})
        else
            "No earlier position is known.";
        drawWrappedTwoLines(note, .{ .x = before_rect.x + 14, .y = before_rect.y + before_rect.h / 2 - 18, .w = before_rect.w - 28, .h = 36 }, 13, theme.muted, 18, 0xe510);
    }

    // Now: the current keyboard.
    const now_x = if (side_by_side) right_x + board_w + 14 else right_x;
    const now_y = if (side_by_side) boards_top else before_y + 24 + board_h + 12;
    const now_caption = if (now) |n|
        try std.fmt.allocPrint(arena, "Now · {s} · {s}", .{ board_name, try layerNote(arena, n.pos) })
    else
        "Now · not on this layout";
    presentation.label(now_caption, .{ .x = now_x, .y = now_y, .w = board_w, .h = 20 }, 12.5, theme.accent, null);
    const now_rect: dvui.Rect = .{ .x = now_x, .y = now_y + 24, .w = board_w, .h = board_h };
    if (now) |n| if (n.seen) |seen| {
        var marks_buf: [3]key_change.Mark = undefined;
        key_change.draw(theme, now_rect, .{
            .geometry = ctx.geometry,
            .labels = snapshotLabels(owner, seen.board, n.pos.layer),
            .marks = key_change.marksFor(seen, .now, &marks_buf),
            .combo = if (seen.combo_key_index) |k| .{ seen.key_index, k } else null,
            .hold_layer = if (seen.layer_key_index != null) n.pos.layer else null,
        }, 0xe600, "practice.layout_changes.now");
    };

    // Footer: keep everything, or apply the choice.
    ui.divider(theme, .{ .x = 0, .y = h - footer_h - 1, .w = w, .h = 1 }, 0xe093);
    const fy = h - footer_h + 12;
    presentation.label("Kept characters keep their statistics on both keyboards.", .{ .x = pad, .y = fy, .w = @max(0, w - pad * 2 - 420), .h = 34 }, 12.5, theme.muted, null);
    const apply = try std.fmt.allocPrint(arena, "Apply · keep {d}, reset {d}", .{ entries.len - resets, resets });
    const apply_w = @max(@as(f32, 200), ui.editorFont(apply, 15).textSize(apply).w + 36);
    if (ui.iconButton(theme, null, apply, "practice.layout_changes.apply", .{ .x = w - pad - apply_w, .y = fy, .w = apply_w, .h = 34 }, true) and pending.* == null) {
        pending.* = .{ .resolve_layout_changes = picks.request(owner.profile.profile_hash) };
    }
    if (ui.button(theme, "Keep all", "practice.layout_changes.keep_all", .{ .x = w - pad - apply_w - 12 - 120, .y = fy, .w = 120, .h = 34 }) and pending.* == null) {
        pending.* = .{ .keep_moved_keys = owner.profile.profile_hash };
    }
}

const ChipGroup = struct { title: []const u8, cps: []const u21, faint: bool = false };

/// Reset characters: practised characters to start over, shown on the
/// current keyboard. Letters stay unlocked.
fn drawResetKeysSheet(
    owner: *const control.Controller,
    sheet: *Sheet,
    theme: ui.Theme,
    ctx: SheetContext,
    pending: *?control.Intent,
) !void {
    const picks = ctx.picks;
    const screen = dvui.windowRect();
    const w: f32 = @min(@as(f32, 1000), screen.w - 40);
    const h: f32 = @min(@as(f32, 600), screen.h - 40);
    var fw = modalFrame(theme, w, h, "practice.sheet.reset_keys");
    defer fw.deinit();
    const arena = dvui.currentWindow().arena();
    if (sheetHeader(theme, w, "Reset characters", "Selected characters start over: speed, accuracy and transitions. Unlocked letters stay unlocked.", "practice.reset_keys.close")) {
        sheet.* = .none;
        return;
    }

    // Entries: letters in unlock order, practised symbols this layout types,
    // and practised characters it cannot type any more.
    const lm = &owner.learning;
    var letters: std.ArrayList(u21) = .empty;
    for (lm.unlock_order[0..lm.unlock_len]) |ch| try letters.append(arena, ch);
    var symbols: std.ArrayList(u21) = .empty;
    var absent: std.ArrayList(u21) = .empty;
    for (lm.stats[0..lm.stat_len]) |st| {
        if (!lm.hasData(st.cp)) continue;
        const group = key_change.groupOf(st.cp);
        if (std.mem.indexOfScalar(u21, letters.items, group) != null) continue;
        const typeable = owner.profile_bound and (owner.profile.routeFor(st.cp) != null or owner.profile.comboFor(st.cp) != null);
        const list = if (typeable) &symbols else &absent;
        if (std.mem.indexOfScalar(u21, list.items, group) == null) try list.append(arena, group);
    }
    std.mem.sort(u21, symbols.items, {}, std.sort.asc(u21));

    const pad: f32 = 24;
    const body_top: f32 = 102;
    const footer_h: f32 = 62;
    const grid_w = std.math.clamp(w * 0.5, 300.0, 500.0);
    const chip_w: f32 = 50;
    const chip_h: f32 = 46;
    const per_row: usize = @max(1, @as(usize, @intFromFloat((grid_w + 6) / (chip_w + 6))));

    var group_buf: [model.max_tracked_keys]u21 = undefined;
    const moved = reviewGroups(owner, &group_buf);
    var y = body_top;
    const chip_groups = [_]ChipGroup{
        .{ .title = "Letters", .cps = letters.items },
        .{ .title = "Punctuation, digits & symbols", .cps = symbols.items },
        .{ .title = "Not on this layout", .cps = absent.items, .faint = true },
    };
    var chip_id: usize = 0;
    for (chip_groups) |cg| {
        if (cg.cps.len == 0) continue;
        presentation.label(cg.title, .{ .x = pad, .y = y, .w = grid_w, .h = 18 }, 12.5, theme.muted, null);
        y += 24;
        for (cg.cps, 0..) |group, i| {
            const col: f32 = @floatFromInt(i % per_row);
            const row: f32 = @floatFromInt(i / per_row);
            const r: dvui.Rect = .{ .x = pad + col * (chip_w + 6), .y = y + row * (chip_h + 6), .w = chip_w, .h = chip_h };
            const has_data = lm.hasData(group) or lm.hasData(key_change.upperOf(group));
            const on = picks.has(group);
            if (try resetChip(owner, theme, r, group, has_data, on, cg.faint, 0xe700 + chip_id) and has_data) {
                picks.set(group, !on);
                picks.confirm = false;
            }
            chip_id += 1;
        }
        y += @as(f32, @floatFromInt((cg.cps.len + per_row - 1) / per_row)) * (chip_h + 6) + 10;
    }

    // Quick choices.
    const qy = @min(y + 2, h - footer_h - 44);
    var qx = pad;
    if (moved.len > 0) {
        const lbl = try std.fmt.allocPrint(arena, "Select moved ({d})", .{moved.len});
        const qw = ui.editorFont(lbl, 13).textSize(lbl).w + 28;
        if (pillButton(theme, lbl, .{ .x = qx, .y = qy, .w = qw, .h = 30 }, false, 0xe800)) {
            for (moved) |group| picks.set(group, true);
            picks.confirm = false;
        }
        qx += qw + 8;
    }
    if (pillButton(theme, "Clear", .{ .x = qx, .y = qy, .w = 70, .h = 30 }, false, 0xe801)) {
        picks.len = 0;
        picks.confirm = false;
    }

    // Right: the current keyboard with the keys of the selected characters.
    const right_x = pad + grid_w + 22;
    const right_w = w - right_x - pad;
    const board_name = if (ctx.board_name.len > 0) ctx.board_name else "this keyboard";
    presentation.label(try std.fmt.allocPrint(arena, "On {s}", .{board_name}), .{ .x = right_x, .y = body_top, .w = right_w, .h = 18 }, 12.5, theme.muted, null);
    var marks: std.ArrayList(key_change.Mark) = .empty;
    var combo: ?[2]u16 = null;
    var notes: std.ArrayList(u8) = .empty;
    var board_hash: ?u64 = null;
    for (picks.slice()) |group| {
        const pos = currentPosition(owner, group) orelse currentPosition(owner, key_change.upperOf(group)) orelse continue;
        const seen = pos.seen orelse continue;
        board_hash = seen.board;
        var buf: [3]key_change.Mark = undefined;
        for (key_change.marksFor(seen, .selected, &buf)) |mark| try marks.append(arena, mark);
        if (seen.combo_key_index) |k| combo = .{ seen.key_index, k };
        if (pos.pos.layer != 0 or pos.pos.combo_slot != null) {
            var tb: [4]u8 = undefined;
            if (notes.items.len > 0) try notes.appendSlice(arena, " · ");
            try notes.print(arena, "{s}: {s}", .{ key_change.displayOf(group, &tb), try layerNote(arena, pos.pos) });
        }
    }
    const board_rect: dvui.Rect = .{ .x = right_x, .y = body_top + 24, .w = right_w, .h = @min(right_w * 0.42, h - body_top - footer_h - 70) };
    key_change.draw(theme, board_rect, .{
        .geometry = ctx.geometry,
        .labels = if (board_hash orelse owner.board_hash) |hash| snapshotLabels(owner, hash, 0) else &.{},
        .marks = marks.items,
        .combo = combo,
    }, 0xe900, "practice.reset_keys.board");
    if (notes.items.len > 0)
        drawWrappedTwoLines(notes.items, .{ .x = right_x, .y = board_rect.y + board_rect.h + 10, .w = right_w, .h = 36 }, 12.5, theme.muted, 18, 0xe910);

    // Footer: two-step confirmation like the profile reset.
    ui.divider(theme, .{ .x = 0, .y = h - footer_h - 1, .w = w, .h = 1 }, 0xe094);
    const fy = h - footer_h + 14;
    const count = picks.len;
    if (!picks.confirm) {
        presentation.label("Streak, daily goal and round history stay as they are.", .{ .x = pad, .y = fy, .w = @max(0, w - pad * 2 - 260), .h = 34 }, 12.5, theme.muted, null);
        const lbl = if (count == 1) "Reset 1 character" else try std.fmt.allocPrint(arena, "Reset {d} characters", .{count});
        if (count == 0) {
            _ = ui.buttonEnabled(theme, "Select characters to reset", "practice.reset_keys.start", .{ .x = w - pad - 240, .y = fy, .w = 240, .h = 34 }, false);
        } else if (ui.dangerButton(theme, null, lbl, "practice.reset_keys.start", .{ .x = w - pad - 240, .y = fy, .w = 240, .h = 34 })) {
            picks.confirm = true;
        }
    } else {
        var names: std.ArrayList(u8) = .empty;
        for (picks.slice(), 0..) |group, i| {
            var tb: [4]u8 = undefined;
            if (i > 0) try names.appendSlice(arena, if (i + 1 == count) " and " else ", ");
            try names.appendSlice(arena, key_change.displayOf(group, &tb));
        }
        const question = try std.fmt.allocPrint(arena, "Reset {s}? Their statistics start over. This cannot be undone.", .{names.items});
        presentation.label(question, .{ .x = pad, .y = fy, .w = @max(0, w - pad * 2 - 310), .h = 34 }, 13, theme.danger, "practice.reset_keys.question");
        if (ui.dangerButton(theme, null, "Confirm reset", "practice.reset_keys.confirm", .{ .x = w - pad - 160, .y = fy, .w = 160, .h = 34 }) and pending.* == null) {
            pending.* = .{ .reset_keys = picks.request(owner.profile.profile_hash) };
        }
        if (ui.button(theme, "Cancel", "practice.reset_keys.cancel", .{ .x = w - pad - 160 - 10 - 120, .y = fy, .w = 120, .h = 34 })) {
            picks.confirm = false;
        }
    }
}

fn resetChip(
    owner: *const control.Controller,
    theme: ui.Theme,
    r: dvui.Rect,
    group: u21,
    has_data: bool,
    on: bool,
    faint: bool,
    id: usize,
) !bool {
    const arena = dvui.currentWindow().arena();
    var opts = ui.options(theme, r, 13);
    opts.id_extra = id;
    opts.background = true;
    opts.border = .all(if (on) 1.5 else 1);
    opts.corners = .all(7);
    opts.padding = .{};
    opts.color_fill = .{ .color = if (on) ui.mix(theme.panel, theme.danger, 0.20) else if (has_data) theme.panel else theme.bg };
    opts.color_border = .{ .color = if (on) theme.danger else theme.border };
    const clicked = dvui.button(@src(), "", .{}, opts);
    var buf: [4]u8 = undefined;
    const text_color = if (on) theme.text else if (!has_data or faint) ui.mix(theme.bg, theme.muted, 0.7) else theme.text;
    dvui.labelNoFmt(@src(), key_change.displayOf(group, &buf), .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = id,
        .rect = .{ .x = r.x, .y = r.y + 3, .w = r.w, .h = r.h * 0.55 },
        .font = dvui.Font.theme(.mono).withSize(16).withWeight(.bold),
        .color_text = .{ .color = text_color },
        .padding = .{},
        .margin = .{},
    });
    const conf = @max(owner.learning.confidenceFor(group), owner.learning.confidenceFor(key_change.upperOf(group)));
    const pct = if (has_data) try std.fmt.allocPrint(arena, "{d:.0}%", .{conf * 100.0}) else "—";
    dvui.labelNoFmt(@src(), pct, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = id,
        .rect = .{ .x = r.x, .y = r.y + r.h * 0.55, .w = r.w, .h = r.h * 0.38 },
        .font = ui.editorFont(pct, 10.5),
        .color_text = .{ .color = if (on) theme.danger else theme.muted },
        .padding = .{},
        .margin = .{},
    });
    return clicked;
}

fn linkButton(theme: ui.Theme, text: []const u8, rect: dvui.Rect, tag: []const u8) bool {
    var opts = ui.options(theme, rect, 12.5);
    opts.tag = tag;
    opts.id_extra = std.hash.Wyhash.hash(0, tag);
    opts.background = false;
    opts.border = .{};
    opts.padding = .{};
    opts.color_text = .{ .color = theme.accent };
    return dvui.button(@src(), text, .{}, opts);
}

test "summarizeRuns handles empty, single, and multi-round histories accurately" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), summarizeRuns(&.{}).count);
    const one = [_]storage.RunRecord{.{ .utc_timestamp = 1, .stage = 1, .wpm = 32, .accuracy = 96, .active_seconds = 30 }};
    const s1 = summarizeRuns(&one);
    try t.expectEqual(@as(usize, 1), s1.count);
    try t.expectEqual(@as(?f32, null), s1.delta_wpm);

    const four = [_]storage.RunRecord{
        .{ .utc_timestamp = 1, .stage = 1, .wpm = 30, .accuracy = 95, .active_seconds = 30 },
        .{ .utc_timestamp = 2, .stage = 1, .wpm = 32, .accuracy = 96, .active_seconds = 30 },
        .{ .utc_timestamp = 3, .stage = 2, .wpm = 38, .accuracy = 97, .active_seconds = 30 },
        .{ .utc_timestamp = 4, .stage = 2, .wpm = 40, .accuracy = 98, .active_seconds = 30 },
    };
    const s4 = summarizeRuns(&four);
    try t.expectApproxEqAbs(@as(f32, 35.0), s4.recent_wpm, 0.01);
    try t.expect(s4.delta_wpm.? > 3.0);

    var many: [120]storage.RunRecord = undefined;
    for (&many, 0..) |*r, i| {
        r.* = .{
            .utc_timestamp = @intCast(1_700_000_000 + i * 60),
            .stage = 2,
            .wpm = 25.0 + @as(f32, @floatFromInt(i)) * 0.25,
            .accuracy = 97.5,
            .active_seconds = 32,
        };
    }
    const s120 = summarizeRuns(&many);
    try t.expectEqual(@as(usize, 120), s120.count);
    try t.expect(s120.recent_wpm > 50.0);
    try t.expect(s120.delta_wpm.? > 15.0);
}
