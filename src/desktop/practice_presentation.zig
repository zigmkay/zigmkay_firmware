//! Practice text and exercise rendering; no input or runner I/O.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const practice = desktop.practice;
const view = desktop.practice_view;

pub const accent = ui.color(0x287AF2);
const error_text = ui.color(0xE85A68);

pub const Scroll = struct { position: f32 = 0, at: ?u64 = null };

fn rectId(bounds: dvui.Rect) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&bounds));
}

pub fn label(text: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color, tag: ?[]const u8) void {
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0, .align_y = 0.5 }, .{
        .rect = bounds,
        .font = dvui.Font.theme(.body).withSize(size),
        .color_text = .{ .color = color },
        .margin = .{},
        .padding = .{},
        .tag = tag,
        .id_extra = rectId(bounds),
    });
}

pub fn caption(text: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color, tag: ?[]const u8) void {
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .rect = bounds,
        .font = dvui.Font.theme(.body).withSize(size),
        .color_text = .{ .color = color },
        .padding = .{},
        .tag = tag,
        .id_extra = rectId(bounds),
    });
}

fn letter(s: *const practice.Session, index: usize, focus: usize, bounds: dvui.Rect, size: f32, t: ui.Theme, hero: bool) void {
    const current = index == focus and s.state != .complete;
    const wrong = index < s.len and s.typed[index] != s.reference[index];
    const text_color = if (current)
        dvui.Color.white
    else if (wrong)
        error_text
    else if (index < s.len)
        ui.color(if (t.bg.r > 100) 0x2C876E else 0x69BFA3)
    else if (hero)
        t.text
    else
        t.muted;
    var bytes: [4]u8 = undefined;
    const text = view.glyph(s.reference[index], current or hero, &bytes);
    // The monospace font has no whitespace symbols; the body font does.
    const symbol = view.whitespace(s.reference[index]);
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5, .ellipsize = false }, .{
        .rect = bounds,
        .font = dvui.Font.theme(if (symbol) .body else .mono).withSize(size),
        .padding = .{},
        .margin = .{},
        .id_extra = index,
        .color_text = .{ .color = text_color },
        .background = current,
        .color_fill = .{ .color = if (wrong) ui.color(0xCF4055) else accent },
        .corners = .all(6),
        .tag = if (current and !hero) "practice.current" else null,
    });
}

pub fn focusWord(s: *const practice.Session, active: bool, t: ui.Theme, bounds: dvui.Rect, focus: usize) void {
    const panel = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = t.control },
        .corners = .all(14),
        .padding = .{},
        .tag = "practice.word",
    });
    defer panel.deinit();
    if (!active) {
        const text = "Try your keyboard, then start a typing test";
        caption(text, .{ .x = 0, .y = 16, .w = bounds.w, .h = bounds.h - 32 }, @min(34, bounds.h * 0.4), t.text, null);
        return;
    }
    if (s.state == .complete) {
        const done_bounds: dvui.Rect = .{ .x = 0, .y = 8, .w = bounds.w, .h = bounds.h - 36 };
        caption("Exercise complete", done_bounds, @min(44, bounds.h * 0.5), ui.color(0x36A77C), null);
        const result = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d:.0} WPM · {d:.1}% accuracy", .{
            s.wpm(0),
            s.accuracy(),
        }) catch "";
        caption(result, .{ .x = 0, .y = bounds.h - 34, .w = bounds.w, .h = 28 }, 16, t.muted, "practice.result");
        return;
    }
    const range = view.word(s.reference[0..s.reference_len], focus);
    const count: f32 = @floatFromInt(range.end - range.start);
    if (count == 0) return;
    const size = @min(@min(@as(f32, 52), bounds.h * 0.5), (bounds.w - 60) / (count * 0.65));
    const cell = dvui.Font.theme(.mono).withSize(size).textSize("M").w + 4;
    const x = (bounds.w - cell * count) / 2;
    const glyph_height = @min(bounds.h - 43, size * 1.4);
    for (range.start..range.end) |i| {
        const offset: f32 = @floatFromInt(i - range.start);
        const cell_bounds: dvui.Rect = .{
            .x = x + offset * cell,
            .y = (bounds.h - 43 - glyph_height) / 2 + 4,
            .w = cell,
            .h = glyph_height,
        };
        letter(s, i, focus, cell_bounds, size, t, true);
    }
    const wrong = focus < s.len;
    const hint_bounds: dvui.Rect = .{ .x = 0, .y = bounds.h - 36, .w = bounds.w, .h = 30 };
    caption(focusHint(s, focus), hint_bounds, @min(17, bounds.h * 0.18), if (wrong) error_text else t.muted, "practice.next");
}

fn focusHint(s: *const practice.Session, focus: usize) []const u8 {
    if (focus < s.len) {
        var bytes: [4]u8 = undefined;
        const remaining = s.len - focus;
        return std.fmt.allocPrint(
            dvui.currentWindow().arena(),
            "Typed «{s}» · Backspace {d} character{s} to correct",
            .{ view.glyph(s.typed[focus], true, &bytes), remaining, if (remaining == 1) "" else "s" },
        ) catch "Correct the red letter";
    }
    if (s.state == .paused) return "Paused · press Resume to continue";
    return switch (s.reference[focus]) {
        ' ' => "Space",
        '\n' => "Enter",
        '\t' => "Tab",
        else => "Next highlighted letter",
    };
}

pub fn context(
    s: *const practice.Session,
    active: bool,
    mode: desktop.practice_controller.Mode,
    scroll: *Scroll,
    fixture: bool,
    t: ui.Theme,
    bounds: dvui.Rect,
    focus: usize,
    now: u64,
) void {
    const panel = dvui.box(@src(), .{}, .{
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = t.bg },
        .corners = .all(12),
        .padding = .{},
        .tag = "practice.text",
    });
    defer panel.deinit();
    if (!active) {
        const text = "Press keys to see them on the keyboard below. Start measures WPM and accuracy.";
        caption(text, .{ .x = 0, .y = 0, .w = bounds.w, .h = bounds.h }, 22, t.muted, null);
        return;
    }
    const font_size = @min(@as(f32, 30), @max(@as(f32, 22), bounds.h / 5));
    const cell = dvui.Font.theme(.mono).withSize(font_size).textSize("M").w + 2;
    const columns: usize = @intFromFloat(@max(1, @floor((bounds.w - 80) / cell)));
    var storage: [8192]view.Range = undefined;
    const ranges = view.lines(s.reference[0..s.reference_len], columns, &storage);
    const active_line = view.currentLine(ranges, focus);
    animateScroll(scroll, @floatFromInt(active_line), now, fixture);
    const line_height = font_size * 1.65;
    const clip = dvui.clip(panel.data().contentRectScale().r);
    defer dvui.clipSet(clip);
    for (ranges, 0..) |range, row_index| {
        const y = bounds.h / 2 - line_height / 2 + (@as(f32, @floatFromInt(row_index)) - scroll.position) * line_height;
        if (y + line_height < 0 or y > bounds.h) continue;
        // Avoid showing half of a neighboring line at the context panel edge.
        if (row_index != active_line and (y < 0 or y + line_height > bounds.h)) continue;
        const row = dvui.box(@src(), .{}, .{
            .id_extra = row_index,
            .rect = .{ .x = 8, .y = y, .w = bounds.w - 16, .h = line_height },
            .padding = .{},
            .background = row_index == active_line,
            .color_fill = .{ .color = t.control },
            .corners = .all(8),
        });
        defer row.deinit();
        if (mode == .zig) {
            const line_number = std.mem.count(u21, s.reference[0..range.start], &.{'\n'}) + 1;
            dvui.label(@src(), "{d}", .{line_number}, .{
                .rect = .{ .x = 0, .y = 0, .w = 40, .h = line_height },
                .font = dvui.Font.theme(.mono).withSize(14),
                .color_text = .{ .color = t.muted },
            });
        }
        const count: f32 = @floatFromInt(range.end - range.start);
        const x = if (mode == .zig) @as(f32, 50) else @max(40, (bounds.w - 16 - count * cell) / 2);
        for (range.start..range.end) |i| {
            const offset: f32 = @floatFromInt(i - range.start);
            const cell_bounds: dvui.Rect = .{ .x = x + offset * cell, .y = 0, .w = cell, .h = line_height };
            letter(s, i, focus, cell_bounds, font_size, t, false);
        }
    }
}

/// Eases the scroll position toward `target`, jumping on large moves and in fixtures.
fn animateScroll(scroll: *Scroll, target: f32, now: u64, fixture: bool) void {
    const previous = scroll.at;
    const elapsed: f32 = if (previous) |at| @as(f32, @floatFromInt(@min(now -| at, 100_000))) / 1_000_000 else 1;
    scroll.at = now;
    if (fixture or previous == null or @abs(target - scroll.position) > 3) {
        scroll.position = target;
    } else {
        scroll.position += (target - scroll.position) * (1 - @exp(-elapsed * 18));
    }
    if (@abs(scroll.position - target) > 0.01) dvui.refresh(null, @src(), null);
}
