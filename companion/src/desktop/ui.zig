//! Shared retained-editor theme, layout options and controls.
const std = @import("std");
const dvui = @import("dvui");
const geometry = @import("desktop-geometry");
const fonts = @import("editor-fonts");
const icon_resources = @import("icon-resources");
const symbols = @import("desktop-core").labels.keycap_symbols;

pub fn color(hex: u24) dvui.Color {
    return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex), .a = 255 };
}

/// One color per layer position, shared by the layer list, keycap borders,
/// hold indicators and the companion. The base layer is red. Light surfaces
/// use darker shades so that borders keep their contrast.
pub const layer_palette = struct {
    pub const dark = [_]u24{
        0xEF4444, // 0 red
        0x3B82F6, // 1 blue
        0xF59E0B, // 2 amber
        0x22C55E, // 3 green
        0xA855F7, // 4 purple
        0x14B8A6, // 5 teal
        0xEC4899, // 6 pink
        0xA16207, // 7 brown
        0x94A3B8, // 8 slate
    };
    pub const light = [_]u24{ 0xDC2626, 0x2563EB, 0xD97706, 0x16A34A, 0x9333EA, 0x0D9488, 0xDB2777, 0x854D0E, 0x475569 };
};

pub fn layerColor(t: Theme, index: usize) dvui.Color {
    return color(t.layers[index % t.layers.len]);
}

/// `base` blended toward `over` by `amount` (0 keeps `base`).
pub fn mix(base: dvui.Color, over: dvui.Color, amount: f32) dvui.Color {
    const t = std.math.clamp(amount, 0, 1);
    const blend = struct {
        fn channel(a: u8, b: u8, f: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(a)) * (1 - f) + @as(f32, @floatFromInt(b)) * f));
        }
    }.channel;
    return .{ .r = blend(base.r, over.r, t), .g = blend(base.g, over.g, t), .b = blend(base.b, over.b, t), .a = base.a };
}

/// How a keycap caption is drawn. The first line is the main legend; further
/// lines (the hold) are smaller and use `secondary`.
pub const CaptionStyle = struct {
    color: dvui.Color,
    secondary: dvui.Color,
    /// Main line size in editor points, before fitting.
    size: f32,
    secondary_scale: f32 = 0.7,
    align_x: f32 = 0.5,
    align_y: f32 = 0.5,
    id_extra: usize = 0,
    /// Colors a layer symbol and its number in that layer's color.
    layer_colors: bool = true,
    layers: []const u24 = &layer_palette.dark,
    /// Turns the caption with its turned keycap.
    turn: Turn = .{},
};

const CaptionLine = struct { text: []const u8, font: dvui.Font, w: f32, h: f32 };

fn iconSize(font: dvui.Font) f32 {
    return font.size * 1.3;
}

/// The horizontal space between a symbol and its neighbours.
fn symbolGap(font: dvui.Font) f32 {
    return font.size * 0.12;
}

fn runWidth(run: symbols.Run, font: dvui.Font) f32 {
    return switch (run) {
        .text => |text| font.textSize(text).w,
        .symbol => |symbol| if (icon_resources.symbolIcon(symbol) != null)
            iconSize(font)
        else switch (icon_resources.glyph(symbol)) {
            .text => |text| font.textSize(text).w,
            else => font.textSize(symbol.glyph()).w,
        },
    };
}

fn measureLine(text: []const u8, font: dvui.Font) dvui.Size {
    var width: f32 = 0;
    var previous_symbol = false;
    var iterator = symbols.runs(text);
    var first = true;
    while (iterator.next()) |run| {
        const is_symbol = run == .symbol;
        if (!first and (is_symbol or previous_symbol)) width += symbolGap(font);
        width += runWidth(run, font);
        previous_symbol = is_symbol;
        first = false;
    }
    return .{ .w = width, .h = font.textSize("Ag").h };
}

/// Lays out up to four caption lines at `scale` of the nominal size.
fn layout(text: []const u8, style: CaptionStyle, scale: f32, lines: *[4]CaptionLine) struct { count: usize, w: f32, h: f32 } {
    var count: usize = 0;
    var width: f32 = 0;
    var height: f32 = 0;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| {
        if (count == lines.len) break;
        const size = style.size * scale * (if (count == 0) @as(f32, 1) else style.secondary_scale);
        const font = fonts.font(line, size);
        const measured = measureLine(line, font);
        lines[count] = .{ .text = line, .font = font, .w = measured.w, .h = measured.h };
        width = @max(width, measured.w);
        height += measured.h;
        count += 1;
    }
    return .{ .count = count, .w = width, .h = height };
}

/// The size of a caption drawn at its nominal size.
pub fn captionSize(text: []const u8, style: CaptionStyle) dvui.Size {
    var lines: [4]CaptionLine = undefined;
    const measured = layout(text, style, 1, &lines);
    return .{ .w = measured.w, .h = measured.h };
}

/// Draws a caption with its keyboard symbols as icons, scaled down to fit
/// `bounds` (relative to the current parent) and aligned inside it.
pub fn caption(text: []const u8, bounds: dvui.Rect, style: CaptionStyle) void {
    var lines: [4]CaptionLine = undefined;
    var measured = layout(text, style, 1, &lines);
    if (measured.count == 0 or measured.w <= 0) return;
    const fit = @min(1, @min(bounds.w / @max(1, measured.w), bounds.h / @max(1, measured.h)));
    // Pixel-snapped font metrics are not proportional to point size, so lay
    // out again at the fitted size and shrink until the caption fits.
    var scale = fit;
    for (0..6) |_| {
        measured = layout(text, style, scale, &lines);
        if (measured.w <= bounds.w and measured.h <= bounds.h) break;
        scale *= 0.94;
    }
    var y = bounds.y + (bounds.h - measured.h) * style.align_y;
    for (lines[0..measured.count], 0..) |line, line_index| {
        const x = bounds.x + (bounds.w - line.w) * style.align_x;
        drawLine(line, x, y, if (line_index == 0) style.color else style.secondary, style, line_index);
        y += line.h;
    }
}

fn drawLine(line: CaptionLine, start: f32, y: f32, tint: dvui.Color, style: CaptionStyle, line_index: usize) void {
    var x = start;
    var previous_symbol = false;
    var first = true;
    var layer_tint: ?dvui.Color = null;
    var iterator = symbols.runs(line.text);
    var run_index: usize = 0;
    while (iterator.next()) |run| : (run_index += 1) {
        const id = style.id_extra *% 131 +% line_index *% 37 +% run_index;
        const is_symbol = run == .symbol;
        if (!first and (is_symbol or previous_symbol)) x += symbolGap(line.font);
        first = false;
        previous_symbol = is_symbol;
        const width = runWidth(run, line.font);
        switch (run) {
            .symbol => |symbol| {
                var symbol_tint = tint;
                if (symbol == .layer and style.layer_colors) {
                    if (layerNumber(iterator.bytes[iterator.index..])) |number| {
                        layer_tint = color(style.layers[number % style.layers.len]);
                        symbol_tint = layer_tint.?;
                    }
                }
                if (icon_resources.symbolIcon(symbol)) |bytes| {
                    const size = iconSize(line.font);
                    dvui.icon(@src(), @tagName(symbol), bytes, .{}, .{
                        .id_extra = id,
                        .color_text = .{ .color = symbol_tint },
                        .rect = style.turn.rect(.{ .x = x, .y = y + (line.h - size) / 2, .w = size, .h = size }),
                        .rotation = style.turn.radians,
                        .padding = .{},
                        .margin = .{},
                    });
                } else {
                    const text = switch (icon_resources.glyph(symbol)) {
                        .text => |value| value,
                        else => symbol.glyph(),
                    };
                    drawText(text, line.font, symbol_tint, .{ .x = x, .y = y, .w = width + 1, .h = line.h }, id, style.turn);
                }
            },
            .text => |text| {
                const text_tint = layer_tint orelse tint;
                layer_tint = null;
                drawText(text, line.font, text_tint, .{ .x = x, .y = y, .w = width + 1, .h = line.h }, id, style.turn);
            },
        }
        x += width;
    }
}

fn drawText(text: []const u8, font: dvui.Font, tint: dvui.Color, bounds: dvui.Rect, id: usize, turn: Turn) void {
    // Snapped glyph metrics can exceed the measured width by a pixel or two;
    // widen the rect symmetrically so centered text is never clipped.
    const slack = font.size * 0.5;
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = id,
        .rect = turn.rect(.{ .x = bounds.x - slack, .y = bounds.y, .w = bounds.w + slack * 2, .h = bounds.h }),
        .rotation = turn.radians,
        .font = font,
        .color_text = .{ .color = tint },
        .padding = .{},
        .margin = .{},
    });
}

/// The layer position written right after a layer symbol.
fn layerNumber(rest: []const u8) ?usize {
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

/// A caption inside an absolutely placed box, such as a chip or list row.
/// Unlike `caption`, it reserves `min_size` in flowing layouts.
pub fn richLabel(text: []const u8, style: CaptionStyle, opts: dvui.Options) void {
    var box_options = opts;
    const size = captionSize(text, style);
    box_options.min_size_content = .{ .w = size.w, .h = size.h };
    box_options.id_extra = style.id_extra;
    const box = dvui.box(@src(), .{}, box_options);
    defer box.deinit();
    const content = box.data().contentRect();
    caption(text, .{ .w = content.w, .h = content.h }, style);
}

pub const Theme = struct {
    bg: dvui.Color,
    panel: dvui.Color,
    control: dvui.Color,
    border: dvui.Color,
    text: dvui.Color,
    muted: dvui.Color,
    /// Primary actions and selection.
    accent: dvui.Color,
    /// Keycap faces on the keyboard canvases.
    keycap: dvui.Color,
    /// Failures and destructive actions.
    danger: dvui.Color,
    /// Passed checks and saved state.
    success: dvui.Color,
    /// Advisories that do not block the work.
    warning: dvui.Color,
    layers: []const u24,

    const light_theme: Theme = .{
        .bg = color(0xEEF0F3),
        .panel = color(0xFFFFFF),
        .control = color(0xF2F4F7),
        .border = color(0xD8DDE4),
        .text = color(0x1F2329),
        .muted = color(0x667180),
        .accent = color(0x2563EB),
        .keycap = color(0xF8F9FB),
        .danger = color(0xDC2626),
        .success = color(0x15803D),
        .warning = color(0xB45309),
        .layers = &layer_palette.light,
    };
    const dark_theme: Theme = .{
        .bg = color(0x15171B),
        .panel = color(0x1E2126),
        .control = color(0x2A2E35),
        .border = color(0x383D46),
        .text = color(0xEDEFF2),
        .muted = color(0x9AA3B0),
        .accent = color(0x3B82F6),
        .keycap = color(0x272B32),
        .danger = color(0xF06B73),
        .success = color(0x6EC59A),
        .warning = color(0xF59E0B),
        .layers = &layer_palette.dark,
    };

    pub fn get(light: bool) Theme {
        return if (light) light_theme else dark_theme;
    }

    /// Caption colors for keycaps on this theme.
    pub fn captionStyle(t: Theme, size: f32, id_extra: usize) CaptionStyle {
        return .{ .color = t.text, .secondary = t.muted, .size = size, .id_extra = id_extra, .layers = t.layers };
    }
};

/// The editor font for `text` at `size` points.
pub fn editorFont(text: []const u8, size: f32) dvui.Font {
    return fonts.font(text, size);
}

pub fn rect(r: anytype) dvui.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// A clockwise turn by `radians` around `pivot`, in canvas units of the
/// parent. DVUI boxes ignore rotation, so turned keys draw their parts as
/// paths and turn each label and icon on its own.
pub const Turn = struct {
    radians: f32 = 0,
    pivot: dvui.Point = .{},

    pub fn point(self: Turn, p: dvui.Point) dvui.Point {
        const d = p.diff(self.pivot);
        const cos = @cos(self.radians);
        const sin = @sin(self.radians);
        return .{ .x = self.pivot.x + d.x * cos - d.y * sin, .y = self.pivot.y + d.x * sin + d.y * cos };
    }

    /// `r` moved so that its centre follows the turn; the caller turns its
    /// contents by `radians` around that centre.
    pub fn rect(self: Turn, r: dvui.Rect) dvui.Rect {
        if (self.radians == 0) return r;
        const centre = self.point(r.center());
        return .{ .x = centre.x - r.w / 2, .y = centre.y - r.h / 2, .w = r.w, .h = r.h };
    }
};

/// A box with `corners` turned by `turn`, filled, with an optional border
/// drawn inside its edge like a DVUI box border.
pub fn turnedBox(r: dvui.Rect, turn: Turn, corners: dvui.CornerRect, fill: dvui.Color, border: ?dvui.Color, thickness: f32) void {
    const parent = dvui.parentGet();
    const screen = parent.screenRectScale(r);
    const pivot = parent.screenRectScale(.{ .x = turn.pivot.x, .y = turn.pivot.y }).r.topLeft();
    var face: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer face.deinit();
    turnedPath(&face, screen.r, corners.scale(screen.s, dvui.CornerRect.Physical), pivot, turn.radians)
        .fillConvex(.{ .color = .{ .color = fill } });
    const stroke = border orelse return;
    if (thickness <= 0) return;
    // Stroke along the middle of the border so it stays inside the face.
    const half = thickness * screen.s / 2;
    var inner = corners.scale(screen.s, dvui.CornerRect.Physical);
    inline for (.{ "tl", "tr", "bl", "br" }) |name| {
        const corner = &@field(inner, name);
        if (corner.kind == .round) corner.* = .round(@max(0, corner.rx - half));
    }
    var edge: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer edge.deinit();
    turnedPath(&edge, screen.r.insetAll(half), inner, pivot, turn.radians)
        .stroke(.{ .thickness = thickness * screen.s, .color = .{ .color = stroke }, .closed = true });
}

fn turnedPath(path: *dvui.Path.Builder, r: dvui.Rect.Physical, radii: dvui.CornerRect.Physical, pivot: dvui.Point.Physical, radians: f32) dvui.Path {
    path.addRect(r, radii);
    const cos = @cos(radians);
    const sin = @sin(radians);
    for (path.points.items) |*p| {
        const d = p.diff(pivot);
        p.* = .{ .x = pivot.x + d.x * cos - d.y * sin, .y = pivot.y + d.x * sin + d.y * cos };
    }
    return path.build();
}

/// A keycap face turned clockwise by `radians` around its centre.
pub fn turnedFace(r: dvui.Rect, radians: f32, corner: f32, fill: dvui.Color, border: dvui.Color, thickness: f32) void {
    turnedBox(r, .{ .radians = radians, .pivot = r.center() }, .round(corner), fill, border, thickness);
}

/// Base options for an absolutely placed control in theme colors.
pub fn options(t: Theme, r: dvui.Rect, size: f32) dvui.Options {
    return .{
        .rect = r,
        .font = fonts.font("", size),
        .color_text = .{ .color = t.text },
        .color_fill = .{ .color = t.control },
        .color_border = .{ .color = t.border },
        .margin = .{},
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .corners = .all(6),
    };
}

/// A label identified by its position, bold from 18 points up.
pub fn label(t: Theme, text: []const u8, r: dvui.Rect, size: f32) void {
    var opts = options(t, r, size);
    opts.font = fonts.font(text, size);
    if (size >= 18) opts.font = opts.font.?.withWeight(.bold);
    opts.id_extra = (@as(usize, @intFromFloat(r.x)) << 16) + @as(usize, @intFromFloat(r.y));
    opts.padding = .{};
    dvui.labelNoFmt(@src(), text, .{}, opts);
}

pub fn button(t: Theme, text: []const u8, tag: []const u8, r: dvui.Rect) bool {
    var data: dvui.WidgetData = undefined;
    return buttonData(t, text, tag, r, &data);
}

/// A button, or a muted label in its place while disabled.
pub fn buttonEnabled(t: Theme, text: []const u8, tag: []const u8, r: dvui.Rect, enabled: bool) bool {
    if (enabled) return button(t, text, tag, r);
    var opts = options(t, r, 15);
    opts.tag = tag;
    opts.id_extra = std.hash.Wyhash.hash(0, tag);
    opts.background = true;
    opts.color_text = .{ .color = t.muted };
    opts.font = fonts.font(text, 15);
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, opts);
    return false;
}

/// Buttons drawn with the accent fill.
const primary_tags = [_][]const u8{ "try.test", "practice.start", "firmware.build", "firmware.inspect" };

/// A button identified by its tag.
pub fn buttonData(t: Theme, text: []const u8, tag: []const u8, r: dvui.Rect, data: *dvui.WidgetData) bool {
    var opts = options(t, r, 13);
    opts.font = fonts.font(text, 15);
    opts.tag = tag;
    opts.data_out = data;
    opts.id_extra = std.hash.Wyhash.hash(0, tag);
    opts.background = true;
    if (r.w < 40) opts.padding = .all(2);
    if (std.mem.startsWith(u8, tag, "layer.duplicate") or std.mem.startsWith(u8, tag, "layer.delete")) opts.background = false;
    for (primary_tags) |primary| {
        if (!std.mem.eql(u8, tag, primary)) continue;
        opts.color_fill = .{ .color = color(0x126AFF) };
        opts.color_text = .{ .color = color(0xFFFFFF) };
    }
    return dvui.button(@src(), text, .{}, opts);
}

/// A panel's bounds on the canvas. The top bar and the keyboard panels grow
/// with windows wider than the design canvas.
pub fn panelRect(which: geometry.Panel) dvui.Rect {
    var bounds = rect(geometry.panel(which));
    const width = @max(@as(f32, 1536), dvui.parentGet().data().contentRect().w);
    if (which == .toolbar) bounds.w = width;
    if (which == .physical or which == .os) bounds.w = width - bounds.x - 16;
    return bounds;
}

pub fn panel(t: Theme, which: geometry.Panel) *dvui.BoxWidget {
    const bounds = panelRect(which);
    var opts = options(t, bounds, 14);
    opts.tag = @tagName(which);
    opts.id_extra = @backingInt(which);
    opts.color_fill = .{ .color = t.panel };
    opts.background = true;
    opts.border = .all(1);
    opts.padding = .{};
    opts.corners = .all(12);
    // The top bar is a full-width strip with a bottom edge.
    if (which == .toolbar) {
        opts.border = .{ .h = 1 };
        opts.corners = .all(0);
    }
    return dvui.box(@src(), .{}, opts);
}

pub fn drawer(src: std.builtin.SourceLocation, t: Theme, bounds: dvui.Rect, modal: bool) *dvui.FloatingWindowWidget {
    return dvui.floatingWindow(src, .{ .modal = modal }, .{
        .rect = bounds,
        .padding = .all(18),
        .background = true,
        .color_fill = .{ .color = t.panel },
    });
}

/// A modal drawer centered in the window, at most `width` wide and 960 high.
pub fn editDrawer(src: std.builtin.SourceLocation, t: Theme, width: f32) *dvui.FloatingWindowWidget {
    const screen = dvui.windowRect();
    const w = @min(width, screen.w - 48);
    const h = @min(@as(f32, 960), screen.h - 48);
    return drawer(src, t, .{ .x = (screen.w - w) / 2, .y = (screen.h - h) / 2, .w = w, .h = h }, true);
}

/// A modal sheet of `w` × `h` canvas units, centered in the window. Its
/// children are placed in canvas units from its top left corner.
pub fn sheet(src: std.builtin.SourceLocation, t: Theme, w: f32, h: f32, tag: []const u8) *dvui.FloatingWindowWidget {
    const scale = dvui.parentGet().screenRectScale(.{}).s / dvui.windowNaturalScale();
    const screen = dvui.windowRect();
    const width = @min(w * scale, screen.w - 32);
    const height = @min(h * scale, screen.h - 32);
    return dvui.floatingWindow(src, .{ .modal = true }, .{
        .rect = .{ .x = (screen.w - width) / 2, .y = (screen.h - height) / 2, .w = width, .h = height },
        .padding = .{},
        .background = true,
        .color_fill = .{ .color = t.panel },
        .color_border = .{ .color = t.border },
        .border = .all(1),
        .corners = .all(14),
        .tag = tag,
    });
}

/// A filled line, such as a divider between sheet sections.
pub fn divider(t: Theme, r: dvui.Rect, id: usize) void {
    const line = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = r,
        .background = true,
        .color_fill = .{ .color = t.border },
        .padding = .{},
        .margin = .{},
    });
    line.deinit();
}

/// The top of a sheet `w` wide: title, one sentence of explanation, a close
/// button and the divider below them at y = 100. Returns true when the close
/// button was clicked.
pub fn sheetHeader(t: Theme, w: f32, title: []const u8, subtitle: []const u8, close_tag: []const u8) bool {
    label(t, title, .{ .x = 28, .y = 26, .w = w - 120, .h = 30 }, 22);
    var muted = t;
    muted.text = t.muted;
    label(muted, subtitle, .{ .x = 28, .y = 62, .w = w - 100, .h = 20 }, 14);
    divider(t, .{ .x = 0, .y = 100, .w = w, .h = 1 }, 0x5eed);
    return iconButton(t, control_icons.remove, "", close_tag, .{ .x = w - 58, .y = 22, .w = 30, .h = 30 }, false);
}

/// A secondary button in the danger color, for destructive actions.
pub fn dangerButton(t: Theme, icon: ?[]const u8, text: []const u8, tag: []const u8, r: dvui.Rect) bool {
    const id = std.hash.Wyhash.hash(0, tag);
    var opts = options(t, r, 15);
    opts.tag = tag;
    opts.id_extra = id;
    opts.background = true;
    opts.border = .all(1);
    opts.corners = .all(8);
    opts.padding = .{};
    opts.color_fill = .{ .color = mix(t.panel, t.danger, 0.08) };
    opts.color_border = .{ .color = mix(t.panel, t.danger, 0.55) };
    const clicked = dvui.button(@src(), "", .{}, opts);
    const font_value = fonts.font(text, 15);
    const icon_size: f32 = 17;
    const gap: f32 = if (icon != null) 8 else 0;
    const text_w = font_value.textSize(text).w;
    var x = r.x + (r.w - (if (icon != null) icon_size else 0) - gap - text_w) / 2;
    if (icon) |bytes| {
        dvui.icon(@src(), tag, bytes, .{}, .{
            .id_extra = id,
            .color_text = .{ .color = t.danger },
            .rect = .{ .x = x, .y = r.y + (r.h - icon_size) / 2, .w = icon_size, .h = icon_size },
            .padding = .{},
            .margin = .{},
        });
        x += icon_size + gap;
    }
    drawText(text, font_value, t.danger, .{ .x = x, .y = r.y, .w = text_w, .h = r.h }, id, .{});
    return clicked;
}

/// A button whose label is a caption with keyboard symbols drawn as icons.
pub fn richButton(src: std.builtin.SourceLocation, text: []const u8, style: CaptionStyle, opts: dvui.Options) bool {
    var button_options = opts;
    const size = captionSize(text, style);
    button_options.min_size_content = .{ .w = size.w, .h = size.h };
    var button_widget: dvui.ButtonWidget = undefined;
    button_widget.init(src, .{}, button_options);
    button_widget.processEvents();
    button_widget.drawBackground();
    const clicked = button_widget.clicked();
    const content = button_widget.data().contentRect();
    caption(text, .{ .w = content.w, .h = content.h }, style);
    button_widget.drawFocus();
    button_widget.deinit();
    return clicked;
}

/// The dvui theme for the editor appearance, in the editor font.
pub fn dvuiTheme(window: *const dvui.Window, light: bool) dvui.Theme {
    return fonts.theme(window, if (light) dvui.Theme.builtin.adwaita_light else dvui.Theme.builtin.adwaita_dark);
}

pub const control_icons = icon_resources.controls;

/// A button with an optional leading icon and optional text, centered.
/// `primary` fills it with the accent color.
pub fn iconButton(t: Theme, icon: ?[]const u8, text: []const u8, tag: []const u8, r: dvui.Rect, primary: bool) bool {
    return iconButtonEnabled(t, icon, text, tag, r, primary, true);
}

/// `iconButton`, drawn muted and inert while disabled.
pub fn iconButtonEnabled(t: Theme, icon: ?[]const u8, text: []const u8, tag: []const u8, r: dvui.Rect, primary: bool, enabled: bool) bool {
    const id = std.hash.Wyhash.hash(0, tag);
    var opts = options(t, r, 15);
    opts.tag = tag;
    opts.id_extra = id;
    opts.background = true;
    opts.border = .all(if (primary) 0 else 1);
    opts.corners = .all(8);
    opts.padding = .{};
    // A disabled primary button keeps a trace of the accent so the work flow
    // stays legible, but no longer reads as clickable.
    if (primary) opts.color_fill = .{ .color = if (enabled) t.accent else mix(t.control, t.accent, 0.3) };
    if (!enabled and !primary) opts.color_text = .{ .color = t.muted };
    const tint = if (!enabled) t.muted else if (primary) color(0xFFFFFF) else t.text;
    var clicked = false;
    if (enabled) {
        clicked = dvui.button(@src(), "", .{}, opts);
    } else {
        const box = dvui.box(@src(), .{}, opts);
        box.deinit();
    }
    const font = fonts.font(text, 15);
    const icon_size: f32 = 18;
    const gap: f32 = if (icon != null and text.len != 0) 8 else 0;
    const text_w = if (text.len == 0) 0 else font.textSize(text).w;
    const total = (if (icon != null) icon_size else 0) + gap + text_w;
    var x = r.x + (r.w - total) / 2;
    if (icon) |bytes| {
        dvui.icon(@src(), tag, bytes, .{}, .{
            .id_extra = id,
            .color_text = .{ .color = tint },
            .rect = .{ .x = x, .y = r.y + (r.h - icon_size) / 2, .w = icon_size, .h = icon_size },
            .padding = .{},
            .margin = .{},
        });
        x += icon_size + gap;
    }
    if (text.len != 0) drawText(text, font, tint, .{ .x = x, .y = r.y, .w = text_w, .h = r.h }, id, .{});
    return clicked;
}

/// The green "On keyboard" pill.
pub fn runningBadge(t: Theme, bounds: dvui.Rect, id: usize) void {
    const pill = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = bounds,
        .background = true,
        .color_fill = .{ .color = mix(t.panel, t.success, 0.16) },
        .corners = .all(bounds.h / 2),
        .padding = .{},
        .margin = .{},
    });
    pill.deinit();
    const dot = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = .{ .x = bounds.x + 10, .y = bounds.y + bounds.h / 2 - 3.5, .w = 7, .h = 7 },
        .background = true,
        .color_fill = .{ .color = t.success },
        .corners = .all(3.5),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();
    var green = t;
    green.text = t.success;
    var opts = options(green, .{ .x = bounds.x + 22, .y = bounds.y, .w = bounds.w - 26, .h = bounds.h }, 11);
    opts.padding = .{};
    opts.id_extra = id;
    dvui.labelNoFmt(@src(), "On keyboard", .{ .align_y = 0.5 }, opts);
}
