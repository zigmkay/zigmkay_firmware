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
    const pad_x: f32 = 12;
    const head_y: f32 = 7;
    const head_h: f32 = 20;

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
        label("Active focus:", .{ .x = pad_x, .y = head_y, .w = 78, .h = head_h }, 11.5, theme.muted, null);
        const badge_rect: dvui.Rect = .{ .x = pad_x + 76, .y = head_y + 1, .w = 24, .h = 18 };
        const fbadge = dvui.box(@src(), .{}, .{
            .rect = badge_rect,
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, theme.warning, 0.22) },
            .color_border = .{ .color = ui.mix(theme.panel, theme.warning, 0.65) },
            .border = .all(1),
            .corners = .all(5),
            .padding = .{},
            .margin = .{},
        });
        fbadge.deinit();
        dvui.labelNoFmt(@src(), upper_ch[0..flen], .{ .align_x = 0.5, .align_y = 0.5 }, .{
            .rect = badge_rect,
            .font = dvui.Font.theme(.mono).withSize(11).withWeight(.bold),
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
        label(detail, .{ .x = pad_x + 106, .y = head_y, .w = @max(0, bounds.w - 260), .h = head_h }, 11.5, theme.text, "practice.focus.summary");
    } else {
        label("Layout key mastery", .{ .x = pad_x, .y = head_y, .w = 200, .h = head_h }, 11.5, theme.muted, null);
    }

    const target_lbl = try std.fmt.allocPrint(arena, "Target speed: {d:.0} WPM", .{owner.config.target_wpm});
    dvui.labelNoFmt(@src(), target_lbl, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = bounds.w - 154, .y = head_y, .w = 142, .h = head_h },
        .font = ui.editorFont(target_lbl, 11.5),
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

    const avail_w = @max(100.0, bounds.w - pad_x * 2 - sep_count * 9.0);
    const gap: f32 = 3.0;
    const chip_w = @max(14.0, (avail_w - gap * @as(f32, @floatFromInt(order.len -| 1))) / @as(f32, @floatFromInt(order.len)));
    const chip_y: f32 = 34;
    const chip_h: f32 = @max(22.0, bounds.h - chip_y - 9);

    var x = pad_x;
    for (order, 0..) |ch, i| {
        if ((has_sep1 and i == home_len) or (has_sep2 and i == unlocked_len)) {
            const sep = dvui.box(@src(), .{}, .{
                .id_extra = 0x5000 + i,
                .rect = .{ .x = x + 2, .y = chip_y + 3, .w = 1, .h = chip_h - 6 },
                .background = true,
                .color_fill = .{ .color = theme.border },
                .padding = .{},
                .margin = .{},
            });
            sep.deinit();
            x += 9.0;
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
            .font = dvui.Font.theme(.mono).withSize(@min(12.0, chip_w * 0.52)).withWeight(if (is_focus) .bold else .normal),
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
    const metrics_h: f32 = 22;
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
    label(metrics_str, .{ .x = pad_x, .y = metrics_y, .w = @max(0, inner_w - 220), .h = metrics_h }, 13, theme.text, "practice.metrics");

    // Daily goal readout + progress bar on right
    const goal_mins: f32 = @floatFromInt(@max(@as(u16, 1), owner.config.daily_goal_minutes));
    const done_mins: f32 = @as(f32, @floatFromInt(owner.persisted.daily_active_seconds)) / 60.0;
    const goal_frac = std.math.clamp(done_mins / goal_mins, 0.0, 1.0);
    const goal_text = try std.fmt.allocPrint(arena, "Daily goal {d:.0}/{d}m", .{ @floor(done_mins), owner.config.daily_goal_minutes });
    const bar_w: f32 = 68;
    const bar_x = bounds.w - pad_x - bar_w;
    dvui.labelNoFmt(@src(), goal_text, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = bar_x - 134, .y = metrics_y, .w = 126, .h = metrics_h },
        .font = ui.editorFont(goal_text, 11.5),
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
    const goal_track = dvui.box(@src(), .{}, .{
        .rect = .{ .x = bar_x, .y = metrics_y + 8, .w = bar_w, .h = 6 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .corners = .all(3),
        .padding = .{},
        .margin = .{},
    });
    goal_track.deinit();
    if (goal_frac > 0.01) {
        const goal_fill = dvui.box(@src(), .{}, .{
            .rect = .{ .x = bar_x, .y = metrics_y + 8, .w = @max(4.0, bar_w * goal_frac), .h = 6 },
            .background = true,
            .color_fill = .{ .color = theme.success },
            .corners = .all(3),
            .padding = .{},
            .margin = .{},
        });
        goal_fill.deinit();
    }

    // 2. Main stage region: either Inline Round Rundown or 3-line Monospace Text Stage
    const stage_y: f32 = 38;
    const footer_h: f32 = 34;
    const stage_h = @max(76.0, bounds.h - stage_y - footer_h - 6);
    const stage_rect: dvui.Rect = .{ .x = pad_x, .y = stage_y, .w = inner_w, .h = stage_h };

    if (s.state == .complete) {
        try drawInlineRundown(owner, theme, stage_rect, now_us, pending);
    } else {
        try drawThreeLineTextStage(owner, theme, stage_rect, focus, status_note, pending);
    }

    // 3. Thin run-progress bar
    const prog_y = stage_y + stage_h + 6;
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

    // 4. Footer row: next-key / finger hint pill (left) + shortcut hints & word counter (right)
    const foot_y = prog_y + 7;
    const foot_h: f32 = 20;
    const hint_text = try formatNextKeyHint(arena, owner, focus, hint, same_hand_shift_nudge);
    label(hint_text, .{ .x = pad_x, .y = foot_y, .w = @max(0, inner_w * 0.62), .h = foot_h }, 12, if (s.current_error) theme.danger else if (same_hand_shift_nudge) theme.warning else theme.muted, "practice.next");

    const words_total = countWords(s.reference[0..s.reference_len]);
    const words_done = countWords(s.reference[0..@min(focus, s.reference_len)]);
    const shortcuts = if (s.state == .complete)
        "Enter / Space Next round"
    else if (s.state == .paused)
        "Esc Resume  ·  Tab New"
    else
        try std.fmt.allocPrint(arena, "Esc Pause  ·  Tab New  ·  {d} / {d} words", .{ words_done, words_total });

    dvui.labelNoFmt(@src(), shortcuts, .{ .align_x = 1, .align_y = 0.5 }, .{
        .rect = .{ .x = pad_x + inner_w * 0.62, .y = foot_y, .w = @max(0, inner_w * 0.38), .h = foot_h },
        .font = ui.editorFont(shortcuts, 11.5),
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

    const font_size: f32 = if (zig_code) 17.0 else @min(@as(f32, 23.0), @max(@as(f32, 16.0), bounds.h * 0.21));
    const mono_font = dvui.Font.theme(.mono).withSize(font_size);
    const cell_w = mono_font.textSize("M").w + 1.5;
    const line_h = @min(bounds.h / 3.2, font_size * 1.6);
    const gutter_x: f32 = if (zig_code) 44.0 else 18.0;
    const columns: usize = @intFromFloat(@max(8.0, @floor((bounds.w - gutter_x - 24.0) / cell_w)));

    var storage: [2048]view.Range = undefined;
    const ranges = view.lines(s.reference[0..s.reference_len], columns, &storage);
    const active_line = view.currentLine(ranges, focus);
    const win = view.visibleThreeLines(ranges.len, active_line);
    const visible_count = win.end - win.start;
    const total_text_h = @as(f32, @floatFromInt(visible_count)) * line_h;
    const top_y = @max(6.0, (bounds.h - total_text_h) * 0.5);

    for (win.start..win.end, 0..) |row_idx, slot| {
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
            const char_rect: dvui.Rect = .{ .x = cx, .y = y + 2, .w = cell_w, .h = @max(12.0, line_h - 4) };
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

            var gbuf: [4]u8 = undefined;
            const cp = s.reference[idx];
            const is_ws = view.whitespace(cp);
            const text = view.glyph(cp, is_cur or (zig_code and cp == '\n'), &gbuf);

            dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5, .ellipsize = false }, .{
                .id_extra = 0x7000 + idx,
                .rect = char_rect,
                .font = dvui.Font.theme(if (is_ws) .body else .mono).withSize(font_size).withWeight(if (is_cur) .bold else .normal),
                .color_text = .{ .color = fg },
                .background = bg_fill != null,
                .color_fill = .{ .color = bg_fill orelse theme.bg },
                .corners = .all(4),
                .padding = .{},
                .margin = .{},
                .tag = if (is_cur) "practice.current" else null,
            });
        }
    }

    // Inline calm status banner when paused / preparing draft / waiting for live
    if (s.state == .paused or status_note.len > 0) {
        const banner_h: f32 = 28;
        const banner_y = bounds.h - banner_h - 6;
        const banner = dvui.box(@src(), .{}, .{
            .rect = .{ .x = 12, .y = banner_y, .w = @max(0, bounds.w - 24), .h = banner_h },
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, theme.accent, 0.14) },
            .color_border = .{ .color = ui.mix(theme.panel, theme.accent, 0.45) },
            .border = .all(1),
            .corners = .all(6),
            .padding = .{},
            .margin = .{},
        });
        defer banner.deinit();

        const msg = if (status_note.len > 0) status_note else "Paused · press Resume or Esc to continue";
        label(msg, .{ .x = 12, .y = 0, .w = @max(0, bounds.w - 140), .h = banner_h }, 12, theme.text, null);
        if (s.state == .paused) {
            if (ui.button(theme, "Resume", "practice.pause", .{ .x = @max(0, bounds.w - 116), .y = 2, .w = 82, .h = 24 }) and pending.* == null) {
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
    label(headline, .{ .x = 16, .y = 10, .w = @max(0, bounds.w - 190), .h = 26 }, 18, theme.success, "practice.result");

    if (rd) |r| {
        if (r.newly_unlocked) |u| {
            const unlock_msg = try std.fmt.allocPrint(arena, "Newly unlocked: {c}", .{std.ascii.toUpper(u)});
            const pill = dvui.box(@src(), .{}, .{
                .rect = .{ .x = 16, .y = 40, .w = 180, .h = 22 },
                .background = true,
                .color_fill = .{ .color = ui.mix(theme.panel, theme.success, 0.22) },
                .color_border = .{ .color = theme.success },
                .border = .all(1),
                .corners = .all(6),
                .padding = .{},
                .margin = .{},
            });
            pill.deinit();
            caption(unlock_msg, .{ .x = 16, .y = 40, .w = 180, .h = 22 }, 12, theme.success, "practice.unlock");
        } else {
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
                if (r.weak_key_len > 0) w_writer.writeAll("   ·   ") catch {};
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
            const sub = if (w_writer.buffered().len > 0) w_writer.buffered() else "Round complete — keep your steady rhythm";
            label(sub, .{ .x = 16, .y = 42, .w = @max(0, bounds.w - 220), .h = 20 }, 12, theme.muted, null);
        }
    }

    label("Press Enter or Space for next round", .{ .x = 16, .y = @max(64, bounds.h - 26), .w = @max(0, bounds.w - 300), .h = 20 }, 12, theme.muted, null);

    // Right actions: Weak-spot drill + primary Next round CTA
    const btn_y = @max(14.0, (bounds.h - 32.0) * 0.5);
    if (ui.iconButton(theme, null, "Next round", "practice.next_round", .{ .x = bounds.w - 138, .y = btn_y, .w = 122, .h = 32 }, true) and pending.* == null) {
        pending.* = .next_round;
    }
    if (bounds.w >= 540) {
        if (ui.button(theme, "Weak-spot drill", "practice.weak_spot", .{ .x = bounds.w - 288, .y = btn_y, .w = 142, .h = 32 }) and pending.* == null) {
            pending.* = .start_weak_spot;
        }
    }
}

/// Clean live telemetry bar for Test keys mode (no scoring, no lessons).
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
    const y: f32 = (bounds.h - 26) * 0.5;

    // Layer badge (avoid redundant "Layer 0 · Layer 1" when the keymap already names it "Layer ...")
    const ltext = if (layer_name.len > 0)
        (if (std.mem.startsWith(u8, layer_name, "Layer"))
            layer_name
        else
            try std.fmt.allocPrint(arena, "Layer {d} · {s}", .{ layer, layer_name }))
    else
        try std.fmt.allocPrint(arena, "Layer {d}", .{layer});
    const lpill = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 14, .y = y, .w = 140, .h = 26 },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, lc, 0.2) },
        .color_border = .{ .color = lc },
        .border = .all(1),
        .corners = .all(13),
        .padding = .{},
        .margin = .{},
    });
    lpill.deinit();
    caption(ltext, .{ .x = 14, .y = y, .w = 140, .h = 26 }, 12, theme.text, null);

    // Held modifiers badges
    const mods = [_]struct { mask: u8, name: []const u8 }{
        .{ .mask = 0x11, .name = "Ctrl" },
        .{ .mask = 0x22, .name = "Shift" },
        .{ .mask = 0x44, .name = "Alt" },
        .{ .mask = 0x88, .name = "Gui" },
    };
    var mx: f32 = 166;
    for (mods, 0..) |m, i| {
        const held = (modifiers & m.mask) != 0;
        const mbox = dvui.box(@src(), .{}, .{
            .id_extra = 0x8000 + i,
            .rect = .{ .x = mx, .y = y, .w = 46, .h = 26 },
            .background = true,
            .color_fill = .{ .color = if (held) ui.mix(theme.panel, theme.accent, 0.28) else theme.control },
            .color_border = .{ .color = if (held) theme.accent else theme.border },
            .border = .all(1),
            .corners = .all(6),
            .padding = .{},
            .margin = .{},
        });
        mbox.deinit();
        caption(m.name, .{ .x = mx, .y = y, .w = 46, .h = 26 }, 11, if (held) theme.text else theme.muted, null);
        mx += 52;
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
        try std.fmt.allocPrint(arena, "Last output: {s}", .{last_txt})
    else
        "Press switches on your keyboard to verify layers, holds, and combos";
    label(emitted, .{ .x = mx + 10, .y = y, .w = @max(0, bounds.w - mx - 190), .h = 26 }, 12, if (owner.test_keys.active_combo_cp != null) ui.layerColor(theme, 4) else theme.muted, "practice.metrics");

    // Source toggle on right
    const src_label = if (owner.config.source == .os) "Input: Keyboard" else "Input: Draft";
    if (ui.button(theme, src_label, "practice.input.source", .{ .x = bounds.w - 156, .y = y, .w = 142, .h = 26 }) and pending.* == null) {
        pending.* = .{ .set_source = if (owner.config.source == .os) .draft else .os };
    }
}

fn formatNextKeyHint(
    arena: std.mem.Allocator,
    owner: *const control.Controller,
    focus: usize,
    hint: ?practice.Hint,
    same_hand_shift_nudge: bool,
) ![]const u8 {
    const s = &owner.session;
    if (s.state == .complete) return "Round complete";
    if (s.current_error) {
        if (focus < s.reference_len) {
            var gb: [4]u8 = undefined;
            const g = view.glyph(s.reference[focus], true, &gb);
            return std.fmt.allocPrint(arena, "Type «{s}» to continue (Stop on error)", .{g});
        }
        return "Type the highlighted key to continue";
    }
    if (focus >= s.reference_len) return "";
    const cp = s.reference[focus];
    var gbuf: [4]u8 = undefined;
    const glyph_str = view.glyph(cp, true, &gbuf);

    if (hint) |h| {
        if (h.combo_key != null) {
            return std.fmt.allocPrint(arena, "Combo: press both highlighted keys → {s}", .{glyph_str});
        }
        if (owner.profile_bound) {
            const p = &owner.profile;
            const finger = p.fingerFor(h.key);
            if (h.layer != 0) {
                return std.fmt.allocPrint(arena, "Next: {s} · Hold Layer {d} + {s}", .{ glyph_str, h.layer, finger.name() });
            }
            if ((h.modifiers & 0x22) != 0) {
                const shift_side = if (p.preferredShiftFor(h.key)) |sp| switch (sp.hand) {
                    .left => "Left Shift",
                    .right => "Right Shift",
                    .neutral => "Shift",
                } else "Shift";
                if (same_hand_shift_nudge) {
                    return std.fmt.allocPrint(arena, "Next: {s} · Hold {s} + {s} · Tip: try opposite-hand Shift", .{ glyph_str, shift_side, finger.name() });
                }
                return std.fmt.allocPrint(arena, "Next: {s} · Hold {s} + {s}", .{ glyph_str, shift_side, finger.name() });
            }
            if (finger != .unknown) {
                const row_str: []const u8 = if (h.key < p.key_count) switch (p.keys[h.key].row_offset) {
                    -1 => " (top row)",
                    1 => " (bottom row)",
                    else => " (home row)",
                } else "";
                return std.fmt.allocPrint(arena, "Next key: {s} · {s}{s}", .{ glyph_str, finger.name(), row_str });
            }
        }
    }
    return std.fmt.allocPrint(arena, "Next key: {s}", .{glyph_str});
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
