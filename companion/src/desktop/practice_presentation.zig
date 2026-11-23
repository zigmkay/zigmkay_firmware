//! Calm flow-first tutor presentation widgets: key-confidence strip, 3-line
//! monospace text stage, inline round rundown, and Test keys telemetry bar.
//! Uses 100% `ui.Theme` / `ui.layerColor` / `ui.mix` tokens.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");

const practice = desktop.practice;
const view = desktop.practice_view;
const control = desktop.practice_controller;
const lp = desktop.practice_layout_profile;
const keyboard_view = @import("practice_keyboard_ui.zig");

pub const Scroll = struct { position: f32 = 0, at: ?u64 = null };

fn rectId(bounds: dvui.Rect) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&bounds));
}

pub fn label(text: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color, tag: ?[]const u8) void {
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0, .align_y = 0.5, .ellipsize = true }, .{
        .rect = bounds,
        .font = ui.editorFont(text, size),
        .color_text = .{ .color = color },
        .margin = .{},
        .padding = .{},
        .tag = tag,
        .id_extra = rectId(bounds),
    });
}

pub fn caption(text: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color, tag: ?[]const u8) void {
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5, .ellipsize = true }, .{
        .rect = bounds,
        .font = ui.editorFont(text, size),
        .color_text = .{ .color = color },
        .margin = .{},
        .padding = .{},
        .tag = tag,
        .id_extra = rectId(bounds),
    });
}

/// Key-confidence strip (adaptive per-key progression): header row + single-row chip strip grouped
/// into Home row | Unlocked | Locked.
pub fn confidenceStrip(owner: *const control.Controller, theme: ui.Theme, bounds: dvui.Rect) !void {
    const card = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.confidence",
    });
    defer card.deinit();

    const arena = dvui.currentWindow().arena();
    const lm = &owner.learning;
    const focus_cp = lm.focus_cp;

    // Header row: Active focus + stats + forecast (left), Target speed (right)
    const pad_x: f32 = 16;
    const head_y: f32 = 8;
    const head_h: f32 = 24;

    if (focus_cp) |fcp| {
        const st = lm.getStat(fcp) orelse desktop.practice_model.KeyStat{ .cp = fcp };
        const key_wpm = st.wpm();
        const key_acc = if (st.acc_initialized) st.ema_acc * 100.0 else 100.0;
        var fbuf: [4]u8 = undefined;
        const flen = std.unicode.utf8Encode(fcp, &fbuf) catch 0;
        var upper_ch: [4]u8 = fbuf;
        if (flen == 1) upper_ch[0] = std.ascii.toUpper(upper_ch[0]);

        const next_unlock: ?u8 = if (lm.unlocked_count < lm.unlock_len) lm.unlock_order[lm.unlocked_count] else null;
        const forecast = lm.forecast();

        // Focus badge pill
        label("Active focus:", .{ .x = pad_x, .y = head_y, .w = 96, .h = head_h }, 14, theme.muted, null);
        const badge_rect: dvui.Rect = .{ .x = pad_x + 96, .y = head_y + 1, .w = 28, .h = 22 };
        const fbadge = dvui.box(@src(), .{}, .{
            .rect = badge_rect,
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, theme.warning, 0.22) },
            .color_border = .{ .color = ui.mix(theme.panel, theme.warning, 0.65) },
            .border = .all(1),
            .corners = .all(6),
            .padding = .{},
            .margin = .{},
        });
        fbadge.deinit();
        dvui.labelNoFmt(@src(), upper_ch[0..flen], .{ .align_x = 0.5, .align_y = 0.5 }, .{
            .rect = badge_rect,
            .font = dvui.Font.theme(.mono).withSize(14).withWeight(.bold),
            .color_text = .{ .color = theme.warning },
            .padding = .{},
            .margin = .{},
        });

        const detail = if (forecast != null and next_unlock != null)
            try std.fmt.allocPrint(arena, "· {d:.0} / {d:.0} WPM · {d:.0}% · ~{d} rounds to unlock {c}", .{
                key_wpm,
                owner.config.target_wpm,
                key_acc,
                forecast.?,
                std.ascii.toUpper(next_unlock.?),
            })
        else if (next_unlock != null)
            try std.fmt.allocPrint(arena, "· {d:.0} / {d:.0} WPM · {d:.0}% · Next: {c}", .{
                key_wpm,
                owner.config.target_wpm,
                key_acc,
                std.ascii.toUpper(next_unlock.?),
            })
        else
            try std.fmt.allocPrint(arena, "· {d:.0} / {d:.0} WPM · {d:.0}% · All letters unlocked", .{
                key_wpm,
                owner.config.target_wpm,
                key_acc,
            });
        label(detail, .{ .x = pad_x + 132, .y = head_y, .w = @max(0, bounds.w - 330), .h = head_h }, 14, theme.text, "practice.focus.summary");
    } else {
        label("Layout key mastery", .{ .x = pad_x, .y = head_y, .w = 220, .h = head_h }, 14, theme.muted, null);
    }

    const target_lbl = try std.fmt.allocPrint(arena, "Target speed: {d:.0} WPM", .{owner.config.target_wpm});
    dvui.labelNoFmt(@src(), target_lbl, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = bounds.w - 196, .y = head_y, .w = 180, .h = head_h },
        .font = ui.editorFont(target_lbl, 14),
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });

    // Single-row chip strip grouped: Home row | Unlocked | Locked
    const order = lm.unlock_order[0..lm.unlock_len];
    if (order.len == 0) return;

    const home_len = if (owner.profile_bound and owner.profile.zone1_len > 0)
        @min(owner.profile.zone1_len, order.len)
    else
        @min(@as(usize, 8), order.len);
    const unlocked_len = @min(lm.unlocked_count, order.len);

    const has_sep1 = home_len > 0 and home_len < order.len;
    const has_sep2 = unlocked_len > home_len and unlocked_len < order.len;
    const sep_count: f32 = @floatFromInt(@as(usize, @intFromBool(has_sep1)) + @as(usize, @intFromBool(has_sep2)));

    const avail_w = @max(100.0, bounds.w - pad_x * 2 - sep_count * 12.0);
    const gap: f32 = 4.0;
    const chip_w = @max(16.0, (avail_w - gap * @as(f32, @floatFromInt(order.len -| 1))) / @as(f32, @floatFromInt(order.len)));
    const chip_y: f32 = 38;
    const chip_h: f32 = @max(26.0, bounds.h - chip_y - 10);

    var x = pad_x;
    for (order, 0..) |ch, i| {
        if ((has_sep1 and i == home_len) or (has_sep2 and i == unlocked_len)) {
            const sep = dvui.box(@src(), .{}, .{
                .id_extra = 0x5000 + i,
                .rect = .{ .x = x + 3, .y = chip_y + 4, .w = 1, .h = chip_h - 8 },
                .background = true,
                .color_fill = .{ .color = theme.border },
                .padding = .{},
                .margin = .{},
            });
            sep.deinit();
            x += 12.0;
        }

        const is_unlocked = i < unlocked_len;
        const is_focus = focus_cp != null and focus_cp.? == ch;
        const conf = lm.confidenceFor(ch);
        const is_mastered = is_unlocked and conf >= 1.0;

        const fill: dvui.Color = if (is_focus)
            ui.mix(theme.panel, theme.warning, 0.24)
        else if (is_mastered)
            ui.mix(theme.panel, theme.success, 0.20)
        else if (is_unlocked)
            ui.mix(theme.panel, theme.accent, 0.18)
        else
            ui.mix(theme.panel, theme.bg, 0.45);

        const border: dvui.Color = if (is_focus)
            theme.warning
        else if (is_mastered)
            ui.mix(theme.panel, theme.success, 0.55)
        else if (is_unlocked)
            ui.mix(theme.panel, theme.accent, 0.5)
        else
            ui.mix(theme.panel, theme.border, 0.6);

        const txt_col: dvui.Color = if (is_focus)
            theme.text
        else if (is_mastered)
            theme.success
        else if (is_unlocked)
            theme.accent
        else
            ui.mix(theme.panel, theme.muted, 0.55);

        const chip_rect: dvui.Rect = .{ .x = x, .y = chip_y, .w = chip_w, .h = chip_h };
        const chip = dvui.box(@src(), .{}, .{
            .id_extra = 0x5100 + i,
            .rect = chip_rect,
            .background = true,
            .color_fill = .{ .color = fill },
            .color_border = .{ .color = border },
            .border = .all(if (is_focus) 1.5 else 1),
            .corners = .all(5),
            .padding = .{},
            .margin = .{},
        });
        chip.deinit();

        const upper = [_]u8{std.ascii.toUpper(ch)};
        dvui.labelNoFmt(@src(), &upper, .{ .align_x = 0.5, .align_y = 0.5 }, .{
            .id_extra = 0x5200 + i,
            .rect = chip_rect,
            .font = dvui.Font.theme(.mono).withSize(@min(16.0, chip_w * 0.56)).withWeight(if (is_focus) .bold else .normal),
            .color_text = .{ .color = txt_col },
            .padding = .{},
            .margin = .{},
        });

        if (is_focus) {
            const bar_w = @min(10.0, chip_w * 0.5);
            const underline = dvui.box(@src(), .{}, .{
                .id_extra = 0x5300 + i,
                .rect = .{ .x = chip_rect.x + (chip_rect.w - bar_w) / 2, .y = chip_rect.y + chip_rect.h - 4, .w = bar_w, .h = 2 },
                .background = true,
                .color_fill = .{ .color = theme.warning },
                .corners = .all(1),
                .padding = .{},
                .margin = .{},
            });
            underline.deinit();
        }

        x += chip_w + gap;
    }
}

/// Calm Typing Panel: metrics + daily goal bar, single 3-line monospace text stage
/// (or inline rundown on completion), run progress bar, and next-key/shortcut footer.
pub fn typingCard(
    owner: *const control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
    focus: usize,
    hint: ?practice.Hint,
    labels: ?*const desktop.label_cache.LabelCache,
    now_us: u64,
    status_note: []const u8,
    same_hand_shift_nudge: bool,
    pending: *?control.Intent,
) !void {
    const card = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.word",
    });
    defer card.deinit();

    const arena = dvui.currentWindow().arena();
    const s = &owner.session;
    const pad_x: f32 = 16;
    const inner_w = @max(0, bounds.w - pad_x * 2);

    // 1. Top metrics row (WPM, Accuracy, Elapsed + Daily Goal bar)
    const metrics_y: f32 = 10;
    const metrics_h: f32 = 26;
    const state_tag: []const u8 = if (s.state == .paused)
        " · Paused"
    else if (s.state == .complete)
        " · Complete"
    else if (owner.config.weak_spot_active)
        " · Weak-spot drill"
    else
        "";
    const metrics_str = try std.fmt.allocPrint(arena, "{d:.0} WPM   ·   {d:.1}% accuracy   ·   {d:.1}s{s}", .{
        s.wpm(now_us),
        s.accuracy(),
        @as(f64, @floatFromInt(s.duration(now_us))) / 1_000_000.0,
        state_tag,
    });
    label(metrics_str, .{ .x = pad_x, .y = metrics_y, .w = @max(0, inner_w - 260), .h = metrics_h }, 15.5, theme.text, "practice.metrics");

    // Daily goal readout + progress bar on right
    const goal_mins: f32 = @floatFromInt(@max(@as(u16, 1), owner.config.daily_goal_minutes));
    const daily = desktop.practice_storage.dailyView(owner.persisted, owner.utc_now_sec);
    const done_mins: f32 = @as(f32, @floatFromInt(daily.active_seconds)) / 60.0;
    const goal_frac = std.math.clamp(done_mins / goal_mins, 0.0, 1.0);
    const goal_text = try std.fmt.allocPrint(arena, "Daily goal {d:.0}/{d}m", .{ @floor(done_mins), owner.config.daily_goal_minutes });
    const bar_w: f32 = 76;
    const bar_x = bounds.w - pad_x - bar_w;
    dvui.labelNoFmt(@src(), goal_text, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = bar_x - 160, .y = metrics_y, .w = 150, .h = metrics_h },
        .font = ui.editorFont(goal_text, 14),
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
    const goal_track = dvui.box(@src(), .{}, .{
        .rect = .{ .x = bar_x, .y = metrics_y + 10, .w = bar_w, .h = 6 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .corners = .all(3),
        .padding = .{},
        .margin = .{},
    });
    goal_track.deinit();
    if (goal_frac > 0.01) {
        const goal_fill = dvui.box(@src(), .{}, .{
            .rect = .{ .x = bar_x, .y = metrics_y + 10, .w = @max(4.0, bar_w * goal_frac), .h = 6 },
            .background = true,
            .color_fill = .{ .color = theme.success },
            .corners = .all(3),
            .padding = .{},
            .margin = .{},
        });
        goal_fill.deinit();
    }

    // 2. Main stage region: either Inline Round Rundown or 3-line Monospace Text Stage
    const stage_y: f32 = 42;
    const footer_h: f32 = 42;
    const stage_h = @max(90.0, bounds.h - stage_y - footer_h - 6);
    const stage_rect: dvui.Rect = .{ .x = pad_x, .y = stage_y, .w = inner_w, .h = stage_h };

    if (s.state == .complete) {
        try drawInlineRundown(owner, theme, stage_rect, now_us, pending);
    } else {
        try drawThreeLineTextStage(owner, theme, stage_rect, focus, status_note, pending);
    }

    // 3. Thin run-progress bar
    const prog_y = stage_y + stage_h + 7;
    const frac = if (s.reference_len == 0)
        @as(f32, 0.0)
    else
        @as(f32, @floatFromInt(s.matched())) / @as(f32, @floatFromInt(s.reference_len));
    const track = dvui.box(@src(), .{}, .{
        .rect = .{ .x = pad_x, .y = prog_y, .w = inner_w, .h = 4 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .corners = .all(2),
        .padding = .{},
        .margin = .{},
    });
    track.deinit();
    if (frac > 0.0) {
        const fill = dvui.box(@src(), .{}, .{
            .rect = .{ .x = pad_x, .y = prog_y, .w = inner_w * frac, .h = 4 },
            .background = true,
            .color_fill = .{ .color = if (s.state == .complete) theme.success else theme.accent },
            .corners = .all(2),
            .padding = .{},
            .margin = .{},
        });
        fill.deinit();
    }

    // 4. Footer row: Next-key / finger hint pill (left) + shortcut hints & word counter (right)
    const foot_y = prog_y + 8;
    const foot_h: f32 = 26;
    const next_info = try formatNextKeyHint(arena, owner, theme, focus, hint, labels, same_hand_shift_nudge);
    const max_pill_w = @max(120.0, inner_w * 0.64);
    const pill_text_w = ui.editorFont(next_info.text, 13.5).textSize(next_info.text).w;
    const pill_w = @min(max_pill_w, pill_text_w + 34.0);
    const pill_fill = if (s.current_error)
        ui.mix(theme.bg, theme.danger, 0.14)
    else if (same_hand_shift_nudge)
        ui.mix(theme.bg, theme.warning, 0.14)
    else
        theme.bg;
    const pill_border = if (s.current_error)
        ui.mix(theme.border, theme.danger, 0.55)
    else if (same_hand_shift_nudge)
        ui.mix(theme.border, theme.warning, 0.55)
    else
        theme.border;

    const hint_pill = dvui.box(@src(), .{}, .{
        .rect = .{ .x = pad_x, .y = foot_y, .w = pill_w, .h = foot_h },
        .background = true,
        .color_fill = .{ .color = pill_fill },
        .color_border = .{ .color = pill_border },
        .border = .all(1),
        .corners = .all(6),
        .padding = .{},
        .margin = .{},
    });
    hint_pill.deinit();

    const dot = dvui.box(@src(), .{}, .{
        .rect = .{ .x = pad_x + 10, .y = foot_y + (foot_h - 8) * 0.5, .w = 8, .h = 8 },
        .background = true,
        .color_fill = .{ .color = next_info.dot_color },
        .corners = .all(4),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();

    label(
        next_info.text,
        .{ .x = pad_x + 24, .y = foot_y, .w = @max(0, pill_w - 32), .h = foot_h },
        13.5,
        next_info.text_color,
        "practice.next",
    );

    const words_total = countWords(s.reference[0..s.reference_len]);
    const words_done = countWords(s.reference[0..@min(focus, s.reference_len)]);
    const shortcuts = if (s.state == .complete)
        "Enter / Space Next round"
    else if (s.state == .paused)
        "Esc Resume  ·  Tab New"
    else
        try std.fmt.allocPrint(arena, "Esc Pause  ·  Tab New  ·  {d} / {d} words", .{ words_done, words_total });

    dvui.labelNoFmt(@src(), shortcuts, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = pad_x + inner_w * 0.64, .y = foot_y, .w = @max(0, inner_w * 0.36), .h = foot_h },
        .font = ui.editorFont(shortcuts, 13.5),
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
}

fn drawThreeLineTextStage(
    owner: *const control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
    focus: usize,
    status_note: []const u8,
    pending: *?control.Intent,
) !void {
    const stage = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = "practice.text",
    });
    defer stage.deinit();

    const s = &owner.session;
    const zig_code = owner.config.stage == .free_text and owner.config.stage6_source == .zig_code;

    if (!owner.active or s.reference_len == 0) {
        caption("Press any key or click Start to begin typing", .{ .x = 12, .y = 0, .w = bounds.w - 24, .h = bounds.h }, 16, theme.muted, null);
        return;
    }

    const has_banner = s.state == .paused or status_note.len > 0;
    const banner_h: f32 = 40;
    const text_region_h = if (has_banner) @max(56.0, bounds.h - banner_h - 10) else bounds.h;
    const max_lines: usize = if (has_banner and text_region_h < 108) 2 else 3;

    const max_font_for_lines = (text_region_h - 10.0) / (@as(f32, @floatFromInt(max_lines)) * 1.48);
    const font_size: f32 = @min(if (zig_code) @as(f32, 20.0) else @as(f32, 28.0), @max(@as(f32, 16.0), max_font_for_lines));
    const mono_font = dvui.Font.theme(.mono).withSize(font_size);
    const cell_w = mono_font.textSize("M").w + 1.5;
    const line_h = @min((text_region_h - 8.0) / @as(f32, @floatFromInt(max_lines)), font_size * 1.54);
    const gutter_x: f32 = if (zig_code) 48.0 else 20.0;
    const columns: usize = @intFromFloat(@max(8.0, @floor((bounds.w - gutter_x - 24.0) / cell_w)));

    var storage: [2048]view.Range = undefined;
    const ranges = view.lines(s.reference[0..s.reference_len], columns, &storage);
    const active_line = view.currentLine(ranges, focus);
    const win_raw = view.visibleThreeLines(ranges.len, active_line);
    const win_end = @min(win_raw.end, win_raw.start + max_lines);
    const visible_count = win_end - win_raw.start;
    const total_text_h = @as(f32, @floatFromInt(visible_count)) * line_h;
    const top_y = @max(6.0, (text_region_h - total_text_h) * 0.5);
    const parent = dvui.parentGet();

    for (win_raw.start..win_end, 0..) |row_idx, slot| {
        const range = ranges[row_idx];
        const y = top_y + @as(f32, @floatFromInt(slot)) * line_h;
        const is_active = (row_idx == active_line);

        if (zig_code) {
            const line_num = std.mem.count(u21, s.reference[0..range.start], &.{'\n'}) + 1;
            dvui.label(@src(), "{d}", .{line_num}, .{
                .id_extra = 0x6000 + row_idx,
                .rect = .{ .x = 8, .y = y, .w = 30, .h = line_h },
                .font = dvui.Font.theme(.mono).withSize(12),
                .color_text = .{ .color = theme.muted },
                .padding = .{},
                .margin = .{},
            });
        }

        const char_count = range.end - range.start;
        const start_x = if (zig_code)
            gutter_x
        else
            @max(18.0, (bounds.w - @as(f32, @floatFromInt(char_count)) * cell_w) * 0.5);

        for (range.start..range.end, 0..) |idx, col| {
            const cx = start_x + @as(f32, @floatFromInt(col)) * cell_w;
            const char_rect: dvui.Rect = .{ .x = cx, .y = y + 1, .w = cell_w, .h = @max(14.0, line_h - 3) };
            const is_cur = (idx == focus);
            const is_wrong = (idx < s.len and s.typed[idx] != s.reference[idx]) or (is_cur and s.current_error);
            const is_typed_ok = idx < s.len and !is_wrong;

            const fg: dvui.Color = if (is_cur and !is_wrong)
                theme.bg
            else if (is_wrong)
                theme.danger
            else if (is_typed_ok)
                theme.success
            else if (is_active)
                theme.text
            else
                theme.muted;

            const bg_fill: ?dvui.Color = if (is_wrong)
                ui.mix(theme.bg, theme.danger, 0.22)
            else if (is_cur)
                theme.warning
            else
                null;

            if (bg_fill != null or is_cur) {
                const cell_box = dvui.box(@src(), .{}, .{
                    .id_extra = 0x7000 + idx,
                    .rect = char_rect,
                    .background = bg_fill != null,
                    .color_fill = .{ .color = bg_fill orelse theme.bg },
                    .corners = .all(4),
                    .padding = .{},
                    .margin = .{},
                    .tag = if (is_cur) "practice.current" else null,
                });
                cell_box.deinit();
            }

            var gbuf: [4]u8 = undefined;
            const cp = s.reference[idx];
            const is_ws = view.whitespace(cp);
            const text = view.glyph(cp, is_cur or (zig_code and cp == '\n'), &gbuf);
            if (text.len > 0) {
                const char_font = dvui.Font.theme(if (is_ws) .body else .mono)
                    .withSize(font_size)
                    .withWeight(if (is_cur) .bold else .normal);
                renderUncroppedGlyph(parent, char_rect, char_font, text, fg);
            }
        }
    }

    // Inline calm status banner when paused / preparing draft / waiting for live
    if (has_banner) {
        const banner_y = bounds.h - banner_h - 6;
        const banner = dvui.box(@src(), .{}, .{
            .rect = .{ .x = 12, .y = banner_y, .w = @max(0, bounds.w - 24), .h = banner_h },
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, theme.accent, 0.14) },
            .color_border = .{ .color = ui.mix(theme.panel, theme.accent, 0.45) },
            .border = .all(1),
            .corners = .all(8),
            .padding = .{},
            .margin = .{},
        });
        defer banner.deinit();

        const msg = if (status_note.len > 0) status_note else "Paused · press Resume or Esc to continue";
        label(msg, .{ .x = 14, .y = 0, .w = @max(0, bounds.w - 160), .h = banner_h }, 14.5, theme.text, null);
        if (s.state == .paused) {
            if (ui.button(theme, "Resume", "practice.pause", .{ .x = @max(0, bounds.w - 134), .y = 4, .w = 98, .h = 32 }) and pending.* == null) {
                pending.* = .resume_run;
            }
        }
    }
}

fn drawInlineRundown(
    owner: *const control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
    now_us: u64,
    pending: *?control.Intent,
) !void {
    const box = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = ui.mix(theme.border, theme.success, 0.45) },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = "practice.rundown",
    });
    defer box.deinit();

    const arena = dvui.currentWindow().arena();
    const s = &owner.session;
    const rd = owner.rundown;

    const wpm_val: f32 = if (rd) |r| r.wpm else @floatCast(s.wpm(now_us));
    const acc_val: f32 = if (rd) |r| r.accuracy else @floatCast(s.accuracy());
    const delta_str: []const u8 = if (rd) |r| blk: {
        if (r.wpm_delta) |d| {
            break :blk try std.fmt.allocPrint(arena, " ({s}{d:.1} WPM)", .{ if (d >= 0) "+" else "", d });
        }
        break :blk "";
    } else "";

    // Left summary: Round complete headline + metrics + unlock highlight
    const headline = try std.fmt.allocPrint(arena, "{d:.0} WPM{s}  ·  {d:.1}% accuracy", .{ wpm_val, delta_str, acc_val });
    label(headline, .{ .x = 18, .y = 12, .w = @max(0, bounds.w - 310), .h = 30 }, 21, theme.success, "practice.result");

    if (rd) |r| {
        var weak_buf: [160]u8 = undefined;
        var w_writer: std.Io.Writer = .fixed(&weak_buf);
        if (r.weak_key_len > 0) {
            w_writer.writeAll("Weakest keys: ") catch {};
            for (r.weak_keys[0..r.weak_key_len], 0..) |wk, i| {
                if (i > 0) w_writer.writeAll(", ") catch {};
                var cb: [4]u8 = undefined;
                const cn = std.unicode.utf8Encode(wk.cp, &cb) catch 0;
                if (cn == 1) cb[0] = std.ascii.toUpper(cb[0]);
                w_writer.print("{s} ({d:.0}%)", .{ cb[0..cn], wk.confidence * 100.0 }) catch {};
            }
        }
        if (r.weak_bigram_len > 0) {
            if (r.weak_key_len > 0) w_writer.writeAll("  ·  ") catch {};
            w_writer.writeAll("Slowest: ") catch {};
            for (r.weak_bigrams[0..r.weak_bigram_len], 0..) |wb, i| {
                if (i > 0) w_writer.writeAll(", ") catch {};
                var b1: [4]u8 = undefined;
                var b2: [4]u8 = undefined;
                const n1 = std.unicode.utf8Encode(wb.prev, &b1) catch 0;
                const n2 = std.unicode.utf8Encode(wb.cur, &b2) catch 0;
                w_writer.print("{s}{s} ({d:.0}ms)", .{ b1[0..n1], b2[0..n2], wb.ema_ms }) catch {};
            }
        }
        const weak_summary = w_writer.buffered();
        const right_reserve: f32 = if (bounds.w >= 540) 320.0 else 160.0;
        const avail_w = @max(0.0, bounds.w - right_reserve - 18.0);

        if (r.newly_unlocked) |u| {
            const unlock_msg = try std.fmt.allocPrint(arena, "Newly unlocked: {c}", .{std.ascii.toUpper(u)});
            const pill_w: f32 = @min(avail_w, @max(@as(f32, 166), ui.editorFont(unlock_msg, 13.5).textSize(unlock_msg).w + 24));
            const pill = dvui.box(@src(), .{}, .{
                .rect = .{ .x = 18, .y = 48, .w = pill_w, .h = 26 },
                .background = true,
                .color_fill = .{ .color = ui.mix(theme.panel, theme.success, 0.22) },
                .color_border = .{ .color = theme.success },
                .border = .all(1),
                .corners = .all(6),
                .padding = .{},
                .margin = .{},
            });
            pill.deinit();
            caption(unlock_msg, .{ .x = 18, .y = 48, .w = pill_w, .h = 26 }, 13.5, theme.success, "practice.unlock");

            if (weak_summary.len > 0) {
                const beside_x = 18.0 + pill_w + 12.0;
                const beside_w = bounds.w - right_reserve - beside_x;
                if (beside_w >= 160.0) {
                    label(weak_summary, .{ .x = beside_x, .y = 48, .w = beside_w, .h = 26 }, 13.5, theme.muted, null);
                } else if (bounds.h >= 122.0) {
                    label(weak_summary, .{ .x = 18, .y = 78, .w = avail_w, .h = 20 }, 13, theme.muted, null);
                }
            }
        } else {
            const sub = if (weak_summary.len > 0) weak_summary else "Round complete — keep your steady rhythm";
            label(sub, .{ .x = 18, .y = 50, .w = avail_w, .h = 22 }, 14, theme.muted, null);
        }
    }

    label("Press Enter or Space for next round", .{ .x = 18, .y = @max(78, bounds.h - 28), .w = @max(0, bounds.w - 320), .h = 22 }, 14, theme.muted, null);

    // Right actions: Weak-spot drill + primary Next round CTA
    const btn_y = @max(14.0, (bounds.h - 36.0) * 0.5);
    if (ui.iconButton(theme, null, "Next round", "practice.next_round", .{ .x = bounds.w - 146, .y = btn_y, .w = 130, .h = 36 }, true) and pending.* == null) {
        pending.* = .next_round;
    }
    if (bounds.w >= 540) {
        if (ui.button(theme, "Weak-spot drill", "practice.weak_spot", .{ .x = bounds.w - 306, .y = btn_y, .w = 150, .h = 36 }) and pending.* == null) {
            pending.* = .start_weak_spot;
        }
    }
}

/// Clean live telemetry bar for Test layout mode (no scoring, no lessons).
pub fn testKeysTelemetryBar(
    owner: *const control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
    layer: usize,
    layer_name: []const u8,
    modifiers: u8,
    pending: *?control.Intent,
) !void {
    const bar = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.test_keys.bar",
    });
    defer bar.deinit();

    const arena = dvui.currentWindow().arena();
    const lc = ui.layerColor(theme, layer);
    const pill_h: f32 = 32;
    const y: f32 = (bounds.h - pill_h) * 0.5;

    // Layer badge (avoid redundant "Layer 0 · Layer 1" when the keymap already names it "Layer ...")
    const ltext = if (layer_name.len > 0)
        (if (std.mem.startsWith(u8, layer_name, "Layer"))
            layer_name
        else
            try std.fmt.allocPrint(arena, "Layer {d} · {s}", .{ layer, layer_name }))
    else
        try std.fmt.allocPrint(arena, "Layer {d}", .{layer});
    const lpill_w: f32 = @min(@as(f32, 200), @max(@as(f32, 148), ui.editorFont(ltext, 14).textSize(ltext).w + 28));
    const lpill = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 14, .y = y, .w = lpill_w, .h = pill_h },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, lc, 0.2) },
        .color_border = .{ .color = lc },
        .border = .all(1.5),
        .corners = .all(pill_h / 2),
        .padding = .{},
        .margin = .{},
    });
    lpill.deinit();
    caption(ltext, .{ .x = 14, .y = y, .w = lpill_w, .h = pill_h }, 14, theme.text, null);

    // Held modifiers badges
    const mods = [_]struct { mask: u8, name: []const u8 }{
        .{ .mask = 0x11, .name = "Ctrl" },
        .{ .mask = 0x22, .name = "Shift" },
        .{ .mask = 0x44, .name = "Alt" },
        .{ .mask = 0x88, .name = "Gui" },
    };
    var mx: f32 = 14 + lpill_w + 14;
    for (mods, 0..) |m, i| {
        const held = (modifiers & m.mask) != 0;
        const mbox = dvui.box(@src(), .{}, .{
            .id_extra = 0x8000 + i,
            .rect = .{ .x = mx, .y = y, .w = 54, .h = pill_h },
            .background = true,
            .color_fill = .{ .color = if (held) ui.mix(theme.panel, theme.accent, 0.28) else theme.control },
            .color_border = .{ .color = if (held) theme.accent else theme.border },
            .border = .all(1),
            .corners = .all(7),
            .padding = .{},
            .margin = .{},
        });
        mbox.deinit();
        caption(m.name, .{ .x = mx, .y = y, .w = 54, .h = pill_h }, 13.5, if (held) theme.text else theme.muted, null);
        mx += 60;
    }

    // Last emitted text / simultaneous presses / combo readout
    const last_txt = owner.test_keys.textSlice();
    const emitted = if (owner.test_keys.active_combo_cp) |ccp| blk: {
        var gbuf: [4]u8 = undefined;
        const g = view.glyph(ccp, true, &gbuf);
        break :blk try std.fmt.allocPrint(arena, "Combo active → {s}", .{g});
    } else if (owner.test_keys.pressed_count >= 2)
        try std.fmt.allocPrint(arena, "{d} keys held simultaneously", .{owner.test_keys.pressed_count})
    else if (last_txt.len > 0)
        try std.fmt.allocPrint(arena, "Last key: {s}", .{last_txt})
    else
        "Press switches on your keyboard to verify layers, holds, and combos";
    label(emitted, .{ .x = mx + 12, .y = y, .w = @max(0, bounds.w - mx - 200), .h = pill_h }, 14, if (owner.test_keys.active_combo_cp != null) ui.layerColor(theme, 4) else theme.muted, "practice.metrics");

    // Source toggle on right
    const src_label = if (owner.config.source == .os) "Input: Keyboard" else "Input: Draft";
    if (ui.button(theme, src_label, "practice.input.source", .{ .x = bounds.w - 172, .y = y, .w = 158, .h = pill_h }) and pending.* == null) {
        pending.* = .{ .set_source = if (owner.config.source == .os) .draft else .os };
    }
}

/// Calm free-typing scratchpad card for Test layout mode, matching the Tutor's
/// monospace text stage aesthetic so the user can type anything they want freely.
pub fn testLayoutScratchpad(
    owner: *control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
) !void {
    const card = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.test_keys.scratchpad",
    });
    defer card.deinit();

    const pad_x: f32 = 16;
    const head_y: f32 = 8;
    const head_h: f32 = 28;
    const text = owner.test_keys.scratchpadSlice();

    label("Free typing · test your layout", .{ .x = pad_x, .y = head_y, .w = @max(0, bounds.w - 130), .h = head_h }, 14.5, theme.muted, null);

    if (text.len > 0) {
        if (ui.button(theme, "Clear", "practice.test_keys.clear", .{ .x = bounds.w - pad_x - 76, .y = head_y, .w = 76, .h = 28 })) {
            owner.test_keys.clearScratchpad();
        }
    }

    const stage_y: f32 = 42;
    const stage_h = @max(54.0, bounds.h - stage_y - 12);
    const stage_rect: dvui.Rect = .{ .x = pad_x, .y = stage_y, .w = @max(0, bounds.w - pad_x * 2), .h = stage_h };
    const stage = dvui.box(@src(), .{}, .{
        .rect = stage_rect,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = "practice.test_keys.input",
    });
    defer stage.deinit();

    if (text.len == 0) {
        // Placeholder + calm cursor cue
        const ph = "Type anything here to test your layout…";
        const ph_font = dvui.Font.theme(.mono).withSize(20);
        const caret_h: f32 = 24;
        const caret = dvui.box(@src(), .{}, .{
            .rect = .{ .x = 18, .y = (stage_h - caret_h) * 0.5, .w = 3, .h = caret_h },
            .background = true,
            .color_fill = .{ .color = theme.warning },
            .corners = .all(1.5),
            .padding = .{},
            .margin = .{},
        });
        caret.deinit();
        dvui.labelNoFmt(@src(), ph, .{ .align_x = 0, .align_y = 0.5, .ellipsize = true }, .{
            .rect = .{ .x = 28, .y = 0, .w = @max(0, stage_rect.w - 44), .h = stage_h },
            .font = ph_font,
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
        return;
    }

    // Decode UTF-8 scratchpad text into codepoints and wrap into up to 3 trailing lines.
    var cps: [512]u21 = undefined;
    var cp_len: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp_len >= cps.len) break;
        cps[cp_len] = cp;
        cp_len += 1;
    }

    const font_size: f32 = @min(@as(f32, 26.0), @max(@as(f32, 18.0), stage_h * 0.28));
    const mono_font = dvui.Font.theme(.mono).withSize(font_size);
    const cell_w = mono_font.textSize("M").w + 1.5;
    const line_h = @min(stage_h / 2.2, font_size * 1.48);
    const cols: usize = @intFromFloat(@max(8.0, @floor((stage_rect.w - 40.0) / cell_w)));

    var ranges_buf: [256]view.Range = undefined;
    const ranges = view.lines(cps[0..cp_len], cols, &ranges_buf);
    const max_vis: usize = if (stage_h >= 104) 3 else 2;
    const start_row = if (ranges.len > max_vis) ranges.len - max_vis else 0;
    const vis = ranges[start_row..];
    const total_h = @as(f32, @floatFromInt(vis.len)) * line_h;
    const top_y = @max(6.0, (stage_h - total_h) * 0.5);

    const parent = dvui.parentGet();
    var caret_x: f32 = 18;
    var caret_y: f32 = top_y;
    for (vis, 0..) |r, slot| {
        const y = top_y + @as(f32, @floatFromInt(slot)) * line_h;
        var col: usize = 0;
        for (r.start..r.end) |idx| {
            const cp = cps[idx];
            if (cp == '\n') continue;
            const cx = 18.0 + @as(f32, @floatFromInt(col)) * cell_w;
            var gbuf: [4]u8 = undefined;
            const g = view.glyph(cp, false, &gbuf);
            if (g.len > 0) {
                renderUncroppedGlyph(parent, .{ .x = cx, .y = y, .w = cell_w, .h = line_h }, mono_font, g, theme.text);
            }
            col += 1;
        }
        caret_x = 18.0 + @as(f32, @floatFromInt(col)) * cell_w;
        caret_y = y;
    }

    // Trailing amber cursor bar
    const caret_h = @max(14.0, font_size * 1.05);
    const caret = dvui.box(@src(), .{}, .{
        .rect = .{ .x = @min(caret_x + 2, stage_rect.w - 14), .y = caret_y + (line_h - caret_h) * 0.5, .w = 3, .h = caret_h },
        .background = true,
        .color_fill = .{ .color = theme.warning },
        .corners = .all(1.5),
        .padding = .{},
        .margin = .{},
    });
    caret.deinit();
}

/// Renders a single glyph centered inside `cell` via `dvui.renderText` without
/// `LabelWidget`'s tight `textHeight()` clip rect so deep descenders (`j`, `g`,
/// `p`, `q`, `y`) are never chopped off.
fn renderUncroppedGlyph(
    parent: dvui.Widget,
    cell: dvui.Rect,
    font: dvui.Font,
    text: []const u8,
    color: dvui.Color,
) void {
    const text_size = font.textSize(text);
    const visual_h = text_size.h * 1.14;
    const gx = cell.x + (cell.w - text_size.w) * 0.5;
    const gy = cell.y + (cell.h - visual_h) * 0.5;
    const rs = parent.screenRectScale(.{ .x = gx, .y = gy, .w = text_size.w, .h = visual_h });
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = rs,
        .color = color,
    }) catch {};
}

const NextKeyInfo = struct {
    text: []const u8,
    dot_color: dvui.Color,
    text_color: dvui.Color,
};

fn keyBaseTapLabel(arena: std.mem.Allocator, labels: ?*const desktop.label_cache.LabelCache, key_index: usize) !?[]const u8 {
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

fn formatNextKeyHint(
    arena: std.mem.Allocator,
    owner: *const control.Controller,
    theme: ui.Theme,
    focus: usize,
    hint: ?practice.Hint,
    labels: ?*const desktop.label_cache.LabelCache,
    same_hand_shift_nudge: bool,
) !NextKeyInfo {
    const s = &owner.session;
    if (s.state == .complete) {
        return .{ .text = "Round complete", .dot_color = theme.success, .text_color = theme.success };
    }
    if (s.current_error) {
        if (focus < s.reference_len) {
            var gb: [4]u8 = undefined;
            const g = view.glyph(s.reference[focus], true, &gb);
            return .{
                .text = try std.fmt.allocPrint(arena, "Type «{s}» to continue (Stop on error)", .{g}),
                .dot_color = theme.danger,
                .text_color = theme.danger,
            };
        }
        return .{ .text = "Type the highlighted key to continue", .dot_color = theme.danger, .text_color = theme.danger };
    }
    if (focus >= s.reference_len) {
        return .{ .text = "", .dot_color = theme.muted, .text_color = theme.muted };
    }
    const cp = s.reference[focus];
    var gbuf: [4]u8 = undefined;
    const glyph_str = view.glyph(cp, true, &gbuf);
    const display_key: []const u8 = if (glyph_str.len == 1 and std.ascii.isAlphabetic(glyph_str[0])) blk: {
        const up = try arena.alloc(u8, 1);
        up[0] = std.ascii.toUpper(glyph_str[0]);
        break :blk up;
    } else glyph_str;

    if (hint) |h| {
        if (h.combo_key != null) {
            return .{
                .text = try std.fmt.allocPrint(arena, "Combo: press both highlighted keys → {s}", .{glyph_str}),
                .dot_color = ui.layerColor(theme, 4),
                .text_color = theme.text,
            };
        }
        if (owner.profile_bound) {
            const p = &owner.profile;
            const finger = p.fingerFor(h.key);
            const fcol = if (finger != .unknown) keyboard_view.fingerColor(theme, finger) else theme.accent;

            if (h.layer != 0) {
                return .{
                    .text = try std.fmt.allocPrint(arena, "Next: {s} · Hold Layer {d} + {s}", .{ glyph_str, h.layer, finger.name() }),
                    .dot_color = ui.mix(ui.layerColor(theme, 5), theme.accent, 0.35),
                    .text_color = theme.text,
                };
            }
            if ((h.modifiers & 0x22) != 0) {
                const sp_opt = p.preferredShiftFor(h.key);
                const shift_side = if (sp_opt) |sp| switch (sp.hand) {
                    .left => "Left Shift",
                    .right => "Right Shift",
                    .neutral => "Shift",
                } else "Shift";
                const shift_key_lbl = if (sp_opt) |sp| try keyBaseTapLabel(arena, labels, sp.key_index) else null;
                const shift_desc = if (shift_key_lbl) |sk|
                    try std.fmt.allocPrint(arena, "{s} ({s})", .{ shift_side, sk })
                else
                    shift_side;
                if (same_hand_shift_nudge) {
                    return .{
                        .text = try std.fmt.allocPrint(arena, "Next: {s} · Hold {s} + {s} · Tip: opposite-hand Shift", .{ glyph_str, shift_desc, finger.name() }),
                        .dot_color = theme.warning,
                        .text_color = theme.warning,
                    };
                }
                return .{
                    .text = try std.fmt.allocPrint(arena, "Next: {s} · Hold {s} + {s}", .{ glyph_str, shift_desc, finger.name() }),
                    .dot_color = ui.mix(ui.layerColor(theme, 5), theme.accent, 0.35),
                    .text_color = theme.text,
                };
            }
            if (finger != .unknown) {
                const row_str: []const u8 = if (h.key < p.key_count) switch (p.keys[h.key].row_offset) {
                    -1 => "top row",
                    1 => "bottom row",
                    else => "home row",
                } else "";
                const anchor_lbl: ?[]const u8 = if (p.homeAnchorFor(finger)) |ak|
                    (if (ak != h.key) try keyBaseTapLabel(arena, labels, ak) else null)
                else
                    null;

                const txt = if (anchor_lbl) |al|
                    try std.fmt.allocPrint(arena, "Next: {s} · {s} ({s} · Home anchor: {s})", .{ display_key, finger.name(), row_str, al })
                else if (row_str.len > 0)
                    try std.fmt.allocPrint(arena, "Next: {s} · {s} ({s})", .{ display_key, finger.name(), row_str })
                else
                    try std.fmt.allocPrint(arena, "Next: {s} · {s}", .{ display_key, finger.name() });
                return .{ .text = txt, .dot_color = fcol, .text_color = theme.text };
            }
        }
    }
    return .{
        .text = try std.fmt.allocPrint(arena, "Next key: {s}", .{display_key}),
        .dot_color = theme.accent,
        .text_color = theme.muted,
    };
}

fn countWords(cps: []const u21) usize {
    var count: usize = 0;
    var in_word = false;
    for (cps) |cp| {
        if (view.whitespace(cp)) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            count += 1;
        }
    }
    return count;
}
