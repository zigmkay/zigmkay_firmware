//! Unified tutor and Test keys physical keyboard renderer matching the Companion
//! Editor Tap/Hold keycap anatomy, exact PCB geometry, rotated thumb keys,
//! finger-zone accents, home-anchor motion cues, and Shift/Layer/Combo overlays.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const layout = @import("layout-model");

const practice = desktop.practice;
const lp = desktop.practice_layout_profile;
const control = desktop.practice_controller;

pub const Params = struct {
    mode: control.Mode = .tutor,
    profile: ?*const lp.LayoutProfile = null,
    geometry: []const layout.physical_layout.Key,
    labels: *const desktop.label_cache.LabelCache,
    layer: usize = 0,
    active_layers: u16 = 1,
    modifiers: layout.Modifiers = .{},
    pressed: []const bool,
    stale: bool = false,

    /// Tutor guidance state (ignored in `.test_keys` mode).
    show_guidance: bool = false,
    show_finger_zones: bool = true,
    unlocked_mask: u32 = 0x03ff_ffff,
    dim_locked: bool = false,
    hint: ?practice.Hint = null,
    tap_targets: ?[]const bool = null,
    hold_targets: ?[]const bool = null,
    one_shot_targets: ?[]const bool = null,
    hold_source_layer: usize = 0,
    combo_output_cp: ?u21 = null,
    error_flash_key: ?usize = null,
    /// How each key went in the last lesson, until the next one starts.
    heat: []const HeatKey = &.{},
    /// Outlined keys with a small badge: tap/hold decisions (all modes).
    marks: []const KeyMark = &.{},
    source_caption: []const u8 = "",
    layer_name: []const u8 = "",
    /// The caption carries a longer legend; the right-hand legend gives way.
    wide_caption: bool = false,
};

pub const Heat = enum { clean, slow, missed };

pub const HeatKey = struct {
    key_index: usize,
    heat: Heat,
};

/// A key outlined in `color` with a badge such as "HOLD ⇧" at its corner.
pub const KeyMark = struct {
    key_index: usize,
    color: dvui.Color,
    badge: []const u8 = "",
    /// A dashed outline: something the last lesson recorded. Solid ones
    /// show what just happened.
    dashed: bool = false,
    /// Fades the mark out; 1 is fully visible.
    alpha: f32 = 1,
};

/// The keyboard's hold color: Shift and layer holds on the keycaps and the
/// tap/hold feedback.
pub fn holdColor(t: ui.Theme) dvui.Color {
    return ui.mix(ui.layerColor(t, 5), t.accent, 0.35);
}

/// Theme-derived semantic colors (100% ui.Theme & ui.layer_palette; no hardcoded hex).
const Palette = struct {
    tap: dvui.Color,
    hold: dvui.Color,
    combo: dvui.Color,
    err: dvui.Color,
    ok: dvui.Color,

    fn fromTheme(t: ui.Theme) Palette {
        return .{
            .tap = t.warning,
            .hold = holdColor(t),
            .combo = ui.layerColor(t, 4),
            .err = t.danger,
            .ok = t.success,
        };
    }
};

pub fn fingerColor(t: ui.Theme, finger: lp.Finger) dvui.Color {
    return switch (finger) {
        .left_pinky, .right_pinky => ui.layerColor(t, 6),
        .left_ring, .right_ring => ui.layerColor(t, 4),
        .left_middle, .right_middle => ui.layerColor(t, 1),
        .left_index, .right_index => ui.layerColor(t, 3),
        .left_thumb, .right_thumb => ui.layerColor(t, 5),
        .unknown => t.muted,
    };
}

pub fn draw(theme: ui.Theme, bounds: dvui.Rect, params: Params) !void {
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

    if (params.geometry.len == 0 or bounds.w < 120 or bounds.h < 90) {
        var muted = theme;
        muted.text = theme.muted;
        ui.label(muted, "Keyboard view unavailable", .{ .x = 16, .y = 14, .w = @max(0, bounds.w - 32), .h = 22 }, 13);
        return;
    }

    const arena = dvui.currentWindow().arena();
    const is_tutor = params.mode == .tutor;
    const pal = Palette.fromTheme(theme);

    // Reserve compact footer legend strip at bottom of keyboard card.
    const legend_h: f32 = 30;
    const pad_x: f32 = 20;
    const pad_top: f32 = 14;
    const area: desktop.physical_view.Rect = .{
        .x = pad_x,
        .y = pad_top,
        .w = @max(0, bounds.w - pad_x * 2),
        .h = @max(0, bounds.h - pad_top - legend_h - 6),
    };

    const output = try arena.alloc(desktop.physical_view.DrawKey, params.geometry.len);
    const plan = try desktop.physical_view.plan(
        output,
        params.geometry,
        params.labels,
        @min(params.layer, params.labels.layer_count - 1),
        params.modifiers,
        area,
        .{
            .pressed = params.pressed,
            .targets = if (is_tutor and params.show_guidance) params.tap_targets else null,
            .holds = if (is_tutor and params.show_guidance) params.hold_targets else null,
            .hold_source_layer = @min(params.hold_source_layer, params.labels.layer_count - 1),
            .active_layers = params.active_layers,
            .stale = params.stale,
        },
    );

    // Index placed rects by key_index for anchor/bridge/combo vector overlays.
    var rect_by_key: [lp.max_keys]?dvui.Rect = @splat(null);
    for (plan) |item| {
        if (item.placed.key_index < lp.max_keys) {
            rect_by_key[item.placed.key_index] = ui.rect(item.placed.rect);
        }
    }

    // Determine active combo pair, tap key, hold key, and home anchor for overlays.
    const combo_pair: ?[2]usize = if (is_tutor and params.show_guidance) blk: {
        if (params.hint) |h| {
            if (h.combo_key) |k1| break :blk .{ h.key, k1 };
        }
        break :blk null;
    } else null;

    var anchor_key: ?usize = null;
    var tap_key_idx: ?usize = null;
    var hold_key_idx: ?usize = null;
    if (is_tutor and params.show_guidance) {
        if (params.hint) |h| {
            tap_key_idx = h.key;
            if (params.profile) |p| {
                const f = p.fingerFor(h.key);
                if (f != .unknown) {
                    if (p.homeAnchorFor(f)) |ak| {
                        if (ak != h.key) anchor_key = ak;
                    }
                }
            }
        }
        if (params.hold_targets) |holds| {
            for (holds, 0..) |is_h, idx| {
                if (is_h) {
                    hold_key_idx = idx;
                    break;
                }
            }
        }
    }

    const display_layer = @min(params.layer, params.labels.layer_count - 1);
    const layer_color = ui.layerColor(theme, display_layer);

    const space_key: ?usize = if (params.profile) |p| p.space_key else null;
    for (plan) |item| {
        const idx: usize = item.placed.key_index;
        const is_combo = if (combo_pair) |cp| (idx == cp[0] or idx == cp[1]) else false;
        const is_one_shot = if (is_tutor and params.show_guidance) blk: {
            if (params.one_shot_targets) |os| {
                if (idx < os.len) break :blk os[idx];
            }
            break :blk false;
        } else false;
        const is_anchor_ring = (anchor_key != null and anchor_key.? == idx);
        const is_error_flash = (is_tutor and params.error_flash_key != null and params.error_flash_key.? == idx);
        const heat: ?Heat = if (is_tutor) for (params.heat) |h| {
            if (h.key_index == idx) break h.heat;
        } else null else null;
        const mark: ?KeyMark = for (params.marks) |m| {
            if (m.key_index == idx) break m;
        } else null;
        const is_active_key = item.target or item.hold or is_combo or item.pressed or is_anchor_ring;
        const locked = is_tutor and params.dim_locked and !is_active_key and isKeyLocked(params.labels, idx, params.unlocked_mask, space_key);
        const finger: lp.Finger = if (params.profile) |p| p.fingerFor(idx) else .unknown;
        const is_index_home = if (params.profile) |p|
            idx < p.key_count and p.keys[idx].primary_home_anchor and (finger == .left_index or finger == .right_index)
        else
            false;

        try drawKeycap(arena, theme, pal, layer_color, item, .{
            .is_tutor = is_tutor,
            .show_finger_zones = is_tutor and params.show_finger_zones and params.profile != null and params.profile.?.fidelity == .schematic,
            .finger = finger,
            .locked = locked,
            .is_combo = is_combo,
            .is_one_shot = is_one_shot,
            .is_anchor_ring = is_anchor_ring,
            .is_index_home = is_index_home,
            .is_error_flash = is_error_flash,
            .heat = heat,
            .mark = mark,
        });
    }

    // Badges go on top of every keycap, so a neighbour never covers them.
    for (plan) |item| {
        const idx: usize = item.placed.key_index;
        const mark = for (params.marks) |m| {
            if (m.key_index == idx) break m;
        } else continue;
        if (mark.badge.len == 0) continue;
        const rect = ui.rect(item.placed.rect);
        const turn: ui.Turn = .{ .radians = item.placed.rotation, .pivot = rect.center() };
        drawBadge(theme, turn.point(.{ .x = rect.x + rect.w, .y = rect.y }), mark, item.placed.id);
    }

    // Draw vector guidance overlays on top of keycaps.
    if (is_tutor and params.show_guidance) {
        // 1. Directional motion chevron from finger home-row anchor to off-home target key.
        if (anchor_key) |ak| {
            if (tap_key_idx) |tk| {
                if (ak < lp.max_keys and tk < lp.max_keys) {
                    if (rect_by_key[ak]) |ar| if (rect_by_key[tk]) |tr| {
                        const f = if (params.profile) |p| p.fingerFor(tk) else .unknown;
                        drawMotionChevron(ar, tr, if (f != .unknown) fingerColor(theme, f) else pal.tap);
                    };
                }
            }
        }
        // 2. Dashed bridge arc connecting Hold key (Shift / Layer) and Tap key.
        if (hold_key_idx) |hk| {
            if (tap_key_idx) |tk| {
                if (hk != tk and hk < lp.max_keys and tk < lp.max_keys) {
                    if (rect_by_key[hk]) |hr| if (rect_by_key[tk]) |tr| {
                        drawDashedBridge(hr, tr, pal.hold);
                    };
                }
            }
        }
        // 3. Purple 2-key combo connector arc + output badge.
        if (combo_pair) |cp| {
            if (cp[0] < lp.max_keys and cp[1] < lp.max_keys) {
                if (rect_by_key[cp[0]]) |r0| if (rect_by_key[cp[1]]) |r1| {
                    drawComboArc(theme, pal, r0, r1, params.combo_output_cp);
                };
            }
        }
    }

    // Footer legend bar (source/layer info on left, finger zones or Tap/Hold/Combo legend on right).
    try drawFooterLegend(theme, pal, bounds, display_layer, params);
}

const KeyState = struct {
    is_tutor: bool,
    show_finger_zones: bool,
    finger: lp.Finger,
    locked: bool,
    is_combo: bool,
    is_one_shot: bool,
    is_anchor_ring: bool,
    is_index_home: bool,
    is_error_flash: bool,
    heat: ?Heat = null,
    mark: ?KeyMark = null,
};

/// During Stage 1 (Home row) and Stage 2 (All letters), only unlocked `a..z`
/// letters and the thumb Space key are active; punctuation and other non-letter
/// keys stay dimmed so the board clearly reflects the active unlocked set.
fn isKeyLocked(labels: *const desktop.label_cache.LabelCache, key_index: usize, unlocked_mask: u32, space_key: ?usize) bool {
    if (unlocked_mask == 0 or unlocked_mask == 0x03ff_ffff) return false;
    if (space_key != null and space_key.? == key_index) return false;
    const entry = labels.lookup(0, key_index, .{});
    if (entry.hid_code) |code| {
        if (code == 44) return false; // Space
    }
    const text = entry.label orelse return true;
    if (text.len == 1) {
        const ch = std.ascii.toLower(text[0]);
        if (ch == ' ') return false;
        if (ch >= 'a' and ch <= 'z') {
            return (unlocked_mask & (@as(u32, 1) << @intCast(ch - 'a'))) == 0;
        }
    }
    return true;
}

fn splitCaption(caption: []const u8) struct { tap: []const u8, hold: []const u8 } {
    if (std.mem.indexOfScalar(u8, caption, '\n')) |nl| {
        return .{ .tap = caption[0..nl], .hold = caption[nl + 1 ..] };
    }
    return .{ .tap = caption, .hold = "" };
}

fn drawKeycap(
    arena: std.mem.Allocator,
    theme: ui.Theme,
    pal: Palette,
    layer_color: dvui.Color,
    item: desktop.physical_view.DrawKey,
    ks: KeyState,
) !void {
    const rect = ui.rect(item.placed.rect);
    if (rect.w < 6 or rect.h < 6) return;

    const id = item.placed.id;
    const turn: ui.Turn = .{ .radians = item.placed.rotation, .pivot = rect.center() };

    const is_transparent = if (item.content.label) |lbl| std.mem.eql(u8, lbl, "---") else false;
    const is_tap = item.target and !ks.is_combo;
    const is_hold = item.hold;

    // Match the shared Companion Editor keycap styling (`keyboard_ui.zig`) 1:1.
    var fill: dvui.Color = if (ks.locked or is_transparent)
        theme.panel
    else
        theme.keycap;
    var border: dvui.Color = if (ks.locked)
        ui.mix(theme.panel, theme.border, 0.55)
    else
        ui.mix(theme.keycap, layer_color, if (is_transparent) 0.3 else 0.65);
    var thickness: f32 = 1.5;
    var tap_text_color: dvui.Color = if (ks.locked)
        ui.mix(theme.panel, theme.muted, 0.55)
    else if (is_transparent)
        theme.muted
    else
        theme.text;
    var hold_text_color: dvui.Color = if (ks.locked)
        ui.mix(theme.panel, theme.muted, 0.45)
    else
        theme.muted;

    if (ks.heat) |heat| {
        const hc = switch (heat) {
            .clean => pal.ok,
            .slow => pal.tap,
            .missed => pal.err,
        };
        fill = ui.mix(theme.keycap, hc, 0.24);
        border = ui.mix(theme.keycap, hc, 0.8);
        thickness = 2.0;
    }

    // A dashed mark replaces the border with dashes drawn after the face.
    var dashes: ?dvui.Color = null;
    if (ks.mark) |mark| {
        const color = ui.mix(border, mark.color, mark.alpha);
        fill = ui.mix(fill, mark.color, 0.2 * mark.alpha);
        thickness = 2.5;
        if (mark.dashed) {
            dashes = color;
            border = fill;
        } else {
            border = color;
        }
    }

    if (ks.is_anchor_ring and !is_tap and !is_hold and !ks.is_combo) {
        const fc = if (ks.finger != .unknown) fingerColor(theme, ks.finger) else theme.accent;
        fill = ui.mix(theme.keycap, fc, 0.14);
        border = fc;
        thickness = 2.0;
    }

    if (ks.is_combo) {
        fill = ui.mix(theme.keycap, pal.combo, 0.26);
        border = pal.combo;
        thickness = 2.5;
        tap_text_color = theme.text;
        hold_text_color = pal.combo;
    } else if (is_tap) {
        fill = ui.mix(theme.keycap, pal.tap, 0.26);
        border = pal.tap;
        thickness = 2.5;
        tap_text_color = theme.text;
        hold_text_color = pal.tap;
    } else if (is_hold) {
        fill = ui.mix(theme.keycap, pal.hold, 0.26);
        border = pal.hold;
        thickness = 2.5;
        tap_text_color = theme.text;
        hold_text_color = pal.hold;
    }

    if (item.pressed) {
        fill = ui.mix(theme.keycap, layer_color, 0.42);
        border = layer_color;
        thickness = 2.5;
        tap_text_color = theme.text;
    }

    if (ks.is_error_flash) {
        fill = ui.mix(theme.keycap, pal.err, 0.35);
        border = pal.err;
        thickness = 2.6;
        tap_text_color = theme.text;
    }

    // 1. Shared Editor Tap/Hold keycap shell (`ui.drawKeycapFace`)
    const band_fill = ui.mix(fill, theme.bg, if (ks.locked or is_transparent) 0.25 else 0.45);
    const divider = ui.mix(fill, border, if (is_tap or is_hold or ks.is_combo or item.pressed) 0.6 else 0.25);
    const split = ui.drawKeycapFace(rect, turn, id, .{
        .fill = fill,
        .border = border,
        .band_fill = band_fill,
        .divider = divider,
        .thickness = thickness,
    });
    if (dashes) |color| drawDashedOutline(rect, turn, color, 2.2);

    // 2. Finger-zone accent strip at very bottom of unlocked keycaps in Tutor mode
    const has_finger_strip = ks.show_finger_zones and !ks.locked and ks.finger != .unknown;
    if (has_finger_strip) {
        const fc = fingerColor(theme, ks.finger);
        const strip_w = @max(6.0, rect.w * 0.48);
        const strip_h: f32 = 2.5;
        ui.keycapPart(
            .{
                .x = rect.x + (rect.w - strip_w) / 2,
                .y = rect.y + rect.h - thickness - strip_h - 1.5,
                .w = strip_w,
                .h = strip_h,
            },
            turn,
            id,
            4,
            .round(1.25),
            ui.mix(band_fill, fc, if (is_tap or is_hold or ks.is_anchor_ring) 0.95 else 0.65),
            null,
            0,
        );
    }

    // 3. Tactile home-row bump on left/right index anchors (Tutor mode only)
    if (ks.is_tutor and ks.is_index_home and !ks.locked) {
        const bump_w = @max(6.0, rect.w * 0.28);
        ui.keycapPart(
            .{
                .x = rect.x + (rect.w - bump_w) / 2,
                .y = rect.y + split - 4.5,
                .w = bump_w,
                .h = 2.0,
            },
            turn,
            id,
            5,
            .round(1.0),
            ui.mix(fill, theme.muted, 0.7),
            null,
            0,
        );
    }

    // 4. Shared Editor legends (`ui.drawKeycapLegends` at exact 24*scale / 16*scale)
    const raw_caption = if (is_transparent) "" else item.content.caption orelse item.content.label orelse "";
    const parts = splitCaption(raw_caption);

    const hold_label: []const u8 = if (ks.is_combo)
        "COMBO"
    else if (is_tap)
        "TAP"
    else if (is_hold)
        try formatHoldCue(arena, item.content, parts.hold, ks.is_one_shot)
    else
        parts.hold;

    const show_layer_colors = !is_transparent and !ks.locked and !item.pressed and !is_hold;
    ui.drawKeycapLegends(
        theme,
        rect,
        turn,
        id,
        item.scale,
        split,
        parts.tap,
        hold_label,
        tap_text_color,
        hold_text_color,
        show_layer_colors,
        if (has_finger_strip) 4.0 else 0.0,
    );
}

fn formatHoldCue(
    arena: std.mem.Allocator,
    content: desktop.label_cache.CachedKeyContent,
    existing_hold: []const u8,
    is_one_shot: bool,
) ![]const u8 {
    const prefix = if (is_one_shot) "1S" else "HOLD";
    if (existing_hold.len > 0 and existing_hold.len <= 12) {
        return try std.fmt.allocPrint(arena, "{s} {s}", .{ prefix, existing_hold });
    }
    if (content.one_shot_layer orelse content.hold_layer) |layer_idx| {
        return try std.fmt.allocPrint(arena, "{s} L{d}", .{ prefix, layer_idx });
    }
    const mods = content.one_shot_mods orelse content.hold_mods;
    if (mods) |m| {
        if (m.left_shift or m.right_shift) {
            return try std.fmt.allocPrint(arena, "{s} ⇧", .{prefix});
        }
    }
    if (content.hid_code) |code| {
        if (code == 225 or code == 229) {
            return try std.fmt.allocPrint(arena, "{s} ⇧", .{prefix});
        }
    }
    return if (is_one_shot) "1-SHOT" else "HOLD";
}

/// Dashes along the straight edges of a (possibly turned) keycap.
pub fn drawDashedOutline(rect: dvui.Rect, turn: ui.Turn, color: dvui.Color, thickness: f32) void {
    const parent = dvui.parentGet();
    const corner = @max(4.0, rect.w * 0.12);
    const inset = thickness / 2;
    const left = rect.x + inset;
    const right = rect.x + rect.w - inset;
    const top = rect.y + inset;
    const bottom = rect.y + rect.h - inset;
    const edges = [_][2]dvui.Point{
        .{ .{ .x = left + corner, .y = top }, .{ .x = right - corner, .y = top } },
        .{ .{ .x = right, .y = top + corner }, .{ .x = right, .y = bottom - corner } },
        .{ .{ .x = right - corner, .y = bottom }, .{ .x = left + corner, .y = bottom } },
        .{ .{ .x = left, .y = bottom - corner }, .{ .x = left, .y = top + corner } },
    };
    const dash = @max(3.0, rect.w / 9);
    for (edges) |edge| {
        const dx = edge[1].x - edge[0].x;
        const dy = edge[1].y - edge[0].y;
        const length = @sqrt(dx * dx + dy * dy);
        if (length < 1) continue;
        const count: usize = @intFromFloat(@max(1, @floor((length + dash) / (dash * 2))));
        const used = @as(f32, @floatFromInt(count)) * dash * 2 - dash;
        const start = (length - used) / 2;
        for (0..count) |i| {
            const a = (start + @as(f32, @floatFromInt(i)) * dash * 2) / length;
            const b = @min(1.0, a + dash / length);
            const p0 = turn.point(.{ .x = edge[0].x + dx * a, .y = edge[0].y + dy * a });
            const p1 = turn.point(.{ .x = edge[0].x + dx * b, .y = edge[0].y + dy * b });
            var seg: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
            defer seg.deinit();
            seg.addPoint(parent.screenRectScale(.{ .x = p0.x, .y = p0.y }).r.topLeft());
            seg.addPoint(parent.screenRectScale(.{ .x = p1.x, .y = p1.y }).r.topLeft());
            const scale = parent.screenRectScale(.{}).s;
            seg.build().stroke(.{ .thickness = thickness * scale, .color = .{ .color = color } });
        }
    }
}

/// A small pill centred on a keycap's top-right corner.
fn drawBadge(theme: ui.Theme, corner: dvui.Point, mark: KeyMark, id: u16) void {
    const font = ui.editorFont(mark.badge, 14).withWeight(.bold);
    const size = font.textSize(mark.badge);
    const w = size.w + 14;
    const h: f32 = 23;
    const rect: dvui.Rect = .{ .x = corner.x - w + 10, .y = corner.y - h / 2 - 2, .w = w, .h = h };
    const pill = dvui.box(@src(), .{}, .{
        .id_extra = @as(usize, id) * 16 + 9,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = mark.color.opacity(mark.alpha) },
        .color_border = .{ .color = theme.panel.opacity(mark.alpha) },
        .border = .all(1.5),
        .corners = .all(h / 2),
        .padding = .{},
        .margin = .{},
    });
    pill.deinit();
    dvui.labelNoFmt(@src(), mark.badge, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = @as(usize, id) * 16 + 10,
        .rect = rect,
        .font = font,
        .color_text = .{ .color = badgeText(theme, mark.color).opacity(mark.alpha) },
        .padding = .{},
        .margin = .{},
    });
}

/// Dark text on a light badge and light text on a dark one.
fn badgeText(theme: ui.Theme, fill: dvui.Color) dvui.Color {
    const luma = 0.299 * @as(f32, @floatFromInt(fill.r)) + 0.587 * @as(f32, @floatFromInt(fill.g)) + 0.114 * @as(f32, @floatFromInt(fill.b));
    const dark = if (theme.bg.r < 128) theme.bg else theme.text;
    const light = if (theme.bg.r < 128) theme.text else theme.panel;
    return if (luma > 150) dark else light;
}

fn drawMotionChevron(anchor: dvui.Rect, target: dvui.Rect, tint: dvui.Color) void {
    const parent = dvui.parentGet();
    const a_pt = parent.screenRectScale(.{ .x = anchor.x + anchor.w / 2, .y = anchor.y + anchor.h / 2 }).r.topLeft();
    const t_pt = parent.screenRectScale(.{ .x = target.x + target.w / 2, .y = target.y + target.h / 2 }).r.topLeft();
    const dx = t_pt.x - a_pt.x;
    const dy = t_pt.y - a_pt.y;
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist < 4.0) return;

    const ux = dx / dist;
    const uy = dy / dist;
    const mx = (a_pt.x + t_pt.x) * 0.5;
    const my = (a_pt.y + t_pt.y) * 0.5;
    const head_len: f32 = @min(7.0, dist * 0.25);
    const wing: f32 = head_len * 0.75;

    // Chevron pointing from anchor toward target.
    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();
    path.addPoint(.{ .x = mx - ux * head_len - uy * wing, .y = my - uy * head_len + ux * wing });
    path.addPoint(.{ .x = mx + ux * (head_len * 0.4), .y = my + uy * (head_len * 0.4) });
    path.addPoint(.{ .x = mx - ux * head_len + uy * wing, .y = my - uy * head_len - ux * wing });
    path.build().stroke(.{ .thickness = 2.0, .color = .{ .color = tint.opacity(0.9) } });
}

fn drawDashedBridge(from: dvui.Rect, to: dvui.Rect, tint: dvui.Color) void {
    const parent = dvui.parentGet();
    const p0 = parent.screenRectScale(.{ .x = from.x + from.w / 2, .y = from.y + 3 }).r.topLeft();
    const p2 = parent.screenRectScale(.{ .x = to.x + to.w / 2, .y = to.y + 3 }).r.topLeft();
    const ctrl: dvui.Point.Physical = .{
        .x = (p0.x + p2.x) * 0.5,
        .y = @min(p0.y, p2.y) - 24.0,
    };

    const segments: usize = 16;
    var i: usize = 0;
    while (i < segments) : (i += 2) {
        const t0: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const t1: f32 = @as(f32, @floatFromInt(@min(i + 1, segments))) / @as(f32, @floatFromInt(segments));
        const a = quadBezier(p0, ctrl, p2, t0);
        const b = quadBezier(p0, ctrl, p2, t1);
        var seg: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
        defer seg.deinit();
        seg.addPoint(a);
        seg.addPoint(b);
        seg.build().stroke(.{ .thickness = 1.8, .color = .{ .color = tint.opacity(0.85) } });
    }
}

fn drawComboArc(theme: ui.Theme, pal: Palette, r0: dvui.Rect, r1: dvui.Rect, output_cp: ?u21) void {
    const parent = dvui.parentGet();
    const p0 = parent.screenRectScale(.{ .x = r0.x + r0.w / 2, .y = r0.y + r0.h - 2 }).r.topLeft();
    const p2 = parent.screenRectScale(.{ .x = r1.x + r1.w / 2, .y = r1.y + r1.h - 2 }).r.topLeft();
    const ctrl: dvui.Point.Physical = .{
        .x = (p0.x + p2.x) * 0.5,
        .y = @max(p0.y, p2.y) + 18.0,
    };

    var arc: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer arc.deinit();
    const steps: usize = 12;
    for (0..steps + 1) |s| {
        const t: f32 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
        arc.addPoint(quadBezier(p0, ctrl, p2, t));
    }
    arc.build().stroke(.{ .thickness = 2.2, .color = .{ .color = pal.combo } });

    if (output_cp) |cp| {
        var cp_buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &cp_buf) catch 0;
        if (n > 0) {
            const mx = (r0.x + r0.w / 2 + r1.x + r1.w / 2) * 0.5;
            const my = @max(r0.y + r0.h, r1.y + r1.h) + 2;
            const badge: dvui.Rect = .{ .x = mx - 14, .y = my, .w = 28, .h = 16 };
            const pill = dvui.box(@src(), .{}, .{
                .rect = badge,
                .background = true,
                .color_fill = .{ .color = ui.mix(theme.panel, pal.combo, 0.35) },
                .color_border = .{ .color = pal.combo },
                .border = .all(1),
                .corners = .all(4),
                .padding = .{},
                .margin = .{},
            });
            pill.deinit();
            var style = theme.captionStyle(11, 0x20001);
            style.color = theme.text;
            ui.caption(cp_buf[0..n], badge, style);
        }
    }
}

fn quadBezier(p0: dvui.Point.Physical, p1: dvui.Point.Physical, p2: dvui.Point.Physical, t: f32) dvui.Point.Physical {
    const u = 1.0 - t;
    return .{
        .x = u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
        .y = u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y,
    };
}

fn drawFooterLegend(
    theme: ui.Theme,
    pal: Palette,
    bounds: dvui.Rect,
    display_layer: usize,
    params: Params,
) !void {
    const arena = dvui.currentWindow().arena();
    const y = bounds.h - 26;

    // Left: source + layer pill (avoid duplicating "Layer" when layer_name already starts with it)
    const layer_tag = if (display_layer != params.hold_source_layer)
        try std.fmt.allocPrint(arena, "Layer {d} preview", .{display_layer})
    else if (params.layer_name.len > 0)
        (if (std.mem.startsWith(u8, params.layer_name, "Layer"))
            params.layer_name
        else
            try std.fmt.allocPrint(arena, "Layer {d} · {s}", .{ display_layer, params.layer_name }))
    else
        try std.fmt.allocPrint(arena, "Layer {d}", .{display_layer});
    const left_text = if (params.source_caption.len > 0)
        try std.fmt.allocPrint(arena, "{s} · {s}", .{ params.source_caption, layer_tag })
    else
        layer_tag;
    // The heatmap legend may run longer than the left half; the right side
    // gives way to it.
    const left_share: f32 = if (params.wide_caption) 0.7 else 0.44;

    var muted = theme;
    muted.text = theme.muted;
    var left_opts = ui.options(muted, .{ .x = 16, .y = y, .w = @max(0, bounds.w * left_share), .h = 20 }, 13);
    left_opts.padding = .{};
    left_opts.tag = "practice.keyboard.source";
    dvui.labelNoFmt(@src(), left_text, .{ .align_y = 0.5, .ellipsize = true }, left_opts);

    if (params.mode == .test_keys) {
        // Clean Test layout indicator on right
        var right_opts = ui.options(muted, .{ .x = bounds.w - 260, .y = y, .w = 244, .h = 20 }, 13);
        right_opts.padding = .{};
        dvui.labelNoFmt(@src(), "Hardware & layout check · unscored", .{ .align_x = 1, .align_y = 0.5 }, right_opts);
        return;
    }

    // Right: finger zone legend (wide viewports) + Hold / Tap swatches
    var cursor_x = bounds.w - 16;

    const swatches = [_]struct { label: []const u8, col: dvui.Color, w: f32 }{
        .{ .label = "Tap", .col = pal.tap, .w = 48 },
        .{ .label = "Hold", .col = pal.hold, .w = 54 },
    };
    for (swatches, 0..) |sw, i| {
        cursor_x -= sw.w;
        drawLegendItem(theme, cursor_x, y, sw.col, sw.label, 0x3000 + i);
    }

    if (bounds.w >= 720 and params.show_finger_zones and params.profile != null and params.profile.?.fidelity == .schematic) {
        cursor_x -= 14;
        const fingers = [_]struct { label: []const u8, f: lp.Finger, w: f32 }{
            .{ .label = "Thumb", .f = .left_thumb, .w = 68 },
            .{ .label = "Index", .f = .left_index, .w = 60 },
            .{ .label = "Middle", .f = .left_middle, .w = 68 },
            .{ .label = "Ring", .f = .left_ring, .w = 52 },
            .{ .label = "Pinky", .f = .left_pinky, .w = 60 },
        };
        for (fingers, 0..) |fi, i| {
            cursor_x -= fi.w;
            if (cursor_x < bounds.w * (left_share + 0.01)) break;
            drawLegendItem(theme, cursor_x, y, fingerColor(theme, fi.f), fi.label, 0x3100 + i);
        }
    }
}

fn drawLegendItem(theme: ui.Theme, x: f32, y: f32, col: dvui.Color, text: []const u8, id: usize) void {
    const dot = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = .{ .x = x, .y = y + 6, .w = 8, .h = 8 },
        .background = true,
        .color_fill = .{ .color = col },
        .corners = .all(4),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();
    var muted = theme;
    muted.text = theme.muted;
    var opts = ui.options(muted, .{ .x = x + 13, .y = y, .w = 58, .h = 20 }, 13);
    opts.id_extra = id;
    opts.padding = .{};
    dvui.labelNoFmt(@src(), text, .{ .align_y = 0.5 }, opts);
}

test "caption splitter separates tap and hold legends cleanly" {
    const t = std.testing;
    const both = splitCaption("T\n⇧");
    try t.expectEqualStrings("T", both.tap);
    try t.expectEqualStrings("⇧", both.hold);
    const tap_only = splitCaption("A");
    try t.expectEqualStrings("A", tap_only.tap);
    try t.expectEqualStrings("", tap_only.hold);
}
