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
const key_change = @import("practice_key_change_ui.zig");
const key_progress = desktop.practice_key_progress;
const tap_hold_ui = @import("practice_tap_hold_ui.zig");
const scratchpad = desktop.practice_scratchpad;

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

pub const StripOptions = struct {
    /// Keycap labels, for what a tap/hold key does while held.
    labels: ?*const desktop.label_cache.LabelCache = null,
    /// Shows this chip's hover card without the pointer (gallery fixtures).
    forced_tooltip: ?u21 = null,
};

/// Key-confidence strip (adaptive per-key progression): header row + single-row chip strip grouped
/// into Home row | Unlocked | Locked. Returns whether a hover card asked for
/// the tap/hold details of the Progress sheet.
pub fn confidenceStrip(owner: *const control.Controller, theme: ui.Theme, bounds: dvui.Rect, options: StripOptions) !bool {
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
    const focus_cp = owner.lessonFocus();

    // Header row: Active focus + stats + forecast (left), Target speed (right)
    const pad_x: f32 = 16;
    const head_y: f32 = 8;
    const head_h: f32 = 24;

    if (focus_cp) |fcp| {
        const st = lm.getStat(fcp) orelse desktop.practice_model.KeyStat{ .cp = fcp };
        var fbuf: [4]u8 = undefined;
        const flen = std.unicode.utf8Encode(fcp, &fbuf) catch 0;
        var upper_ch: [4]u8 = fbuf;
        if (flen == 1) upper_ch[0] = std.ascii.toUpper(upper_ch[0]);

        const next_unlock: ?u8 = if (lm.unlocked_count < lm.unlock_len) lm.unlock_order[lm.unlocked_count] else null;

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

        // Name what the focus key still needs, in the same terms as the chips:
        // speed against the target and first-try hits in its last presses.
        const kp = key_progress.of(st, owner.config.target_wpm);
        const speed_txt = try std.fmt.allocPrint(arena, "Speed {d:.0} / {d:.0} WPM{s}", .{
            kp.wpm,
            owner.config.target_wpm,
            if (kp.speedOk()) " ✓" else "",
        });
        const hits_txt = if (kp.window == 0)
            "No presses yet"
        else if (kp.hitsOk())
            try std.fmt.allocPrint(arena, "Hits {d} of last {d} ✓", .{ kp.hits, kp.window })
        else
            try std.fmt.allocPrint(arena, "Hits {d} of last {d} · needs {d}", .{ kp.hits, kp.window, kp.hits_needed });
        const tail_txt = if (next_unlock) |n|
            try std.fmt.allocPrint(arena, "Next: {c}", .{std.ascii.toUpper(n)})
        else
            "All letters unlocked";
        const ok_col = theme.success;
        const miss_col = theme.warning;
        const segments = [_]struct { text: []const u8, color: dvui.Color }{
            .{ .text = "· ", .color = theme.muted },
            .{ .text = speed_txt, .color = if (kp.speedOk()) ok_col else miss_col },
            .{ .text = " · ", .color = theme.muted },
            .{ .text = hits_txt, .color = if (kp.window > 0 and kp.hitsOk()) ok_col else miss_col },
            .{ .text = " · ", .color = theme.muted },
            .{ .text = tail_txt, .color = theme.text },
        };
        var sx: f32 = pad_x + 132;
        const right_edge = bounds.w - 200;
        for (segments, 0..) |seg, si| {
            if (sx >= right_edge) break;
            const seg_w = ui.editorFont(seg.text, 14).textSize(seg.text).w + 1;
            dvui.labelNoFmt(@src(), seg.text, .{ .align_x = 0, .align_y = 0.5, .ellipsize = true }, .{
                .id_extra = 0x5600 + si,
                .rect = .{ .x = sx, .y = head_y, .w = @min(seg_w, right_edge - sx), .h = head_h },
                .font = ui.editorFont(seg.text, 14),
                .color_text = .{ .color = seg.color },
                .padding = .{},
                .margin = .{},
                .tag = if (si == 1) "practice.focus.summary" else null,
            });
            sx += seg_w;
        }
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

    // Single-row chip strip grouped: First letters | Unlocked | Locked
    const order = lm.unlock_order[0..lm.unlock_len];
    if (order.len == 0) return false;
    var open_details = false;
    const profile: ?*const lp.LayoutProfile = if (owner.profile_bound) &owner.profile else null;

    const home_len = @min(lm.firstLetters().len, order.len);
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
        const is_mastered = is_unlocked and lm.isGreen(ch);

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
        const chip_phys = chip.data().borderRectScale().r;
        chip.deinit();

        // Unlocked keys with practice show speed and recent hits under the
        // letter, so the label moves up to make room.
        const chip_stat: ?desktop.practice_model.KeyStat = if (is_unlocked) lm.getStat(ch) else null;
        const show_meter = chip_stat != null and chip_stat.?.samples > 0 and chip_h >= 30;
        const label_rect: dvui.Rect = if (show_meter) .{ .x = chip_rect.x, .y = chip_rect.y, .w = chip_rect.w, .h = chip_rect.h - 7 } else chip_rect;

        const upper = [_]u8{std.ascii.toUpper(ch)};
        dvui.labelNoFmt(@src(), &upper, .{ .align_x = 0.5, .align_y = 0.5 }, .{
            .id_extra = 0x5200 + i,
            .rect = label_rect,
            .font = dvui.Font.theme(.mono).withSize(@min(16.0, chip_w * 0.56)).withWeight(if (is_focus) .bold else .normal),
            .color_text = .{ .color = txt_col },
            .padding = .{},
            .margin = .{},
        });

        // A moved practised letter waits for the layout-change answer.
        const moved = for (owner.reviewSlice()) |cp| {
            if (key_change.groupOf(cp) == ch) break true;
        } else false;
        if (moved) {
            const dot = dvui.box(@src(), .{}, .{
                .id_extra = 0x5400 + i,
                .rect = .{ .x = chip_rect.x + chip_rect.w - 8, .y = chip_rect.y + 3, .w = 5, .h = 5 },
                .background = true,
                .color_fill = .{ .color = theme.warning },
                .corners = .all(2.5),
                .padding = .{},
                .margin = .{},
            });
            dot.deinit();
        }

        // A key that keeps holding or tapping by mistake gets a small marker.
        const th_summary: ?desktop.practice_model.TapHoldSummary = if (is_unlocked) owner.tapHoldSummary(ch) else null;
        const th: ?TapHoldCard = if (th_summary) |s| if (s.window > 0) .{
            .summary = s,
            .role = try tap_hold_ui.roleOfChar(arena, profile, options.labels, ch),
        } else null else null;
        if (th) |th_card| tap_hold_ui.chipMarker(theme, chip_rect, th_card.summary, th_card.role, i);

        if (show_meter) {
            const kp = key_progress.of(chip_stat.?, owner.config.target_wpm);
            chipMeter(theme, chip_rect, kp, is_mastered, i);
            const forced = options.forced_tooltip != null and options.forced_tooltip.? == ch;
            if (try keyTooltip(theme, chip_phys, ch, chip_stat.?, kp, th, forced, i)) open_details = true;
        } else if (is_focus) {
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
    return open_details;
}

/// The tap/hold window of a chip's key and what the key does while held.
const TapHoldCard = struct {
    summary: desktop.practice_model.TapHoldSummary,
    role: tap_hold_ui.Role,
};

fn fillRect(rect: dvui.Rect, color: dvui.Color, id: usize) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const b = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = color },
        .corners = .all(@min(rect.h, rect.w) / 2),
        .padding = .{},
        .margin = .{},
    });
    b.deinit();
}

/// Two hairline bars under a chip's letter: speed toward the target (left)
/// and first-try hits in the last presses (right, with a tick at the gate).
fn chipMeter(theme: ui.Theme, chip: dvui.Rect, kp: key_progress.KeyProgress, mastered: bool, i: usize) void {
    const total_w = @max(12.0, chip.w * 0.7);
    const half_w = (total_w - 2) / 2;
    const x0 = chip.x + (chip.w - total_w) / 2;
    const y = chip.y + chip.h - 8;
    const h: f32 = 3;
    const track = ui.mix(theme.panel, theme.border, 0.9);
    const presses_ok = kp.pressesOk();
    const speed_col = if (mastered) theme.success else if (presses_ok) ui.mix(theme.accent, theme.text, 0.15) else ui.mix(theme.panel, theme.muted, 0.6);
    const hits_col = if (mastered or (presses_ok and kp.hitsOk())) theme.success else if (presses_ok) theme.warning else ui.mix(theme.panel, theme.muted, 0.6);

    fillRect(.{ .x = x0, .y = y, .w = half_w, .h = h }, track, 0x5700 + i * 8);
    fillRect(.{ .x = x0, .y = y, .w = half_w * kp.speed_fraction, .h = h }, speed_col, 0x5700 + i * 8 + 1);
    const hx = x0 + half_w + 2;
    fillRect(.{ .x = hx, .y = y, .w = half_w, .h = h }, track, 0x5700 + i * 8 + 2);
    fillRect(.{ .x = hx, .y = y, .w = half_w * kp.hitFraction(), .h = h }, hits_col, 0x5700 + i * 8 + 3);
    if (kp.window > 0 and !mastered) {
        const gate_x = hx + half_w * (@as(f32, @floatFromInt(kp.hits_needed)) / @as(f32, @floatFromInt(kp.window)));
        const tick = dvui.box(@src(), .{}, .{
            .id_extra = 0x5700 + i * 8 + 4,
            .rect = .{ .x = @min(gate_x, hx + half_w - 1), .y = y - 1, .w = 1, .h = h + 2 },
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, theme.text, 0.7) },
            .padding = .{},
            .margin = .{},
        });
        tick.deinit();
    }
}

fn tooltipLine(text: []const u8, color: dvui.Color, size: f32, weight: dvui.Font.Weight, id: usize) void {
    dvui.labelNoFmt(@src(), text, .{}, .{
        .id_extra = id,
        .font = ui.editorFont(text, size).withWeight(weight),
        .color_text = .{ .color = color },
        .padding = .{ .y = 1, .h = 1 },
        .margin = .{},
    });
}

/// Hover card for a chip: what the key still needs, in plain numbers, and
/// for a tap/hold key how its taps and holds go. Returns whether "Details in
/// Progress" was clicked.
fn keyTooltip(
    theme: ui.Theme,
    active: dvui.Rect.Physical,
    ch: u8,
    st: desktop.practice_model.KeyStat,
    kp: key_progress.KeyProgress,
    th: ?TapHoldCard,
    forced: bool,
    i: usize,
) !bool {
    var tt: dvui.FloatingTooltipWidget = undefined;
    // The tap/hold card has a link, so it stays open under the pointer.
    tt.init(@src(), .{ .active_rect = active, .position = .vertical, .interactive = th != null }, .{
        .id_extra = 0x5800 + i,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{ .x = 12, .y = 9, .w = 12, .h = 9 },
        .min_size_content = .{ .w = if (th != null) 330 else 260 },
    });
    defer tt.deinit();
    if (forced) tt.showing = true;
    if (!tt.shown()) return false;

    const arena = dvui.currentWindow().arena();
    const up = std.ascii.toUpper(ch);
    const title = switch (kp.blocker) {
        .none => std.fmt.allocPrint(arena, "{c} · green: fast and accurate enough", .{up}),
        .presses => std.fmt.allocPrint(arena, "{c} · not green yet: {d} more presses to judge it", .{ up, model_min_samples -| kp.presses }),
        .hits => std.fmt.allocPrint(arena, "{c} · not green yet: {d} {s} too many in its last {d}", .{
            up,
            kp.hits_needed -| kp.hits,
            if (kp.hits_needed -| kp.hits == 1) "miss" else "misses",
            kp.window,
        }),
        .speed => std.fmt.allocPrint(arena, "{c} · not green yet: {d:.0} of {d:.0} WPM", .{ up, kp.wpm, kp.target_wpm }),
    } catch return false;
    tooltipLine(title, theme.text, 13.5, .bold, 0);

    const speed = std.fmt.allocPrint(arena, "Speed     {d:.0} / {d:.0} WPM{s}", .{ kp.wpm, kp.target_wpm, if (kp.speedOk()) "  ✓" else "" }) catch return false;
    tooltipLine(speed, if (kp.speedOk()) theme.success else theme.muted, 12.5, .normal, 1);
    const hits = if (kp.window == 0)
        "Hits      no presses yet"
    else
        std.fmt.allocPrint(arena, "Hits      {d} of last {d} · needs {d}{s}", .{ kp.hits, kp.window, kp.hits_needed, if (kp.hitsOk()) "  ✓" else "" }) catch return false;
    tooltipLine(hits, if (kp.window > 0 and kp.hitsOk()) theme.success else theme.muted, 12.5, .normal, 2);
    const presses = std.fmt.allocPrint(arena, "Presses   {d} · needs {d}{s}", .{ kp.presses, model_min_samples, if (kp.pressesOk()) "  ✓" else "" }) catch return false;
    tooltipLine(presses, if (kp.pressesOk()) theme.success else theme.muted, 12.5, .normal, 3);

    const foot = if (key_progress.oldestMissLeavesIn(st)) |n|
        std.fmt.allocPrint(arena, "A miss counts for {d} presses; the oldest one stops counting in {d}.", .{ desktop.practice_model.accuracy_window, n }) catch return false
    else
        "Every press of the last 30 was right on the first try.";
    tooltipLine(foot, theme.muted, 11.5, .normal, 4);
    const card = th orelse return false;
    return tap_hold_ui.tooltipSection(theme, ch, card.summary, card.role);
}

const model_min_samples = desktop.practice_model.min_samples_for_mastery;

/// Calm Typing Panel: metrics + daily goal bar, single 3-line monospace text stage
/// (or inline rundown on completion), run progress bar, and next-key/shortcut footer.
pub const StripChoice = enum { none, review };

pub const layout_change_strip_h: f32 = 46;

/// Whether the layout-change question may show: practised characters moved
/// and no round is being typed. It never interrupts a run.
pub fn showsLayoutChangeStrip(owner: *const control.Controller) bool {
    return owner.config.mode == .tutor and owner.reviewSlice().len > 0 and owner.session.state != .running;
}

/// Asks once whether practised characters that moved keep their statistics.
pub fn layoutChangeStrip(
    owner: *const control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
    pending: *?control.Intent,
) !StripChoice {
    const strip = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = ui.mix(theme.panel, theme.warning, 0.55) },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.layout_changes.strip",
    });
    defer strip.deinit();

    const arena = dvui.currentWindow().arena();
    var group_buf: [desktop.practice_model.max_tracked_keys]u21 = undefined;
    const entries = key_change.groups(owner.reviewSlice(), &group_buf);
    if (entries.len == 0) return .none;
    const dot = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 14, .y = bounds.h / 2 - 4, .w = 8, .h = 8 },
        .background = true,
        .color_fill = .{ .color = theme.warning },
        .corners = .all(4),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();

    var choice: StripChoice = .none;
    const by: f32 = (bounds.h - 30) / 2;
    var rx = bounds.w - 10;
    var name_buf: [4]u8 = undefined;
    const text = if (entries.len == 1) blk: {
        const group = entries[0];
        const name = key_change.displayOf(group, &name_buf);
        const reset_lbl = try std.fmt.allocPrint(arena, "Reset {s}", .{name});
        const reset_w = ui.editorFont(reset_lbl, 14).textSize(reset_lbl).w + 30;
        rx -= reset_w;
        if (ui.dangerButton(theme, null, reset_lbl, "practice.layout_changes.reset_one", .{ .x = rx, .y = by, .w = reset_w, .h = 30 }) and pending.* == null) {
            var request: control.KeyReset = .{ .profile_hash = owner.profile.profile_hash };
            request.add(group);
            pending.* = .{ .resolve_layout_changes = request };
        }
        rx -= 8 + 132;
        if (ui.button(theme, "Keep statistics", "practice.layout_changes.keep_one", .{ .x = rx, .y = by, .w = 132, .h = 30 }) and pending.* == null) {
            pending.* = .{ .keep_moved_keys = owner.profile.profile_hash };
        }
        rx -= 8 + 116;
        if (ui.button(theme, "Show change", "practice.layout_changes.show", .{ .x = rx, .y = by, .w = 116, .h = 30 })) choice = .review;

        const cp = key_change.representative(group, owner.reviewSlice());
        var buf: [desktop.practice_layout_profile.max_routes]desktop.practice_model.KnownPosition = undefined;
        const now = for (owner.currentPositions(&buf)) |entry| {
            if (entry.pos.cp == cp) break entry;
        } else null;
        const reason = if (owner.learning.lastKnownPosition(cp)) |old| if (now) |n|
            try key_change.describe(arena, old.pos, n.pos)
        else
            "moved" else "moved";
        break :blk try std.fmt.allocPrint(arena, "{s} sits elsewhere on this keyboard ({s}). Keep its statistics or practise it from scratch?", .{ name, reason });
    } else blk: {
        rx -= 150;
        if (ui.iconButton(theme, null, "Review changes…", "practice.layout_changes.review", .{ .x = rx, .y = by, .w = 150, .h = 30 }, true)) choice = .review;
        rx -= 8 + 100;
        if (ui.button(theme, "Keep all", "practice.layout_changes.keep_all_strip", .{ .x = rx, .y = by, .w = 100, .h = 30 }) and pending.* == null) {
            pending.* = .{ .keep_moved_keys = owner.profile.profile_hash };
        }
        var names: std.ArrayList(u8) = .empty;
        for (entries, 0..) |group, i| {
            if (i > 0) try names.appendSlice(arena, "  ");
            try names.appendSlice(arena, key_change.displayOf(group, &name_buf));
        }
        break :blk try std.fmt.allocPrint(arena, "{d} practised characters sit elsewhere on this keyboard: {s}", .{ entries.len, names.items });
    };
    label(text, .{ .x = 32, .y = 0, .w = @max(0, rx - 44), .h = bounds.h }, 14, theme.text, "practice.layout_changes.question");
    return choice;
}

pub const help_strip_h: f32 = 52;

pub const HelpButton = struct { text: []const u8, tag: []const u8, primary: bool = false, intent: control.Intent };

/// A calm two-line notice above the text with up to three buttons on the
/// right; the rightmost is the suggested one.
fn helpStrip(
    theme: ui.Theme,
    bounds: dvui.Rect,
    color: dvui.Color,
    tag: []const u8,
    title: []const u8,
    sub: []const u8,
    buttons: []const HelpButton,
    pending: *?control.Intent,
) void {
    const strip = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = ui.mix(theme.panel, color, 0.55) },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = tag,
    });
    defer strip.deinit();
    const dot = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 14, .y = bounds.h / 2 - 4, .w = 8, .h = 8 },
        .background = true,
        .color_fill = .{ .color = color },
        .corners = .all(4),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();

    const by: f32 = (bounds.h - 30) / 2;
    var rx = bounds.w - 10;
    var i = buttons.len;
    while (i > 0) : (i -= 1) {
        const b = buttons[i - 1];
        const w = ui.editorFont(b.text, 14).textSize(b.text).w + 30;
        rx -= w;
        const rect: dvui.Rect = .{ .x = rx, .y = by, .w = w, .h = 30 };
        const clicked = if (b.primary) ui.iconButton(theme, null, b.text, b.tag, rect, true) else ui.button(theme, b.text, b.tag, rect);
        if (clicked and pending.* == null) pending.* = b.intent;
        rx -= 8;
    }
    const text_w = @max(0, rx - 44);
    label(title, .{ .x = 32, .y = 6, .w = text_w, .h = 21 }, 14, theme.text, null);
    label(sub, .{ .x = 32, .y = 26, .w = text_w, .h = 20 }, 12.5, theme.muted, null);
}

/// Stuck help: shown once a letter has gone `control.stuck_after_rounds`
/// lessons without progress. It stays while typing and never stops it.
pub fn stuckHelp(owner: *const control.Controller) ?control.StuckHelp {
    if (owner.config.mode != .tutor) return null;
    return owner.stuckHelp();
}

pub fn stuckStrip(
    owner: *const control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
    help: control.StuckHelp,
    pending: *?control.Intent,
) !void {
    const arena = dvui.currentWindow().arena();
    const up = if (help.cp < 128) std.ascii.toUpper(@intCast(help.cp)) else '?';
    const kp = help.progress;
    const dismiss_text = "Dismiss · Ctrl+Backspace";
    switch (help.reason) {
        .hits => {
            const title = try std.fmt.allocPrint(arena, "{c} keeps slipping. {d} of its last {d} presses were right; it needs {d}.", .{ up, kp.hits, kp.window, kp.hits_needed });
            const practise = try std.fmt.allocPrint(arena, "Practise {c} slowly · Ctrl+P", .{up});
            helpStrip(theme, bounds, theme.accent, "practice.stuck.strip", title, "Slow down a little and aim for clean presses. Speed comes back on its own.", &.{
                .{ .text = dismiss_text, .tag = "practice.stuck.dismiss", .intent = .{ .dismiss_stuck = help.cp } },
                .{ .text = practise, .tag = "practice.stuck.practise", .primary = true, .intent = .{ .practise_key = .{ .cp = help.cp, .slow = true } } },
            }, pending);
        },
        .speed => {
            const title = try std.fmt.allocPrint(arena, "{c} is accurate but not yet at {d:.0} WPM ({d:.0} WPM for {d} lessons).", .{ up, owner.config.target_wpm, kp.wpm, help.rounds });
            const practise = try std.fmt.allocPrint(arena, "Practise {c} · Ctrl+P", .{up});
            const dismiss: HelpButton = .{ .text = dismiss_text, .tag = "practice.stuck.dismiss", .intent = .{ .dismiss_stuck = help.cp } };
            const practise_btn: HelpButton = .{ .text = practise, .tag = "practice.stuck.practise", .primary = help.lower_target == null, .intent = .{ .practise_key = .{ .cp = help.cp, .slow = false } } };
            if (help.lower_target) |lower| {
                const lower_lbl = try std.fmt.allocPrint(arena, "Lower target to {d:.0} WPM · Ctrl+Down", .{lower});
                helpStrip(theme, bounds, theme.accent, "practice.stuck.strip", title, "That's normal on a new keyboard. You can lower the target and raise it again later.", &.{
                    dismiss,
                    practise_btn,
                    .{ .text = lower_lbl, .tag = "practice.stuck.lower_target", .primary = true, .intent = .{ .set_target_wpm = lower } },
                }, pending);
            } else {
                helpStrip(theme, bounds, theme.accent, "practice.stuck.strip", title, "That's normal on a new keyboard. Speed grows with relaxed, regular practice.", &.{ dismiss, practise_btn }, pending);
            }
        },
    }
}

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
    else if (owner.config.weak_spot_active)
        " · Weak-spot drill"
    else if (owner.slow_round)
        " · Slow round: only clean presses count"
    else if (owner.lesson_bigram) |pair|
        try std.fmt.allocPrint(arena, " · Weak spot: {s}", .{&pair})
    else
        "";
    // Until the first keystroke the row shows how the last lesson went.
    const last = if (s.state == .ready) owner.last_lesson else null;
    const metrics_str = if (last) |l| try std.fmt.allocPrint(arena, "Last lesson   ·   {d:.0} WPM{s}   ·   {d:.1}% accuracy   ·   {d:.1}s{s}", .{
        l.wpm,
        if (l.wpm_delta) |d| try std.fmt.allocPrint(arena, " ({s}{d:.1})", .{ if (d >= 0) "+" else "", d }) else "",
        l.accuracy,
        l.active_seconds,
        if (state_tag.len > 0) state_tag else "   ·   starts on your first key",
    }) else try std.fmt.allocPrint(arena, "{d:.0} WPM   ·   {d:.1}% accuracy   ·   {d:.1}s{s}", .{
        s.wpm(now_us),
        s.accuracy(),
        @as(f64, @floatFromInt(s.duration(now_us))) / 1_000_000.0,
        state_tag,
    });
    label(metrics_str, .{ .x = pad_x, .y = metrics_y, .w = @max(0, inner_w - 260), .h = metrics_h }, 15.5, if (last != null) theme.muted else theme.text, "practice.metrics");

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

    try drawThreeLineTextStage(owner, theme, stage_rect, focus, status_note, pending);

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
            .color_fill = .{ .color = theme.accent },
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
    const loud_error = s.current_error and s.error_mode != .forgive;
    const pill_fill = if (loud_error)
        ui.mix(theme.bg, theme.danger, 0.14)
    else if (same_hand_shift_nudge)
        ui.mix(theme.bg, theme.warning, 0.14)
    else
        theme.bg;
    const pill_border = if (loud_error)
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

    const letters_total = countLetters(s.reference[0..s.reference_len]);
    const letters_done = countLetters(s.reference[0..@min(focus, s.reference_len)]);
    const shortcuts = if (s.state == .paused)
        "Esc Resume  ·  Tab New text"
    else
        try std.fmt.allocPrint(arena, "Esc Pause  ·  Tab New text  ·  {d} / {d} letters", .{ letters_done, letters_total });

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
    const forgiving = s.error_mode == .forgive;

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
            // Forgiving input marks a typo quietly: a dimmer cursor with a thin
            // red line and the wrong key beside it; a character passed with a
            // mistake turns red only once it is behind the cursor.
            const quiet_typo = forgiving and is_cur and s.current_error;
            const is_wrong = if (forgiving)
                s.wasMissed(idx)
            else
                (idx < s.len and s.typed[idx] != s.reference[idx]) or (is_cur and s.current_error);
            const is_typed_ok = idx < s.len and !is_wrong;

            const fg: dvui.Color = if (quiet_typo)
                theme.text
            else if (is_cur and !is_wrong)
                theme.bg
            else if (is_wrong)
                theme.danger
            else if (is_typed_ok)
                theme.success
            else if (is_active)
                theme.text
            else
                theme.muted;

            const bg_fill: ?dvui.Color = if (quiet_typo)
                ui.mix(theme.bg, theme.warning, 0.5)
            else if (is_wrong and !forgiving)
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
            if (quiet_typo) quietTypoMark(theme, char_rect, s.last_wrong_cp, idx);

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

/// A thin red line under the cursor and the wrong key, small, beside it.
fn quietTypoMark(theme: ui.Theme, cell: dvui.Rect, wrong: ?u21, idx: usize) void {
    const line = dvui.box(@src(), .{}, .{
        .id_extra = 0x7800 + idx,
        .rect = .{ .x = cell.x + 2, .y = cell.y + cell.h - 2, .w = @max(2, cell.w - 4), .h = 3 },
        .background = true,
        .color_fill = .{ .color = theme.danger },
        .corners = .all(1.5),
        .padding = .{},
        .margin = .{},
        .tag = "practice.typo",
    });
    line.deinit();
    const cp = wrong orelse return;
    var buf: [4]u8 = undefined;
    const text = view.glyph(cp, true, &buf);
    if (text.len == 0) return;
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0, .align_y = 0 }, .{
        .id_extra = 0x7900 + idx,
        .rect = .{ .x = cell.x + cell.w - 1, .y = cell.y - 6, .w = 18, .h = 18 },
        .font = dvui.Font.theme(.mono).withSize(13),
        .color_text = .{ .color = ui.mix(theme.bg, theme.danger, 0.8) },
        .padding = .{},
        .margin = .{},
    });
}

/// Notices of the last lesson in the top right corner of `area`. They fade
/// out on their own after `control.notice_us`. Only the tap/hold notice takes
/// a click: it returns true to open its section of the Progress sheet.
pub fn lessonNotices(
    owner: *const control.Controller,
    theme: ui.Theme,
    area: dvui.Rect,
    now_us: u64,
    labels: ?*const desktop.label_cache.LabelCache,
) !bool {
    const events = owner.visibleEvents(now_us);
    if (events.len == 0) return false;
    const arena = dvui.currentWindow().arena();
    const age = now_us -| owner.events_at_us;
    const fade_us: u64 = 600_000;
    const left = control.notice_us -| age;
    const alpha: f32 = if (left < fade_us) @as(f32, @floatFromInt(left)) / @as(f32, @floatFromInt(fade_us)) else 1.0;
    var y = area.y + 14;
    var last_id: ?dvui.Id = null;
    var open_details = false;
    const profile: ?*const lp.LayoutProfile = if (owner.profile_bound) &owner.profile else null;
    for (events, 0..) |event, i| {
        const text = switch (event) {
            .new_letter => |ch| try std.fmt.allocPrint(arena, "New letter: {c}", .{std.ascii.toUpper(ch)}),
            .green => |cp| if (cp < 128)
                try std.fmt.allocPrint(arena, "{c} is green now", .{std.ascii.toUpper(@intCast(cp))})
            else
                "A key is green now",
            .daily_goal => "Daily goal reached",
            .stage => |stage| try std.fmt.allocPrint(arena, "On to {s}", .{stage.title()}),
            .tap_hold => |notice| try tap_hold_ui.noticeText(arena, notice, try tap_hold_ui.roleOfChar(arena, profile, labels, notice.cp)),
        };
        const w = @min(area.w - 32, ui.editorFont(text, 14.5).textSize(text).w + 52);
        const rect: dvui.Rect = .{ .x = area.x + area.w - 16 - w, .y = y, .w = w, .h = 38 };
        const color = switch (event) {
            .tap_hold => |notice| if (notice.hold) tap_hold_ui.holdColor(theme) else theme.warning,
            else => theme.success,
        };
        const box = dvui.box(@src(), .{}, .{
            .id_extra = 0x7a00 + i,
            .rect = rect,
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, color, 0.16).opacity(alpha) },
            .color_border = .{ .color = ui.mix(theme.panel, color, 0.6).opacity(alpha) },
            .border = .all(1),
            .corners = .all(9),
            .padding = .{},
            .margin = .{},
            .tag = if (i == 0) "practice.notice" else null,
        });
        last_id = box.data().id;
        if (event == .tap_hold) {
            // The whole notice is a link to the Progress sheet section.
            var click: dvui.ButtonWidget = undefined;
            click.init(@src(), .{}, .{
                .id_extra = 0x7a40 + i,
                .rect = .{ .x = 0, .y = 0, .w = rect.w, .h = rect.h },
                .background = false,
                .padding = .{},
                .margin = .{},
                .tag = "practice.notice.tap_hold",
            });
            click.processEvents();
            if (click.hovered()) dvui.cursorSet(.hand);
            if (click.clicked()) open_details = true;
            click.deinit();
        }
        box.deinit();
        const mark = switch (event) {
            .new_letter, .stage => "+",
            .green, .daily_goal => "✓",
            .tap_hold => |notice| blk: {
                const role = try tap_hold_ui.roleOfChar(arena, profile, labels, notice.cp);
                break :blk if (notice.hold and role.glyph.len > 0 and role.glyph.len <= 3) role.glyph else "!";
            },
        };
        caption(mark, .{ .x = rect.x + 8, .y = rect.y, .w = 22, .h = rect.h }, 16, color.opacity(alpha), null);
        label(text, .{ .x = rect.x + 34, .y = rect.y, .w = w - 40, .h = rect.h }, 14.5, theme.text.opacity(alpha), null);
        y += rect.h + 8;
    }
    // Draw again when the notices start to fade and while they fade.
    if (last_id) |id| {
        const wait = if (left > fade_us) left - fade_us else @min(left, 50_000);
        dvui.timer(id, @intCast(@max(@as(u64, 1), wait)));
    }
    return open_details;
}

/// Clean live telemetry bar for Test layout mode (no scoring, no lessons).
/// Height of the telemetry bar's first row.
pub const telemetry_row_h: f32 = 54;

/// The tap/hold row of the telemetry bar, shown when `tap_holds` is set.
pub const TelemetryTapHolds = struct {
    labels: ?*const desktop.label_cache.LabelCache,
    support: control.TapHoldSupport,
};

pub fn testKeysTelemetryBar(
    owner: *const control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
    layer: usize,
    layer_name: []const u8,
    modifiers: u8,
    tap_holds: ?TelemetryTapHolds,
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
    const y: f32 = (telemetry_row_h - pill_h) * 0.5;
    if (tap_holds) |row| try tap_hold_ui.testRow(owner, theme, .{
        .x = 14,
        .y = telemetry_row_h - 4,
        .w = @max(0, bounds.w - 28),
        .h = tap_hold_ui.test_row_h,
    }, row.labels, row.support);

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
        break :blk try std.fmt.allocPrint(arena, "Combo keys held → {s}", .{g});
    } else if (owner.test_keys.pressed_count >= 2)
        try std.fmt.allocPrint(arena, "{d} keys held simultaneously", .{owner.test_keys.pressed_count})
    else if (last_txt.len > 0) {
        // Last key: [⌥⇧←] select word left
        const x0 = mx + 12;
        const max_x = x0 + @max(0, bounds.w - mx - 200);
        const intro = "Last key:";
        const intro_w = ui.editorFont(intro, 14).textSize(intro).w + 8;
        label(intro, .{ .x = x0, .y = y, .w = @min(intro_w, @max(0, max_x - x0)), .h = pill_h }, 14, theme.muted, "practice.metrics");
        const shown = if (std.mem.eql(u8, last_txt, " ")) "Space" else last_txt;
        const chip_w = @min(ui.editorFont(shown, 13.5).textSize(shown).w + 16, @max(0, max_x - x0 - intro_w));
        const chip_h: f32 = 24;
        const chip = dvui.box(@src(), .{}, .{
            .rect = .{ .x = x0 + intro_w, .y = y + (pill_h - chip_h) * 0.5, .w = chip_w, .h = chip_h },
            .background = true,
            .color_fill = .{ .color = theme.control },
            .color_border = .{ .color = theme.border },
            .border = .all(1),
            .corners = .all(5),
            .padding = .{},
            .margin = .{},
            .tag = "practice.test_keys.last_key",
        });
        chip.deinit();
        caption(shown, .{ .x = x0 + intro_w, .y = y + (pill_h - chip_h) * 0.5, .w = chip_w, .h = chip_h }, 13.5, theme.text, null);
        const action = owner.test_keys.last_action;
        const action_x = x0 + intro_w + chip_w + 8;
        if (action.len > 0 and action_x < max_x)
            label(action, .{ .x = action_x, .y = y, .w = max_x - action_x, .h = pill_h }, 14, theme.muted, null);
        return;
    } else "Press switches on your keyboard to verify layers, holds, and combos";
    label(emitted, .{ .x = mx + 12, .y = y, .w = @max(0, bounds.w - mx - 200), .h = pill_h }, 14, if (owner.test_keys.active_combo_cp != null) ui.layerColor(theme, 4) else theme.muted, "practice.metrics");
}

/// What the Test layout field shows and how it reacts, kept by the view.
pub const TestField = struct {
    /// Every key stays in the field (`practice_ui.consumeInput`); Esc lets go.
    captured: bool = true,
    /// The next Test layout frame captures the field, as on opening it.
    capture_on_show: bool = true,
    /// The field's size in cells as last drawn, for moves by row and page.
    cells: scratchpad.Editor.View = .{ .columns = 72, .rows = 6 },
    /// Wheel movement not yet turned into whole rows.
    wheel: f32 = 0,
    /// Scroll the cursor into view on the next frame.
    reveal: bool = true,
};

/// The rows of text the field shows on a roomy window.
pub const test_field_rows: f32 = 6;
const field_font_size: f32 = 18;
const field_line_h: f32 = 26;
const field_head_h: f32 = 42;
const field_foot_h: f32 = 30;
const field_text_pad: f32 = 6;

/// The field's height for `rows` rows of text.
pub fn testFieldHeight(rows: f32) f32 {
    return field_head_h + rows * field_line_h + field_text_pad * 2 + 2 + field_foot_h;
}

/// A key cap such as Esc in running text; returns its width.
fn keyCap(theme: ui.Theme, text: []const u8, x: f32, y: f32, h: f32) f32 {
    const size: f32 = 12;
    const w = ui.editorFont(text, size).textSize(text).w + 12;
    const cap_h: f32 = 20;
    const top = y + (h - cap_h) * 0.5;
    const cap = dvui.box(@src(), .{}, .{
        .id_extra = rectId(.{ .x = x, .y = top, .w = w, .h = cap_h }),
        .rect = .{ .x = x, .y = top, .w = w, .h = cap_h },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .color_border = .{ .color = theme.border },
        .border = .{ .x = 1, .y = 1, .w = 1, .h = 2 },
        .corners = .all(4),
        .padding = .{},
        .margin = .{},
    });
    cap.deinit();
    caption(text, .{ .x = x, .y = top, .w = w, .h = cap_h - 1 }, size, theme.text, null);
    return w;
}

/// Lays out running text and key caps from the left; returns the next x.
fn runningText(theme: ui.Theme, parts: []const []const u8, x0: f32, y: f32, h: f32, color: dvui.Color, max_x: f32) f32 {
    var x = x0;
    for (parts, 0..) |part, i| {
        if (x >= max_x) break;
        if (i % 2 == 1) {
            x += 5;
            x += keyCap(theme, part, x, y, h) + 5;
        } else {
            const w = ui.editorFont(part, 13.5).textSize(part).w + 1;
            label(part, .{ .x = x, .y = y, .w = @min(w, max_x - x), .h = h }, 13.5, color, null);
            x += w;
        }
    }
    return x;
}

/// The Test layout text field: a multi-line editor that keeps every key
/// while captured, and lets the keyboard steer the app once released.
/// Returns true when a click asks to capture it.
pub fn testLayoutScratchpad(
    owner: *control.Controller,
    theme: ui.Theme,
    bounds: dvui.Rect,
    field: *TestField,
) !bool {
    const editor = &owner.test_keys.field;
    const captured = field.captured;
    const arena = dvui.currentWindow().arena();
    if (captured) {
        // A soft glow around the accent border.
        const glow = dvui.box(@src(), .{}, .{
            .rect = .{ .x = bounds.x - 3, .y = bounds.y - 3, .w = bounds.w + 6, .h = bounds.h + 6 },
            .background = true,
            .color_fill = .{ .color = theme.accent.opacity(0.16) },
            .corners = .all(13),
            .padding = .{},
            .margin = .{},
        });
        glow.deinit();
    }
    const card = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = if (captured) theme.accent else theme.border },
        .border = .all(if (captured) 2 else 1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = "practice.test_keys.scratchpad",
    });
    defer card.deinit();

    const pad_x: f32 = 16;
    const head_y: f32 = 7;
    const head_h: f32 = 28;
    const mac = scratchpad.Platform.native() == .mac;

    // Right of the header: where the cursor is, and Clear.
    const where = editor.lineColumn();
    const position = try std.fmt.allocPrint(arena, "Line {d}, column {d}{s}", .{
        where.line,
        where.column,
        if (editor.full or editor.len == scratchpad.capacity) " · Full (8 KB)" else "",
    });
    const clear_w: f32 = 64;
    var right_x = bounds.w - pad_x;
    if (editor.len > 0) {
        right_x -= clear_w;
        if (ui.button(theme, "Clear", "practice.test_keys.clear", .{ .x = right_x, .y = head_y, .w = clear_w, .h = head_h })) {
            owner.test_keys.clearField();
        }
        right_x -= 8;
    }
    const position_w = ui.editorFont(position, 13.5).textSize(position).w + 2;
    const position_x = @max(pad_x + 200, right_x - position_w);
    label(position, .{ .x = position_x, .y = head_y, .w = right_x - position_x, .h = head_h }, 13.5, theme.muted, "practice.test_keys.position");

    // Left of the header: whether keys stay in the field.
    const head_max = position_x - 12;
    if (captured) {
        const lit = ui.mix(theme.accent, theme.text, 0.3);
        const dot = dvui.box(@src(), .{}, .{
            .rect = .{ .x = pad_x, .y = head_y + head_h * 0.5 - 3.5, .w = 7, .h = 7 },
            .background = true,
            .color_fill = .{ .color = theme.accent },
            .corners = .all(3.5),
            .padding = .{},
            .margin = .{},
        });
        dot.deinit();
        _ = runningText(theme, &.{ "Keys stay in this field ·", "Esc", "to leave" }, pad_x + 15, head_y, head_h, lit, head_max);
    } else {
        _ = runningText(theme, &.{ "Free typing · click here or press", "Enter", "to type again" }, pad_x, head_y, head_h, theme.muted, head_max);
    }

    // The text.
    const box_y = field_head_h;
    const box_h = @max(field_line_h + field_text_pad * 2, bounds.h - box_y - field_foot_h);
    const box_rect: dvui.Rect = .{ .x = pad_x, .y = box_y, .w = @max(0, bounds.w - pad_x * 2), .h = box_h };
    const box = dvui.box(@src(), .{}, .{
        .rect = box_rect,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = "practice.test_keys.input",
    });

    const font = dvui.Font.theme(.mono).withSize(field_font_size);
    const cell_w = font.textSize("M").w + 0.5;
    const text_x: f32 = 14;
    const bar_w: f32 = 10;
    const rows_shown: usize = @intFromFloat(@max(1, @floor((box_h - field_text_pad * 2) / field_line_h)));
    const columns: usize = @intFromFloat(@max(8, @floor((box_rect.w - text_x - bar_w) / cell_w)));
    // A new size, or a text set from outside, scrolls the cursor into view.
    const cells: scratchpad.Editor.View = .{ .columns = columns, .rows = rows_shown };
    if (field.reveal or !std.meta.eql(cells, field.cells)) editor.reveal(cells);
    field.reveal = false;
    field.cells = cells;
    const row_count = editor.rowCount(columns);
    editor.top_row = @min(editor.top_row, row_count -| rows_shown);

    // A click places the cursor (Shift extends the selection) and captures
    // the field; dragging selects; the wheel scrolls.
    var wants_capture = false;
    const data = box.data();
    const content = data.contentRectScale();
    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, data)) continue;
        const mouse = switch (event.evt) {
            .mouse => |mouse| mouse,
            else => continue,
        };
        const local = content.pointFromPhysical(mouse.p);
        const row = editor.top_row + @as(usize, @intFromFloat(@max(0, @floor((local.y - field_text_pad) / field_line_h))));
        const column: usize = @intFromFloat(@max(0, @round((local.x - text_x) / cell_w)));
        switch (mouse.action) {
            .focus => event.handle(@src(), data),
            .press => if (mouse.button.pointer()) {
                event.handle(@src(), data);
                dvui.captureMouse(data, event.num);
                editor.pointAt(row, column, columns, mouse.mod.shift());
                wants_capture = true;
            },
            .motion => if (dvui.captured(data.id)) {
                event.handle(@src(), data);
                editor.pointAt(row, column, columns, true);
                editor.reveal(field.cells);
            },
            .release => if (dvui.captured(data.id)) {
                event.handle(@src(), data);
                dvui.captureMouse(null, event.num);
            },
            .wheel_y => |dy| {
                event.handle(@src(), data);
                field.wheel -= dy;
                const rows_moved: isize = @intFromFloat(@trunc(field.wheel / field_line_h));
                if (rows_moved != 0) {
                    field.wheel -= @as(f32, @floatFromInt(rows_moved)) * field_line_h;
                    editor.scroll(rows_moved, field.cells);
                }
            },
            .position => dvui.cursorSet(.ibeam),
            else => {},
        }
    }

    const parent = dvui.parentGet();
    const text = editor.text();
    const sel_start = editor.selectionStart();
    const sel_end = editor.selectionEnd();
    const selection_fill = ui.mix(theme.bg, theme.accent, 0.38);
    var caret: ?dvui.Rect = null;
    if (text.len == 0) {
        const placeholder = "Type anything here to test your layout…";
        dvui.labelNoFmt(@src(), placeholder, .{ .align_x = 0, .align_y = 0.5, .ellipsize = true }, .{
            .rect = .{ .x = text_x, .y = field_text_pad, .w = @max(0, box_rect.w - text_x * 2), .h = field_line_h },
            .font = font,
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
        caret = .{ .x = text_x, .y = field_text_pad, .w = 0, .h = field_line_h };
    } else {
        var rows = scratchpad.Rows.init(text, columns);
        var index: usize = 0;
        const cursor_place = editor.place(editor.cursor, columns);
        while (rows.next()) |row| : (index += 1) {
            if (index < editor.top_row) continue;
            const slot = index - editor.top_row;
            if (slot >= rows_shown) break;
            const y = field_text_pad + @as(f32, @floatFromInt(slot)) * field_line_h;
            // The selection, with the line break shown as a narrow cell.
            const lo = @max(sel_start, row.start);
            const hi = @min(sel_end, row.end);
            const takes_break = !row.wrapped and row.end < text.len and sel_start <= row.end and sel_end > row.end;
            if (lo < hi or takes_break) {
                const from = scratchpad.codepoints(text[row.start..@max(row.start, @min(lo, row.end))]);
                const to = if (lo < hi) scratchpad.codepoints(text[row.start..hi]) else from;
                const x = text_x + @as(f32, @floatFromInt(from)) * cell_w;
                const w = @as(f32, @floatFromInt(to - from)) * cell_w + if (takes_break) cell_w * 0.5 else 0;
                const highlight = dvui.box(@src(), .{}, .{
                    .id_extra = index,
                    .rect = .{ .x = x, .y = y + 2, .w = w, .h = field_line_h - 4 },
                    .background = true,
                    .color_fill = .{ .color = selection_fill },
                    .corners = .all(2),
                    .padding = .{},
                    .margin = .{},
                });
                highlight.deinit();
            }
            var at = row.start;
            var column: usize = 0;
            while (at < row.end) : (column += 1) {
                const n = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
                const glyph = text[at..@min(row.end, at + n)];
                at += glyph.len;
                if (glyph[0] == ' ') continue;
                const cx = text_x + @as(f32, @floatFromInt(column)) * cell_w;
                renderUncroppedGlyph(parent, .{ .x = cx, .y = y, .w = cell_w, .h = field_line_h }, font, glyph, theme.text);
            }
            if (cursor_place.row == index) {
                caret = .{ .x = text_x + @as(f32, @floatFromInt(cursor_place.column)) * cell_w, .y = y, .w = 0, .h = field_line_h };
            }
        }
        // A slim indicator shows where the view is in a longer text.
        if (row_count > rows_shown) {
            const track_h = box_h - field_text_pad * 2;
            const thumb_h = @max(18, track_h * @as(f32, @floatFromInt(rows_shown)) / @as(f32, @floatFromInt(row_count)));
            const travel = track_h - thumb_h;
            const ratio = @as(f32, @floatFromInt(editor.top_row)) / @as(f32, @floatFromInt(row_count - rows_shown));
            const thumb = dvui.box(@src(), .{}, .{
                .rect = .{ .x = box_rect.w - 8, .y = field_text_pad + travel * ratio, .w = 4, .h = thumb_h },
                .background = true,
                .color_fill = .{ .color = theme.border },
                .corners = .all(2),
                .padding = .{},
                .margin = .{},
                .tag = "practice.test_keys.scrollbar",
            });
            thumb.deinit();
        }
    }
    // A thin amber caret while keys stay in the field.
    if (captured) if (caret) |spot| {
        const caret_h = field_font_size * 1.15;
        const bar = dvui.box(@src(), .{}, .{
            .rect = .{ .x = spot.x - 1, .y = spot.y + (spot.h - caret_h) * 0.5, .w = 2, .h = caret_h },
            .background = true,
            .color_fill = .{ .color = theme.warning },
            .corners = .all(1),
            .padding = .{},
            .margin = .{},
            .tag = "practice.test_keys.caret",
        });
        bar.deinit();
    };
    box.deinit();

    // Footer: what the keys do, and that nothing is scored.
    const foot_y = bounds.h - field_foot_h;
    const unscored_w: f32 = 80;
    caption("Unscored", .{ .x = bounds.w - pad_x - unscored_w, .y = foot_y + 3, .w = unscored_w, .h = field_foot_h - 6 }, 12.5, theme.muted, null);
    const hint: []const u8 = if (!captured)
        "Tab and arrows move between the controls"
    else if (mac)
        "Arrows, Home/End, Page Up/Down, ⌥ word, ⌘ line and text start/end, ⇧ selects, ⌘A ⌘C ⌘X ⌘V ⌘Z"
    else
        "Arrows, Home/End, Page Up/Down, Ctrl word, Ctrl+Home/End text start/end, Shift selects, Ctrl+A C X V Z";
    label(hint, .{ .x = pad_x + 2, .y = foot_y + 3, .w = @max(0, bounds.w - pad_x * 2 - unscored_w - 10), .h = field_foot_h - 6 }, 12.5, theme.muted, "practice.test_keys.hint");
    return wants_capture;
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
        return .{ .text = "Lesson complete", .dot_color = theme.success, .text_color = theme.success };
    }
    // Forgiving input keeps the hint calm; typing on catches up by itself.
    if (s.current_error and s.error_mode != .forgive) {
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

/// Characters other than spaces and line breaks.
fn countLetters(cps: []const u21) usize {
    var n: usize = 0;
    for (cps) |cp| n += @intFromBool(cp != ' ' and cp != '\n' and cp != '\t');
    return n;
}
