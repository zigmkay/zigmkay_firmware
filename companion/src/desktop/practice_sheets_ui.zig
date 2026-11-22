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

pub const Sheet = enum { none, stages, progress };

pub const SheetContext = struct {
    board_name: []const u8 = "",
    profile_name: []const u8 = "",
    runs: []const storage.RunRecord = &.{},
    custom_text_buf: *[256]u8,
    custom_text_seeded: *bool,
};

/// Draws whichever secondary sheet (`stages` or `progress`) is open, if any.
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
    }
}

/// Compact floating Settings popover anchored under the top-right gear button.
pub fn drawSettingsPopover(
    owner: *const control.Controller,
    open: *bool,
    confirm_reset: *bool,
    theme: ui.Theme,
    anchor_right: f32,
    anchor_top: f32,
    pending: *?control.Intent,
) !void {
    if (!open.*) return;
    const pop_w: f32 = 304;
    const pop_h: f32 = if (confirm_reset.*) 324 else 300;
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
    const pad: f32 = 14;
    const inner_w = pop_w - pad * 2;

    // Header
    presentation.label("Tutor settings", .{ .x = pad, .y = 10, .w = inner_w - 30, .h = 22 }, 14, theme.text, null);
    if (ui.iconButton(theme, ui.control_icons.remove, "", "practice.settings.close", .{ .x = pop_w - 36, .y = 8, .w = 24, .h = 24 }, false)) {
        open.* = false;
        confirm_reset.* = false;
        return;
    }
    ui.divider(theme, .{ .x = 0, .y = 38, .w = pop_w, .h = 1 }, 0xa001);

    // 1. Target speed (WPM stepper + presets)
    var cy: f32 = 48;
    const wpm_title = try std.fmt.allocPrint(arena, "Target speed: {d:.0} WPM", .{owner.config.target_wpm});
    presentation.label(wpm_title, .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 12, theme.muted, null);
    cy += 22;
    const wpm_presets = [_]f32{ 25, 35, 45, 60, 80 };
    const pw = (inner_w - 16) / 5.0;
    for (wpm_presets, 0..) |preset, i| {
        const active = @abs(owner.config.target_wpm - preset) < 0.5;
        const lbl = try std.fmt.allocPrint(arena, "{d:.0}", .{preset});
        if (pillButton(theme, lbl, .{ .x = pad + @as(f32, @floatFromInt(i)) * (pw + 4), .y = cy, .w = pw, .h = 26 }, active, 0xa100 + i) and pending.* == null) {
            pending.* = .{ .set_target_wpm = preset };
        }
    }
    cy += 36;

    // 2. Daily goal (minutes)
    presentation.label("Daily goal", .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 12, theme.muted, null);
    cy += 22;
    const goals = [_]u16{ 5, 10, 15, 30 };
    const gw = (inner_w - 12) / 4.0;
    for (goals, 0..) |mins, i| {
        const active = owner.config.daily_goal_minutes == mins;
        const lbl = try std.fmt.allocPrint(arena, "{d} min", .{mins});
        if (pillButton(theme, lbl, .{ .x = pad + @as(f32, @floatFromInt(i)) * (gw + 4), .y = cy, .w = gw, .h = 26 }, active, 0xa200 + i) and pending.* == null) {
            pending.* = .{ .set_daily_goal = mins };
        }
    }
    cy += 36;

    // 3. Guidance mode
    presentation.label("Keyboard guidance", .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 12, theme.muted, null);
    cy += 22;
    const gmodes = [_]struct { m: storage.GuidanceMode, lbl: []const u8 }{
        .{ .m = .guided, .lbl = "Guided" },
        .{ .m = .on_hesitation, .lbl = "On hesitation" },
        .{ .m = .free, .lbl = "Free" },
    };
    const gmw = (inner_w - 8) / 3.0;
    for (gmodes, 0..) |gm, i| {
        const active = owner.config.guidance == gm.m;
        if (pillButton(theme, gm.lbl, .{ .x = pad + @as(f32, @floatFromInt(i)) * (gmw + 4), .y = cy, .w = gmw, .h = 26 }, active, 0xa300 + i) and pending.* == null) {
            pending.* = .{ .set_guidance = gm.m };
        }
    }
    cy += 36;

    // 4. Input source
    presentation.label("Input source", .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 12, theme.muted, null);
    cy += 22;
    const sw = (inner_w - 6) / 2.0;
    if (pillButton(theme, "OS keyboard text", .{ .x = pad, .y = cy, .w = sw, .h = 26 }, owner.config.source == .os, 0xa400) and pending.* == null) {
        pending.* = .{ .set_source = .os };
    }
    if (pillButton(theme, "Unflashed draft", .{ .x = pad + sw + 6, .y = cy, .w = sw, .h = 26 }, owner.config.source == .draft, 0xa401) and pending.* == null) {
        pending.* = .{ .set_source = .draft };
    }
    cy += 38;

    // 5. Reset progress (inline two-step confirmation)
    ui.divider(theme, .{ .x = pad, .y = cy - 6, .w = inner_w, .h = 1 }, 0xa002);
    if (!confirm_reset.*) {
        if (ui.dangerButton(theme, null, "Reset profile progress", "practice.settings.reset", .{ .x = pad, .y = cy + 2, .w = inner_w, .h = 28 })) {
            confirm_reset.* = true;
        }
    } else {
        presentation.label("Clear all stats & round history?", .{ .x = pad, .y = cy, .w = inner_w, .h = 18 }, 11.5, theme.danger, null);
        const bw = (inner_w - 6) / 2.0;
        if (ui.dangerButton(theme, null, "Confirm reset", "practice.settings.confirm_reset", .{ .x = pad, .y = cy + 22, .w = bw, .h = 28 }) and pending.* == null) {
            pending.* = .reset_progress;
            confirm_reset.* = false;
            open.* = false;
        }
        if (ui.button(theme, "Cancel", "practice.settings.cancel_reset", .{ .x = pad + bw + 6, .y = cy + 22, .w = bw, .h = 28 })) {
            confirm_reset.* = false;
        }
    }
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
    const h: f32 = @min(@as(f32, 620), screen.h - 40);

    var fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .rect = .{ .x = (screen.w - w) * 0.5, .y = (screen.h - h) * 0.5, .w = w, .h = h },
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(14),
        .tag = "practice.sheet.stages",
    });
    defer fw.deinit();

    const arena = dvui.currentWindow().arena();
    const subtitle = try std.fmt.allocPrint(arena, "Derived from {s} · Any stage freely selectable", .{
        if (ctx.profile_name.len > 0) ctx.profile_name else "your active layout",
    });
    if (ui.sheetHeader(theme, w, "6-Stage Learning Path", subtitle, "practice.sheet.close")) {
        sheet.* = .none;
        return;
    }

    const pad: f32 = 24;
    const grid_top: f32 = 114;
    const narrow = w < 680;
    const cols: usize = if (narrow) 2 else 3;
    const rows: usize = if (narrow) 3 else 2;
    const gap: f32 = 12;
    const card_w = (w - pad * 2 - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const footer_reserve: f32 = 96;
    const card_h = @max(118.0, (h - grid_top - footer_reserve - gap * @as(f32, @floatFromInt(rows - 1))) / @as(f32, @floatFromInt(rows)));

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
            ui.mix(theme.panel, theme.accent, 0.14)
        else if (is_done)
            ui.mix(theme.panel, theme.success, 0.09)
        else
            theme.bg;
        const border = if (is_active)
            theme.accent
        else if (is_done)
            ui.mix(theme.panel, theme.success, 0.55)
        else
            theme.border;

        const clicked = dvui.button(@src(), "", .{}, .{
            .id_extra = 0xb000 + i,
            .tag = try std.fmt.allocPrint(arena, "practice.stage.{d}", .{st.number()}),
            .rect = rect,
            .background = true,
            .color_fill = .{ .color = fill },
            .color_fill_hover = .{ .color = ui.mix(fill, theme.text, 0.06) },
            .color_fill_press = .{ .color = ui.mix(fill, theme.text, 0.12) },
            .color_border = .{ .color = border },
            .border = .all(if (is_active) 1.8 else 1),
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        if (clicked and pending.* == null) {
            pending.* = .{ .set_stage = st };
            sheet.* = .none;
        }

        // Top row: STAGE N + status badge
        const num_str = try std.fmt.allocPrint(arena, "STAGE {d}", .{st.number()});
        presentation.label(num_str, .{ .x = rx + 12, .y = ry + 10, .w = 72, .h = 16 }, 10.5, theme.muted, null);

        const state_str: []const u8 = if (is_active)
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
            .rect = .{ .x = rx + card_w - 118, .y = ry + 10, .w = 106, .h = 16 },
            .font = ui.editorFont(state_str, 10.5),
            .color_text = .{ .color = state_col },
            .padding = .{},
            .margin = .{},
        });

        // Stage title + layout-derived description + progress bar
        presentation.label(st.shortName(), .{ .x = rx + 12, .y = ry + 30, .w = card_w - 24, .h = 22 }, 14.5, theme.text, null);
        const desc = try stageDescription(arena, owner, prof, st);
        presentation.label(desc, .{ .x = rx + 12, .y = ry + 54, .w = card_w - 24, .h = 34 }, 11.5, theme.muted, null);

        const prog = stageProgress(owner, st, home_mastered);
        const bar_y = ry + card_h - 16;
        const bar_w = card_w - 24;
        const track = dvui.box(@src(), .{}, .{
            .id_extra = 0xb200 + i,
            .rect = .{ .x = rx + 12, .y = bar_y, .w = bar_w, .h = 5 },
            .background = true,
            .color_fill = .{ .color = theme.control },
            .corners = .all(2.5),
            .padding = .{},
            .margin = .{},
        });
        track.deinit();
        if (prog > 0.01) {
            const pfill = dvui.box(@src(), .{}, .{
                .id_extra = 0xb300 + i,
                .rect = .{ .x = rx + 12, .y = bar_y, .w = @max(6.0, bar_w * prog), .h = 5 },
                .background = true,
                .color_fill = .{ .color = if (is_done) theme.success else accent_col },
                .corners = .all(2.5),
                .padding = .{},
                .margin = .{},
            });
            pfill.deinit();
        }
    }

    // Bottom Stage 5 / Stage 6 sub-options bar
    const opt_y = h - footer_reserve + 10;
    ui.divider(theme, .{ .x = pad, .y = opt_y - 8, .w = w - pad * 2, .h = 1 }, 0xb400);

    // Left: Stage 5 filter (Mixed | Combos only | Layer 1)
    presentation.label("Stage 5 mode:", .{ .x = pad, .y = opt_y + 4, .w = 94, .h = 24 }, 12, theme.muted, null);
    const s5_x = pad + 96;
    if (pillButton(theme, "Mixed", .{ .x = s5_x, .y = opt_y + 2, .w = 64, .h = 26 }, owner.config.stage5_filter == .mixed, 0xb501) and pending.* == null) {
        pending.* = .{ .set_stage5_filter = .{ .filter = .mixed, .layer = null } };
        sheet.* = .none;
    }
    if (pillButton(theme, "Combos", .{ .x = s5_x + 68, .y = opt_y + 2, .w = 72, .h = 26 }, owner.config.stage5_filter == .combos_only, 0xb502) and pending.* == null) {
        pending.* = .{ .set_stage5_filter = .{ .filter = .combos_only, .layer = null } };
        sheet.* = .none;
    }
    if (pillButton(theme, "Layer 1", .{ .x = s5_x + 144, .y = opt_y + 2, .w = 68, .h = 26 }, owner.config.stage5_filter == .specific_layer, 0xb503) and pending.* == null) {
        pending.* = .{ .set_stage5_filter = .{ .filter = .specific_layer, .layer = 1 } };
        sheet.* = .none;
    }

    // Right / Second row: Stage 6 source (English prose | Zig code | Custom text)
    const s6_x = if (w >= 760) w - pad - 320 else pad;
    const s6_y = if (w >= 760) opt_y else opt_y + 34;
    presentation.label("Stage 6:", .{ .x = s6_x, .y = s6_y + 4, .w = 56, .h = 24 }, 12, theme.muted, null);
    if (pillButton(theme, "Prose", .{ .x = s6_x + 58, .y = s6_y + 2, .w = 64, .h = 26 }, owner.config.stage6_source == .english_prose, 0xb601) and pending.* == null) {
        pending.* = .{ .set_stage6_source = .{ .source = .english_prose } };
        sheet.* = .none;
    }
    if (pillButton(theme, "Zig code", .{ .x = s6_x + 126, .y = s6_y + 2, .w = 76, .h = 26 }, owner.config.stage6_source == .zig_code, 0xb602) and pending.* == null) {
        pending.* = .{ .set_stage6_source = .{ .source = .zig_code, .zig_lesson = owner.config.zig_lesson_index } };
        sheet.* = .none;
    }
    if (pillButton(theme, "Custom", .{ .x = s6_x + 206, .y = s6_y + 2, .w = 72, .h = 26 }, owner.config.stage6_source == .custom_text, 0xb603) and pending.* == null) {
        if (ctx.custom_text_buf[0] != 0) {
            owner.setCustomText(std.mem.sliceTo(ctx.custom_text_buf, 0));
        }
        pending.* = .{ .set_stage6_source = .{ .source = .custom_text } };
        sheet.* = .none;
    }

    // Compact custom text entry field at bottom row
    const custom_y = opt_y + 38;
    if (w >= 760) {
        if (!ctx.custom_text_seeded.*) {
            ctx.custom_text_buf.* = @splat(0);
            const n = @min(owner.custom_text_len, ctx.custom_text_buf.len - 1);
            @memcpy(ctx.custom_text_buf[0..n], owner.custom_text[0..n]);
            ctx.custom_text_seeded.* = true;
        }
        var te_opts = ui.options(theme, .{ .x = pad, .y = custom_y, .w = w - pad * 2 - 120, .h = 30 }, 12);
        te_opts.border = .all(1);
        te_opts.corners = .all(6);
        te_opts.tag = "practice.sheet.custom_text";
        const te = dvui.textEntry(@src(), .{ .text = .{ .buffer = ctx.custom_text_buf }, .placeholder = "Paste custom text for Stage 6…" }, te_opts);
        const submitted = te.enter_pressed;
        te.deinit();
        const use_clicked = ui.button(theme, "Practice text", "practice.sheet.use_custom", .{ .x = w - pad - 112, .y = custom_y, .w = 112, .h = 30 });
        if ((submitted or use_clicked) and pending.* == null) {
            owner.setCustomText(std.mem.sliceTo(ctx.custom_text_buf, 0));
            pending.* = .{ .set_stage6_source = .{ .source = .custom_text } };
            sheet.* = .none;
        }
    }
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
    const h: f32 = @min(@as(f32, 620), screen.h - 40);

    var fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .rect = .{ .x = (screen.w - w) * 0.5, .y = (screen.h - h) * 0.5, .w = w, .h = h },
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(14),
        .tag = "practice.sheet.progress",
    });
    defer fw.deinit();

    const arena = dvui.currentWindow().arena();
    const title = try std.fmt.allocPrint(arena, "Progress · {s}", .{
        if (ctx.profile_name.len > 0) ctx.profile_name else "Active layout",
    });
    const subtitle = try std.fmt.allocPrint(arena, "Profile-scoped · {d} rounds · {d}-day streak · Local storage (ZON)", .{
        owner.learning.total_rounds,
        owner.persisted.streak_days,
    });
    if (ui.sheetHeader(theme, w, title, subtitle, "practice.sheet.close")) {
        sheet.* = .none;
        return;
    }

    // Primary Continue CTA in sheet header
    const cont_lbl = try std.fmt.allocPrint(arena, "Continue Stage {d}", .{owner.config.stage.number()});
    if (ui.iconButton(theme, null, cont_lbl, "practice.sheet.continue", .{ .x = w - 224, .y = 24, .w = 156, .h = 32 }, true)) {
        sheet.* = .none;
        return;
    }

    const pad: f32 = 24;
    const body_top: f32 = 114;
    const body_w = w - pad * 2;
    const body_h = h - body_top - 20;

    // 1. Three KPI cards across top
    const kpi_h: f32 = 76;
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
        "Complete rounds to track trend";
    drawKpiCard(theme, .{ .x = pad, .y = body_top, .w = kpi_w, .h = kpi_h }, "Recent average", avg_wpm_str, delta_str, if (stats.delta_wpm != null and stats.delta_wpm.? >= 0) theme.success else theme.muted, 0xc001);

    const acc_str = if (stats.count > 0)
        try std.fmt.allocPrint(arena, "{d:.1}%", .{stats.recent_acc})
    else
        "—";
    drawKpiCard(theme, .{ .x = pad + kpi_w + kpi_gap, .y = body_top, .w = kpi_w, .h = kpi_h }, "Accuracy", acc_str, "Target ≥ 95%", if (stats.recent_acc >= 95.0 or stats.count == 0) theme.success else theme.warning, 0xc002);

    const unlock_str = try std.fmt.allocPrint(arena, "{d} / {d}", .{ owner.learning.unlocked_count, owner.learning.unlock_len });
    const target_sub = try std.fmt.allocPrint(arena, "Target {d:.0} WPM", .{owner.config.target_wpm});
    drawKpiCard(theme, .{ .x = pad + (kpi_w + kpi_gap) * 2, .y = body_top, .w = kpi_w, .h = kpi_h }, "Unlocked keys", unlock_str, target_sub, theme.accent, 0xc003);

    // 2. Lower 2-column grid: WPM Trend Chart (left) + Weakest Keys & Transitions + Weak-spot CTA (right)
    const lower_y = body_top + kpi_h + 14;
    const lower_h = @max(180.0, body_h - kpi_h - 14);
    const stacked = body_w < 640;
    const left_w = if (stacked) body_w else body_w * 0.56;
    const right_w = if (stacked) body_w else body_w - left_w - 14;
    const chart_h = if (stacked) lower_h * 0.48 else lower_h;
    const weak_y = if (stacked) lower_y + chart_h + 10 else lower_y;
    const weak_h = if (stacked) lower_h - chart_h - 10 else lower_h;

    try drawWpmTrendPanel(owner, theme, .{ .x = pad, .y = lower_y, .w = left_w, .h = chart_h }, ctx.runs);
    try drawWeakSpotsPanel(owner, sheet, theme, .{ .x = if (stacked) pad else pad + left_w + 14, .y = weak_y, .w = right_w, .h = weak_h }, pending);
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
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(9),
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
    presentation.label(title, .{ .x = rect.x + 12, .y = rect.y + 8, .w = rect.w - 24, .h = 16 }, 11, theme.muted, null);
    presentation.label(value, .{ .x = rect.x + 12, .y = rect.y + 26, .w = rect.w - 24, .h = 26 }, 20, theme.text, null);
    presentation.label(sub, .{ .x = rect.x + 12, .y = rect.y + 54, .w = rect.w - 24, .h = 16 }, 11, sub_color, null);
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
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.chart.wpm",
    });
    defer panel.deinit();

    const arena = dvui.currentWindow().arena();
    presentation.label("WPM trend & unlocks", .{ .x = 14, .y = 10, .w = rect.w - 130, .h = 20 }, 13, theme.text, null);
    const target_tag = try std.fmt.allocPrint(arena, "Target {d:.0} WPM", .{owner.config.target_wpm});
    dvui.labelNoFmt(@src(), target_tag, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = rect.w - 120, .y = 10, .w = 106, .h = 20 },
        .font = ui.editorFont(target_tag, 11),
        .color_text = .{ .color = theme.warning },
        .padding = .{},
        .margin = .{},
    });

    if (runs.len < 2) {
        presentation.caption("Complete at least 2 rounds to plot your WPM curve", .{ .x = 16, .y = 40, .w = rect.w - 32, .h = rect.h - 56 }, 13, theme.muted, null);
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

    const plot_x: f32 = 42;
    const plot_y: f32 = 38;
    const plot_w = @max(40.0, rect.w - plot_x - 16);
    const plot_h = @max(40.0, rect.h - plot_y - 24);
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
            .font = dvui.Font.theme(.mono).withSize(10.5),
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
            .rect = .{ .x = px - 2.5, .y = raw_y - 2.5, .w = 5, .h = 5 },
            .background = true,
            .color_fill = .{ .color = if (r.unlocked_char != null) theme.success else theme.accent.opacity(0.45) },
            .corners = .all(2.5),
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
                    .rect = .{ .x = px - 12, .y = @max(plot_y - 4, raw_y - 18), .w = 24, .h = 14 },
                    .font = dvui.Font.theme(.mono).withSize(9.5).withWeight(.bold),
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
    line.build().stroke(.{ .thickness = 2.2, .color = .{ .color = theme.accent } });
}

fn drawWeakSpotsPanel(
    owner: *const control.Controller,
    sheet: *Sheet,
    theme: ui.Theme,
    rect: dvui.Rect,
    pending: *?control.Intent,
) !void {
    const panel = dvui.box(@src(), .{}, .{
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.sheet.weak_panel",
    });
    defer panel.deinit();

    const arena = dvui.currentWindow().arena();
    const pad: f32 = 12;
    presentation.label("Weakest keys & transitions", .{ .x = pad, .y = 10, .w = rect.w - pad * 2, .h = 20 }, 13, theme.text, null);

    var wk_buf: [4]model.KeySummary = undefined;
    const weak_keys = owner.learning.weakestKeys(&wk_buf);
    var wb_buf: [3]model.BigramStat = undefined;
    const weak_bigrams = owner.learning.slowestBigrams(2, &wb_buf);

    var cy: f32 = 36;
    if (weak_keys.len == 0 and weak_bigrams.len == 0) {
        presentation.label("Complete a round to identify your slowest keys and transitions.", .{ .x = pad, .y = cy, .w = rect.w - pad * 2, .h = 36 }, 12, theme.muted, null);
    } else {
        const max_rows: usize = @min(weak_keys.len, 4);
        for (weak_keys[0..max_rows], 0..) |wk, i| {
            const row_h: f32 = 32;
            if (cy + row_h > rect.h - 68) break;
            const row = dvui.box(@src(), .{}, .{
                .id_extra = 0xd000 + i,
                .rect = .{ .x = pad, .y = cy, .w = rect.w - pad * 2, .h = row_h },
                .background = true,
                .color_fill = .{ .color = theme.panel },
                .color_border = .{ .color = theme.border },
                .border = .all(1),
                .corners = .all(7),
                .padding = .{},
                .margin = .{},
            });
            row.deinit();

            var cbuf: [4]u8 = undefined;
            const clen = std.unicode.utf8Encode(wk.cp, &cbuf) catch 0;
            if (clen == 1) cbuf[0] = std.ascii.toUpper(cbuf[0]);
            const kbadge: dvui.Rect = .{ .x = pad + 6, .y = cy + 5, .w = 24, .h = 22 };
            const kb = dvui.box(@src(), .{}, .{
                .id_extra = 0xd100 + i,
                .rect = kbadge,
                .background = true,
                .color_fill = .{ .color = ui.mix(theme.panel, theme.warning, 0.22) },
                .corners = .all(5),
                .padding = .{},
                .margin = .{},
            });
            kb.deinit();
            presentation.caption(cbuf[0..clen], kbadge, 12, theme.warning, null);

            const key_wpm: f32 = if (wk.ema_ms > 0) 12_000.0 / wk.ema_ms else 0;
            const finger_str: []const u8 = if (owner.profile_bound) blk: {
                if (owner.profile.routeFor(wk.cp)) |r| break :blk owner.profile.fingerFor(r.key_index).name();
                break :blk "";
            } else "";
            const meta = if (finger_str.len > 0)
                try std.fmt.allocPrint(arena, "{d:.0} WPM · {d:.0}% · {s}", .{ key_wpm, wk.ema_acc * 100.0, finger_str })
            else
                try std.fmt.allocPrint(arena, "{d:.0} WPM · {d:.0}%", .{ key_wpm, wk.ema_acc * 100.0 });
            presentation.label(meta, .{ .x = pad + 38, .y = cy + 6, .w = @max(0, rect.w - pad * 2 - 108), .h = 20 }, 11, theme.muted, null);

            // Mini confidence bar
            const bw: f32 = 54;
            const bx = rect.w - pad - bw - 8;
            const tr = dvui.box(@src(), .{}, .{
                .id_extra = 0xd200 + i,
                .rect = .{ .x = bx, .y = cy + 13, .w = bw, .h = 6 },
                .background = true,
                .color_fill = .{ .color = theme.control },
                .corners = .all(3),
                .padding = .{},
                .margin = .{},
            });
            tr.deinit();
            const bf = dvui.box(@src(), .{}, .{
                .id_extra = 0xd300 + i,
                .rect = .{ .x = bx, .y = cy + 13, .w = @max(3.0, bw * wk.confidence), .h = 6 },
                .background = true,
                .color_fill = .{ .color = if (wk.confidence >= 1.0) theme.success else theme.warning },
                .corners = .all(3),
                .padding = .{},
                .margin = .{},
            });
            bf.deinit();
            cy += row_h + 6;
        }

        if (weak_bigrams.len > 0 and cy + 24 < rect.h - 54) {
            const bg = weak_bigrams[0];
            var b1: [4]u8 = undefined;
            var b2: [4]u8 = undefined;
            const n1 = std.unicode.utf8Encode(bg.prev, &b1) catch 0;
            const n2 = std.unicode.utf8Encode(bg.cur, &b2) catch 0;
            const bg_text = try std.fmt.allocPrint(arena, "Slowest transition: {s}{s} ({d:.0} ms avg)", .{ b1[0..n1], b2[0..n2], bg.ema_ms });
            presentation.label(bg_text, .{ .x = pad, .y = cy + 2, .w = rect.w - pad * 2, .h = 20 }, 11.5, theme.muted, null);
        }
    }

    // 1-click Weak-spot drill CTA pinned at bottom of panel
    const cta_h: f32 = 42;
    const cta_y = rect.h - cta_h - 10;
    const cta_box = dvui.box(@src(), .{}, .{
        .rect = .{ .x = pad, .y = cta_y, .w = rect.w - pad * 2, .h = cta_h },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, theme.accent, 0.14) },
        .color_border = .{ .color = ui.mix(theme.panel, theme.accent, 0.45) },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
    });
    cta_box.deinit();
    presentation.label("Target bottlenecks (~20 words)", .{ .x = pad + 10, .y = cta_y + 10, .w = @max(0, rect.w - pad * 2 - 160), .h = 22 }, 11.5, theme.text, null);
    if (ui.iconButton(theme, null, "Weak-spot drill", "practice.sheet.weak_spot", .{ .x = rect.w - pad - 146, .y = cta_y + 6, .w = 138, .h = 30 }, true) and pending.* == null) {
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

fn isHomeRowMastered(owner: *const control.Controller) bool {
    const z1 = if (owner.profile_bound and owner.profile.zone1_len > 0)
        owner.profile.zone1Letters()
    else
        owner.learning.unlock_order[0..@min(@as(usize, 8), owner.learning.unlock_len)];
    if (z1.len == 0) return false;
    for (z1) |ch| {
        if (owner.learning.confidenceFor(ch) < 1.0) return false;
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
            const z1 = if (owner.profile_bound and owner.profile.zone1_len > 0)
                owner.profile.zone1Letters()
            else
                owner.learning.unlock_order[0..@min(@as(usize, 8), owner.learning.unlock_len)];
            if (z1.len == 0) break :blk 0.0;
            var sum: f32 = 0;
            for (z1) |ch| sum += owner.learning.confidenceFor(ch);
            break :blk sum / @as(f32, @floatFromInt(z1.len));
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
    st: generator.Stage,
) ![]const u8 {
    return switch (st) {
        .home_row => blk: {
            if (prof) |p| {
                const z1 = p.zone1Letters();
                if (z1.len > 0) {
                    var upper: [26]u8 = undefined;
                    for (z1, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
                    break :blk try std.fmt.allocPrint(arena, "{s} + thumb Space", .{upper[0..z1.len]});
                }
            }
            break :blk "Home-row anchor keys + thumb Space";
        },
        .all_letters => blk: {
            const lm = &owner.learning;
            const focus_c: u8 = if (lm.focus_cp) |f| (if (f <= 127) std.ascii.toUpper(@intCast(f)) else '?') else '-';
            break :blk try std.fmt.allocPrint(arena, "{d}/{d} unlocked · Focus: {c}", .{ lm.unlocked_count, lm.unlock_len, focus_c });
        },
        .shift => blk: {
            if (prof) |p| {
                if (p.has_left_shift and p.has_right_shift) {
                    break :blk "50/50 balanced opposite-hand Shift";
                }
            }
            break :blk "Capitalization with opposite-hand Shift";
        },
        .punctuation_numbers => blk: {
            if (prof) |p| {
                break :blk try std.fmt.allocPrint(arena, "{d} punctuation & {d} digits reachable", .{ p.punctuation_len, p.digits_len });
            }
            break :blk "Punctuation groups & number patterns";
        },
        .layers_combos => blk: {
            if (prof) |p| {
                break :blk try std.fmt.allocPrint(arena, "{d} layer symbols & {d} project combos", .{ p.layer_symbols_len, p.combo_len });
            }
            break :blk "Programming symbols & 2-key combos";
        },
        .free_text => "English prose, Zig code & custom text",
    };
}

fn pillButton(theme: ui.Theme, text: []const u8, rect: dvui.Rect, active: bool, id: usize) bool {
    var opts = ui.options(theme, rect, 11.5);
    opts.id_extra = id;
    opts.background = true;
    opts.border = .all(1);
    opts.corners = .all(6);
    opts.padding = .{};
    opts.color_fill = .{ .color = if (active) ui.mix(theme.panel, theme.accent, 0.24) else theme.control };
    opts.color_border = .{ .color = if (active) theme.accent else theme.border };
    opts.color_text = .{ .color = if (active) theme.text else theme.muted };
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
