//! Small keyboards for the Tutor's before/now comparison of moved keys and
//! for the per-character reset. They draw only board geometry, one
//! single-character label per key and marks, so a keyboard that is no longer
//! connected can be shown from its saved snapshot.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const layout = @import("layout-model");

const lp = desktop.practice_layout_profile;
const model = desktop.practice_model;
const control = desktop.practice_controller;

pub const Kind = enum { before, now, hold, selected };

pub const Mark = struct { key: u16, kind: Kind };

pub const MiniBoard = struct {
    geometry: []const layout.physical_layout.Key,
    /// Single-character label per key index; 0 draws an empty key.
    labels: []const u21,
    marks: []const Mark = &.{},
    /// Two keys pressed together, joined by an arc like the keyboard canvas.
    combo: ?[2]u16 = null,
    /// Layer written on the held key instead of its label.
    hold_layer: ?u8 = null,
};

/// The colour of a mark: where a key was (warning, dashed), where it is now
/// (accent), the key held for its layer (the keyboard canvas's hold colour)
/// and a key chosen for a reset (danger).
pub fn markColor(theme: ui.Theme, kind: Kind) dvui.Color {
    return switch (kind) {
        .before => theme.warning,
        .now => theme.accent,
        .hold => ui.mix(ui.layerColor(theme, 5), theme.accent, 0.35),
        .selected => theme.danger,
    };
}

fn markFor(board: MiniBoard, key: usize) ?Kind {
    var found: ?Kind = null;
    for (board.marks) |mark| {
        if (mark.key != key) continue;
        // A key that is both held and chosen shows the stronger meaning.
        if (found == null or @backingInt(mark.kind) > @backingInt(found.?)) found = mark.kind;
    }
    return found;
}

/// Draws `board` fitted into `rect`; `id` keeps two boards in one parent apart.
pub fn draw(theme: ui.Theme, rect: dvui.Rect, board: MiniBoard, id: usize, tag: ?[]const u8) void {
    const frame = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
        .tag = tag,
    });
    defer frame.deinit();
    if (board.geometry.len == 0 or rect.w < 60 or rect.h < 40) return;

    const arc_room: f32 = if (board.combo != null) 14 else 0;
    const fit = desktop.physical_view.fit(board.geometry, .{
        .x = 10,
        .y = 10,
        .w = @max(0, rect.w - 20),
        .h = @max(0, rect.h - 20 - arc_room),
    });
    var rects: [lp.max_keys]?dvui.Rect = @splat(null);
    for (board.geometry, 0..) |key, i| {
        const placed = fit.place(key);
        const full = ui.rect(placed.rect);
        const gap = @min(2.0, full.w * 0.08);
        const r: dvui.Rect = .{ .x = full.x + gap, .y = full.y + gap, .w = @max(0, full.w - gap * 2), .h = @max(0, full.h - gap * 2) };
        if (r.w < 4 or r.h < 4) continue;
        const index: usize = key.key_index;
        if (index < rects.len) rects[index] = r;
        const turn: ui.Turn = .{ .radians = placed.rotation, .pivot = r.center() };
        const kind = markFor(board, index);
        const corner = @max(3.0, r.w * 0.14);
        if (kind) |k| {
            const tint = markColor(theme, k);
            const fill = ui.mix(theme.keycap, tint, if (k == .before) 0.12 else 0.26);
            ui.keycapPart(r, turn, placed.id, 0, .round(corner), fill, if (k == .before) null else tint, 2);
            if (k == .before) dashedOutline(r, turn, tint);
        } else {
            ui.keycapPart(r, turn, placed.id, 0, .round(corner), ui.mix(theme.keycap, theme.bg, 0.35), ui.mix(theme.bg, theme.border, 0.9), 1);
        }

        var text_buf: [8]u8 = undefined;
        const text: []const u8 = if (kind == .hold and board.hold_layer != null)
            std.fmt.bufPrint(&text_buf, "L{d}", .{board.hold_layer.?}) catch ""
        else if (index < board.labels.len and board.labels[index] > ' ')
            text_buf[0 .. std.unicode.utf8Encode(upperOf(board.labels[index]), &text_buf) catch 0]
        else
            "";
        if (text.len == 0) continue;
        const size = std.math.clamp(r.h * 0.42, 8.0, 15.0);
        dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, .{
            .id_extra = i,
            .rect = turn.rect(r),
            .font = dvui.Font.theme(.mono).withSize(size).withWeight(if (kind != null) .bold else .normal),
            .color_text = .{ .color = if (kind != null) theme.text else ui.mix(theme.bg, theme.muted, 0.8) },
            .padding = .{},
            .margin = .{},
        });
    }

    if (board.combo) |pair| {
        if (pair[0] < rects.len and pair[1] < rects.len) {
            if (rects[pair[0]]) |a| if (rects[pair[1]]) |b| {
                const kind = markFor(board, pair[0]) orelse .now;
                comboArc(a, b, markColor(theme, kind));
            };
        }
    }
}

fn screenScale() f32 {
    return dvui.parentGet().screenRectScale(.{ .w = 1, .h = 1 }).s;
}

fn physical(p: dvui.Point) dvui.Point.Physical {
    return dvui.parentGet().screenRectScale(.{ .x = p.x, .y = p.y }).r.topLeft();
}

/// A dashed border around a turned key, for where a key used to be.
fn dashedOutline(r: dvui.Rect, turn: ui.Turn, tint: dvui.Color) void {
    const corners = [_]dvui.Point{
        .{ .x = r.x + 1, .y = r.y + 1 },
        .{ .x = r.x + r.w - 1, .y = r.y + 1 },
        .{ .x = r.x + r.w - 1, .y = r.y + r.h - 1 },
        .{ .x = r.x + 1, .y = r.y + r.h - 1 },
    };
    for (0..4) |side| {
        const a = physical(turn.point(corners[side]));
        const b = physical(turn.point(corners[(side + 1) % 4]));
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const length = @sqrt(dx * dx + dy * dy);
        if (length < 1) continue;
        const scale = screenScale();
        const dash = 4.0 * scale;
        const step = 7.0 * scale;
        var at: f32 = 0;
        while (at < length) : (at += step) {
            const end = @min(length, at + dash);
            var seg: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
            defer seg.deinit();
            seg.addPoint(.{ .x = a.x + dx * at / length, .y = a.y + dy * at / length });
            seg.addPoint(.{ .x = a.x + dx * end / length, .y = a.y + dy * end / length });
            seg.build().stroke(.{ .thickness = 1.8 * scale, .color = .{ .color = tint } });
        }
    }
}

fn comboArc(a: dvui.Rect, b: dvui.Rect, tint: dvui.Color) void {
    const p0 = physical(.{ .x = a.x + a.w / 2, .y = a.y + a.h - 1 });
    const p2 = physical(.{ .x = b.x + b.w / 2, .y = b.y + b.h - 1 });
    const ctrl: dvui.Point.Physical = .{ .x = (p0.x + p2.x) * 0.5, .y = @max(p0.y, p2.y) + 12.0 * screenScale() };
    var arc: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer arc.deinit();
    const steps: usize = 12;
    for (0..steps + 1) |s| {
        const t: f32 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
        const u = 1.0 - t;
        arc.addPoint(.{
            .x = u * u * p0.x + 2 * u * t * ctrl.x + t * t * p2.x,
            .y = u * u * p0.y + 2 * u * t * ctrl.y + t * t * p2.y,
        });
    }
    arc.build().stroke(.{ .thickness = 2.0 * screenScale(), .color = .{ .color = tint } });
}

/// The marks of a character at `seen` on its keyboard: the key itself, the
/// combo partner and the key held for the layer.
pub fn marksFor(seen: model.SeenKey, kind: Kind, out: *[3]Mark) []const Mark {
    var len: usize = 0;
    out[len] = .{ .key = seen.key_index, .kind = kind };
    len += 1;
    if (seen.combo_key_index) |k| {
        out[len] = .{ .key = k, .kind = kind };
        len += 1;
    }
    if (seen.layer_key_index) |k| {
        out[len] = .{ .key = k, .kind = .hold };
        len += 1;
    }
    return out[0..len];
}

/// One entry of the question and the sheets: a letter stands for both cases.
pub fn groupOf(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + ('a' - 'A');
    return cp;
}

/// How an entry is written: letters in capitals like the confidence strip.
pub fn displayOf(cp: u21, buf: *[4]u8) []const u8 {
    if (cp == ' ') return "Spc";
    const shown: u21 = if (cp >= 'a' and cp <= 'z') cp - ('a' - 'A') else cp;
    const n = std.unicode.utf8Encode(shown, buf) catch return "?";
    return buf[0..n];
}

/// The entries of `cps` in first-seen order, letters merged by case.
pub fn groups(cps: []const u21, out: []u21) []u21 {
    var len: usize = 0;
    for (cps) |cp| {
        const g = groupOf(cp);
        if (std.mem.indexOfScalar(u21, out[0..len], g) != null) continue;
        if (len >= out.len) break;
        out[len] = g;
        len += 1;
    }
    return out[0..len];
}

/// The character whose position describes an entry: the lowercase letter
/// when it moved, otherwise the moved character itself.
pub fn representative(group: u21, review: []const u21) u21 {
    if (std.mem.indexOfScalar(u21, review, group) != null) return group;
    for (review) |cp| if (groupOf(cp) == group) return cp;
    return group;
}

pub fn reasonText(reason: lp.MoveReason, new: lp.KeyPosition, buf: []u8) []const u8 {
    return switch (reason) {
        .key_to_combo => "key → combo",
        .combo_to_key => "combo → key",
        .other_combo => "another combo",
        .other_layer => std.fmt.bufPrint(buf, "now on layer {d}", .{new.layer}) catch "another layer",
        .back_on_base_layer => "back on layer 0",
        .needs_shift => "now needs Shift",
        .drops_shift => "no Shift now",
        .other_hand => "other hand",
        .other_finger => "another finger",
        .other_row => "another row",
        .other_column => "another column",
    };
}

/// All reasons of a move joined with " · ".
pub fn describe(arena: std.mem.Allocator, old: lp.KeyPosition, new: lp.KeyPosition) ![]const u8 {
    var reasons_buf: [lp.max_move_reasons]lp.MoveReason = undefined;
    const reasons = lp.describeMove(old, new, &reasons_buf);
    var out: std.ArrayList(u8) = .empty;
    for (reasons, 0..) |reason, i| {
        if (i > 0) try out.appendSlice(arena, " · ");
        var buf: [24]u8 = undefined;
        try out.appendSlice(arena, reasonText(reason, new, &buf));
    }
    if (out.items.len == 0) try out.appendSlice(arena, "another key");
    return out.items;
}

test "entries merge letter cases and keep symbols apart" {
    const t = std.testing;
    var buf: [8]u21 = undefined;
    try t.expectEqualSlices(u21, &.{ 'z', '/' }, groups(&.{ 'Z', '/', 'z' }, &buf));
    try t.expectEqual(@as(u21, 'Z'), representative('z', &.{ 'Z', '/' }));
    try t.expectEqual(@as(u21, 'z'), representative('z', &.{ 'Z', 'z' }));
    var text: [4]u8 = undefined;
    try t.expectEqualStrings("Z", displayOf('z', &text));
    try t.expectEqualStrings("/", displayOf('/', &text));
}

test "marks cover the combo partner and the held layer key" {
    const t = std.testing;
    var buf: [3]Mark = undefined;
    const marks = marksFor(.{ .key_index = 4, .combo_key_index = 5, .layer_key_index = 30 }, .now, &buf);
    try t.expectEqual(@as(usize, 3), marks.len);
    try t.expectEqual(Kind.hold, marks[2].kind);
    const board: MiniBoard = .{ .geometry = &.{}, .labels = &.{}, .marks = &.{ .{ .key = 1, .kind = .hold }, .{ .key = 1, .kind = .selected } } };
    try t.expectEqual(@as(?Kind, .selected), markFor(board, 1));
}

/// The capital of a lowercase letter entry; other entries stay.
pub fn upperOf(group: u21) u21 {
    if (group >= 'a' and group <= 'z') return group - ('a' - 'A');
    return group;
}
