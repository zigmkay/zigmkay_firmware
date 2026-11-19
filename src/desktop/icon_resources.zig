//! Vector icons: retained cache names and the keycap symbol table.
//!
//! Keycap symbols use lucide icons from the pinned icon package. A few keyboard
//! symbols have no lucide icon; they are drawn from small first-party SVGs in the
//! lucide style, converted to TinyVG once on first use. Symbols that no icon
//! set covers (Insert, Scroll Lock) are short text, as printed on keycaps.
const std = @import("std");
const icons = @import("icons");
const svg2tvg = @import("svg2tvg");
const desktop = @import("desktop-core");
const Symbol = desktop.labels.keycap_symbols.Symbol;
const lucide = icons.tvg.lucide;

pub const gui_icon = lucide.command;

/// Icons of editor controls, outside keycaps.
pub const controls = struct {
    pub const keyboard = lucide.keyboard;
    pub const open = lucide.@"folder-open";
    pub const build = lucide.wrench;
    pub const flash = lucide.zap;
    pub const undo = lucide.@"undo-2";
    pub const redo = lucide.@"redo-2";
    pub const light = lucide.sun;
    pub const dark = lucide.moon;
    pub const add = lucide.plus;
    pub const copy = lucide.copy;
    pub const paste = lucide.clipboard;
    pub const remove = lucide.x;
    pub const duplicate = lucide.@"copy-plus";
    pub const expand = lucide.@"chevron-down";
    pub const next = lucide.@"chevron-right";
    pub const search = lucide.search;
    pub const check = lucide.check;
    pub const rename = lucide.pencil;
    pub const export_source = lucide.download;
    pub const folder = lucide.folder;
    pub const git = lucide.@"git-branch";
    pub const saved = lucide.@"circle-check";
    pub const warning = lucide.@"triangle-alert";
    pub const info = lucide.info;
    pub const template = lucide.@"layout-template";
    pub const blank = lucide.@"square-dashed";
    pub const back = lucide.@"arrow-left";
    pub const forward = lucide.@"arrow-right";
    pub const refresh = lucide.@"refresh-cw";
    pub const file = lucide.@"file-code";
    pub const transfer = lucide.@"arrow-left-right";
    pub const delete = lucide.@"trash-2";
    pub const encoder = lucide.@"rotate-cw";
    pub const external = lucide.@"square-arrow-out-up-right";
    pub const autofire = lucide.repeat;
    pub const inherit = lucide.@"arrow-down";
    pub const nothing = lucide.ban;
};
const Entry = struct { name: []const u8, bytes: []const u8 };

pub const entries = [_]Entry{
    .{ .name = "companion", .bytes = lucide.@"circuit-board" },
    .{ .name = "shutdown", .bytes = lucide.power },
    .{ .name = "vol_up", .bytes = lucide.@"volume-2" },
    .{ .name = "vol_down", .bytes = lucide.@"volume-1" },
    .{ .name = "mute", .bytes = lucide.@"volume-x" },
    .{ .name = "next", .bytes = lucide.@"skip-forward" },
    .{ .name = "prev", .bytes = lucide.@"skip-back" },
    .{ .name = "m_left", .bytes = lucide.mouse },
    .{ .name = "m_right", .bytes = lucide.mouse },
    .{ .name = "m_mid", .bytes = lucide.mouse },
    .{ .name = "w_up", .bytes = lucide.@"chevron-up" },
    .{ .name = "w_down", .bytes = lucide.@"chevron-down" },
    .{ .name = "w_left", .bytes = lucide.@"chevron-left" },
    .{ .name = "w_right", .bytes = lucide.@"chevron-right" },
    .{ .name = "backspace", .bytes = lucide.delete },
    .{ .name = "enter", .bytes = lucide.@"corner-down-left" },
    .{ .name = "left", .bytes = lucide.@"arrow-left" },
    .{ .name = "right", .bytes = lucide.@"arrow-right" },
    .{ .name = "up", .bytes = lucide.@"arrow-up" },
    .{ .name = "down", .bytes = lucide.@"arrow-down" },
    .{ .name = "tab", .bytes = lucide.@"arrow-right-to-line" },
    .{ .name = "space", .bytes = lucide.space },
    .{ .name = "page_down", .bytes = lucide.@"chevrons-down" },
    .{ .name = "page_up", .bytes = lucide.@"chevrons-up" },
    .{ .name = "home", .bytes = lucide.@"arrow-up-left" },
    .{ .name = "end", .bytes = lucide.@"arrow-down-right" },
};

pub fn lookup(name: []const u8) ?[]const u8 {
    for (entries) |entry| if (std.mem.eql(u8, name, entry.name)) return entry.bytes;
    return null;
}

const context: u8 = 0;

pub fn resolver() desktop.label_cache.IconResolver {
    return .{ .context = &context, .resolve = resolve };
}

fn resolve(_: *const anyopaque, gpa: std.mem.Allocator, name: []const u8) !?[]u8 {
    const bytes = lookup(name) orelse return null;
    return try gpa.dupe(u8, bytes);
}

/// How a keycap draws one symbol.
pub const Glyph = union(enum) {
    /// TinyVG bytes of a pinned icon.
    icon: []const u8,
    /// A first-party SVG, converted to TinyVG on first use.
    svg: Custom,
    /// Short text for symbols without any icon.
    text: []const u8,
};

pub fn glyph(symbol: Symbol) Glyph {
    return switch (symbol) {
        .backspace => .{ .icon = lucide.delete },
        .delete_forward => .{ .svg = .delete_forward },
        .escape => .{ .icon = lucide.@"circle-arrow-out-up-left" },
        .tab => .{ .icon = lucide.@"arrow-right-to-line" },
        .caps_lock => .{ .icon = lucide.@"arrow-big-up-dash" },
        .enter => .{ .icon = lucide.@"corner-down-left" },
        .space => .{ .svg = .space },
        .shift => .{ .icon = lucide.@"arrow-big-up" },
        .control => .{ .icon = lucide.@"chevron-up" },
        .option => .{ .icon = lucide.option },
        .command => .{ .icon = lucide.command },
        .windows => .{ .icon = lucide.@"grid-2x2" },
        .left => .{ .icon = lucide.@"arrow-left" },
        .right => .{ .icon = lucide.@"arrow-right" },
        .up => .{ .icon = lucide.@"arrow-up" },
        .down => .{ .icon = lucide.@"arrow-down" },
        .home => .{ .icon = lucide.@"arrow-up-left" },
        .end => .{ .icon = lucide.@"arrow-down-right" },
        .page_up => .{ .icon = lucide.@"chevrons-up" },
        .page_down => .{ .icon = lucide.@"chevrons-down" },
        .insert => .{ .text = "ins" },
        .print_screen => .{ .icon = lucide.scan },
        .scroll_lock => .{ .text = "scr" },
        .pause => .{ .icon = lucide.pause },
        .menu => .{ .icon = lucide.menu },
        .power => .{ .icon = lucide.power },
        .volume_up => .{ .icon = lucide.@"volume-2" },
        .volume_down => .{ .icon = lucide.@"volume-1" },
        .mute => .{ .icon = lucide.@"volume-x" },
        .next_track => .{ .icon = lucide.@"skip-forward" },
        .previous_track => .{ .icon = lucide.@"skip-back" },
        .mouse_left => .{ .svg = .mouse_left },
        .mouse_right => .{ .svg = .mouse_right },
        .mouse_middle => .{ .svg = .mouse_middle },
        .mouse_back => .{ .icon = lucide.@"circle-arrow-left" },
        .mouse_forward => .{ .icon = lucide.@"circle-arrow-right" },
        .wheel_up => .{ .svg = .wheel_up },
        .wheel_down => .{ .svg = .wheel_down },
        .wheel_left => .{ .svg = .wheel_left },
        .wheel_right => .{ .svg = .wheel_right },
        .companion => .{ .icon = lucide.eye },
        .shutdown => .{ .icon = lucide.x },
        .log_toggle => .{ .icon = lucide.@"scroll-text" },
        .layer => .{ .icon = lucide.layers },
        .callback => .{ .text = "ƒ" },
        .one_shot => .{ .icon = lucide.pin },
        .dead_key => .{ .icon = lucide.@"circle-dashed" },
    };
}

/// First-party icons in the lucide grid: 24 units, 2-unit round strokes.
pub const Custom = enum {
    space,
    delete_forward,
    mouse_left,
    mouse_right,
    mouse_middle,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,

    fn svg(self: Custom) []const u8 {
        const body = switch (self) {
            // A centered ␣; lucide `space` is a flat line at the bottom edge.
            .space =>
            \\<path d="M4 9v5a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9"/>
            ,
            // lucide `delete`, mirrored: the forward-delete key ⌦.
            .delete_forward =>
            \\<path d="M14 5a2 2 0 0 1 1.344.519l6.328 5.74a1 1 0 0 1 0 1.481l-6.328 5.741A2 2 0 0 1 14 19H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z"/><path d="m12 9-6 6"/><path d="m6 9 6 6"/>
            ,
            .mouse_left => mouse ++
                \\<path d="M12 2.5V10H5.5V9A6.5 6.5 0 0 1 12 2.5z" fill="currentColor" stroke="none"/>
            ,
            .mouse_right => mouse ++
                \\<path d="M12 2.5V10H18.5V9A6.5 6.5 0 0 0 12 2.5z" fill="currentColor" stroke="none"/>
            ,
            .mouse_middle => mouse ++
                \\<rect x="10.25" y="5" width="3.5" height="6" rx="1.75" fill="currentColor" stroke="none"/>
            ,
            .wheel_up => mouse ++
                \\<path d="m9 10 3-3 3 3"/>
            ,
            .wheel_down => mouse ++
                \\<path d="m9 12 3 3 3-3"/>
            ,
            .wheel_left => mouse ++
                \\<path d="m13.5 8-3 3 3 3"/>
            ,
            .wheel_right => mouse ++
                \\<path d="m10.5 8 3 3-3 3"/>
            ,
        };
        return body;
    }

    const mouse =
        \\<rect x="5" y="2" width="14" height="20" rx="7"/>
    ;
};

const svg_open =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
;
const svg_close = "</svg>";

const custom_count = @typeInfo(Custom).@"enum".field_names.len;
/// Converted icons live for the process. Only the UI thread draws icons.
var converted: [custom_count]?[]const u8 = @splat(null);

/// Converts a first-party SVG to TinyVG bytes owned by `gpa`.
pub fn convert(gpa: std.mem.Allocator, custom: Custom) ![]const u8 {
    const source = try std.mem.concat(gpa, u8, &.{ svg_open, custom.svg(), svg_close });
    defer gpa.free(source);
    return svg2tvg.tvg_from_svg(gpa, source, .{});
}

/// The TinyVG bytes of a first-party icon, converting it on first use. Returns
/// null if conversion fails, so callers can fall back to the symbol's glyph.
pub fn customIcon(custom: Custom) ?[]const u8 {
    const slot = &converted[@backingInt(custom)];
    if (slot.*) |bytes| return bytes;
    slot.* = convert(std.heap.page_allocator, custom) catch return null;
    return slot.*;
}

/// The TinyVG bytes of a symbol, or null when it is drawn as text.
pub fn symbolIcon(symbol: Symbol) ?[]const u8 {
    return switch (glyph(symbol)) {
        .icon => |bytes| bytes,
        .svg => |custom| customIcon(custom),
        .text => null,
    };
}

const Bounds = struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32, commands: usize };

/// Parses every drawing command and returns the area its points cover.
fn inspect(bytes: []const u8) !Bounds {
    var reader = std.Io.Reader.fixed(bytes);
    var parser = try svg2tvg.tvg.parse(std.testing.allocator, &reader);
    defer parser.deinit();
    try std.testing.expect(parser.header.width > 0 and parser.header.height > 0);
    var bounds: Bounds = .{ .min_x = std.math.inf(f32), .min_y = std.math.inf(f32), .max_x = -std.math.inf(f32), .max_y = -std.math.inf(f32), .commands = 0 };
    while (try parser.next()) |command| {
        bounds.commands += 1;
        include(&bounds, command);
    }
    return bounds;
}

/// Widens `bounds` by every point reachable in a parsed drawing command.
fn include(bounds: *Bounds, value: anytype) void {
    const T = @TypeOf(value);
    if (T == svg2tvg.tvg.Point) {
        bounds.min_x = @min(bounds.min_x, value.x);
        bounds.min_y = @min(bounds.min_y, value.y);
        bounds.max_x = @max(bounds.max_x, value.x);
        bounds.max_y = @max(bounds.max_y, value.y);
        return;
    }
    if (T == svg2tvg.tvg.Path.Node) {
        // Horizontal and vertical segments carry one coordinate, and arcs
        // bulge up to their radius beyond their end points.
        switch (value) {
            .horiz => |node| {
                bounds.min_x = @min(bounds.min_x, node.data);
                bounds.max_x = @max(bounds.max_x, node.data);
            },
            .vert => |node| {
                bounds.min_y = @min(bounds.min_y, node.data);
                bounds.max_y = @max(bounds.max_y, node.data);
            },
            .arc_circle => |node| bulge(bounds, node.data.target, node.data.radius, node.data.radius),
            .arc_ellipse => |node| bulge(bounds, node.data.target, node.data.radius_x, node.data.radius_y),
            inline else => |node| include(bounds, node),
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names) |name| include(bounds, @field(value, name)),
        .@"union" => |info| if (info.tag_type != null) switch (value) {
            inline else => |payload| include(bounds, payload),
        },
        .pointer => |info| if (info.size == .slice) for (value) |item| include(bounds, item),
        .optional => if (value) |item| include(bounds, item),
        else => {},
    }
}

/// Widens `bounds` around an arc end point by the arc's radii.
fn bulge(bounds: *Bounds, target: svg2tvg.tvg.Point, radius_x: f32, radius_y: f32) void {
    include(bounds, target);
    // An over-estimate; keep it inside the 24-unit grid it is checked against.
    bounds.min_x = @min(bounds.min_x, @max(0, target.x - radius_x));
    bounds.max_x = @max(bounds.max_x, @min(24, target.x + radius_x));
    bounds.min_y = @min(bounds.min_y, @max(0, target.y - radius_y));
    bounds.max_y = @max(bounds.max_y, @min(24, target.y + radius_y));
}

test "every keycap symbol has a drawable glyph that fills its icon box" {
    inline for (@typeInfo(Symbol).@"enum".field_values) |value| {
        const symbol: Symbol = @fromBackingInt(value);
        switch (glyph(symbol)) {
            .text => |text| try std.testing.expect(text.len > 0 and text.len <= 3),
            .icon, .svg => {
                const bytes = switch (glyph(symbol)) {
                    .icon => |icon| icon,
                    .svg => |custom| try convert(std.testing.allocator, custom),
                    .text => unreachable,
                };
                defer if (glyph(symbol) == .svg) std.testing.allocator.free(bytes);
                const bounds = inspect(bytes) catch |err| {
                    std.debug.print("symbol {t} does not parse\n", .{symbol});
                    return err;
                };
                errdefer std.debug.print("symbol {t} draws {d} commands in {any}\n", .{ symbol, bounds.commands, bounds });
                try std.testing.expect(bounds.commands > 0);
                // Lucide icons span most of their 24-unit grid; an icon squeezed
                // into a corner or collapsed to a line would read as broken.
                try std.testing.expect(bounds.max_x - bounds.min_x >= 8);
                try std.testing.expect(bounds.max_y - bounds.min_y >= 4);
                try std.testing.expect(bounds.min_x >= 0 and bounds.min_y >= 0);
                try std.testing.expect(bounds.max_x <= 24 and bounds.max_y <= 24);
            },
        }
    }
}

test "first-party icons convert once and are reused" {
    const first = customIcon(.mouse_left) orelse return error.ConversionFailed;
    const second = customIcon(.mouse_left) orelse return error.ConversionFailed;
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expect(symbolIcon(.insert) == null);
    try std.testing.expect(symbolIcon(.delete_forward) != null);
}

test "every retained cache icon parses and resolver returns owned immutable bytes" {
    const t = std.testing;
    for (entries) |entry| {
        var reader = std.Io.Reader.fixed(entry.bytes);
        var parser = try svg2tvg.tvg.parse(t.allocator, &reader);
        defer parser.deinit();
        var count: usize = 0;
        while (try parser.next()) |_| count += 1;
        try t.expect(count > 0);
        const owned = (try resolve(&context, t.allocator, entry.name)).?;
        defer t.allocator.free(owned);
        try t.expectEqualSlices(u8, entry.bytes, owned);
        try t.expect(owned.ptr != entry.bytes.ptr);
    }
    try t.expect(try resolve(&context, t.allocator, "unknown") == null);
}
