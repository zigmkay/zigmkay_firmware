//! Keycap symbols carried inside caption strings.
//!
//! Compact keycap captions encode each keyboard symbol as one code point of the
//! Unicode Private Use Area, so captions stay plain strings in the label cache.
//! The GUI draws these code points as vector icons, which renders identically on
//! every host and does not depend on system fonts. `plain` restores readable
//! Unicode glyphs for contexts without icons, and `name` spells a symbol out for
//! inspectors and search.
const std = @import("std");

pub const Symbol = enum(u8) {
    backspace,
    delete_forward,
    escape,
    tab,
    caps_lock,
    enter,
    space,
    shift,
    control,
    option,
    command,
    windows,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    insert,
    print_screen,
    scroll_lock,
    pause,
    menu,
    power,
    volume_up,
    volume_down,
    mute,
    next_track,
    previous_track,
    mouse_left,
    mouse_right,
    mouse_middle,
    mouse_back,
    mouse_forward,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
    companion,
    shutdown,
    log_toggle,
    layer,
    callback,
    one_shot,
    dead_key,

    pub const first: u21 = 0xE000;

    pub fn codepoint(symbol: Symbol) u21 {
        return first + @as(u21, @backingInt(symbol));
    }

    pub fn fromCodepoint(value: u21) ?Symbol {
        if (value < first) return null;
        return std.enums.fromInt(Symbol, value - first);
    }

    /// The UTF-8 encoding of the symbol's code point.
    pub fn text(symbol: Symbol) []const u8 {
        return &encoded[@backingInt(symbol)];
    }

    /// `text` for comptime concatenation.
    pub fn literal(comptime symbol: Symbol) *const [3]u8 {
        return comptime &encoded[@backingInt(symbol)];
    }

    /// The spelled-out name shown where keys are described rather than drawn.
    pub fn name(symbol: Symbol) []const u8 {
        return switch (symbol) {
            .backspace => "Backspace",
            .delete_forward => "Delete",
            .escape => "Escape",
            .tab => "Tab",
            .caps_lock => "Caps Lock",
            .enter => "Return",
            .space => "Space",
            .shift => "Shift",
            .control => "Control",
            .option => "Option",
            .command => "Command",
            .windows => "Windows",
            .left => "Left",
            .right => "Right",
            .up => "Up",
            .down => "Down",
            .home => "Home",
            .end => "End",
            .page_up => "Page Up",
            .page_down => "Page Down",
            .insert => "Insert",
            .print_screen => "Print Screen",
            .scroll_lock => "Scroll Lock",
            .pause => "Pause",
            .menu => "Menu",
            .power => "Power",
            .volume_up => "Volume Up",
            .volume_down => "Volume Down",
            .mute => "Mute",
            .next_track => "Next Track",
            .previous_track => "Previous Track",
            .mouse_left => "Left Click",
            .mouse_right => "Right Click",
            .mouse_middle => "Middle Click",
            .mouse_back => "Mouse Back",
            .mouse_forward => "Mouse Forward",
            .wheel_up => "Scroll Up",
            .wheel_down => "Scroll Down",
            .wheel_left => "Scroll Left",
            .wheel_right => "Scroll Right",
            .companion => "Show / hide companion",
            .shutdown => "Quit companion",
            .log_toggle => "Toggle companion logging",
            .layer => "Layer",
            .callback => "Callback",
            .one_shot => "One-shot",
            .dead_key => "Dead key",
        };
    }

    /// A Unicode glyph, or a short word, for text-only contexts.
    pub fn glyph(symbol: Symbol) []const u8 {
        return switch (symbol) {
            .backspace => "⌫",
            .delete_forward => "⌦",
            .escape => "⎋",
            .tab => "⇥",
            .caps_lock => "⇪",
            .enter => "↩",
            .space => "␣",
            .shift => "⇧",
            .control => "⌃",
            .option => "⌥",
            .command => "⌘",
            .windows => "Win",
            .left => "←",
            .right => "→",
            .up => "↑",
            .down => "↓",
            .home => "↖",
            .end => "↘",
            .page_up => "⇞",
            .page_down => "⇟",
            .insert => "Ins",
            .print_screen => "PrtSc",
            .scroll_lock => "ScrLk",
            .pause => "Pause",
            .menu => "☰",
            .power => "⏻",
            .volume_up => "🔊",
            .volume_down => "🔉",
            .mute => "🔇",
            .next_track => "⏭",
            .previous_track => "⏮",
            .mouse_left => "LMB",
            .mouse_right => "RMB",
            .mouse_middle => "MMB",
            .mouse_back => "MB4",
            .mouse_forward => "MB5",
            .wheel_up => "⇡",
            .wheel_down => "⇣",
            .wheel_left => "⇠",
            .wheel_right => "⇢",
            .companion => "◉",
            .shutdown => "✕",
            .log_toggle => "◎",
            .layer => "L",
            .callback => "ƒ",
            .one_shot => "¹",
            .dead_key => "◌",
        };
    }
};

const symbol_count = @typeInfo(Symbol).@"enum".field_names.len;

const encoded: [symbol_count][3]u8 = blk: {
    var result: [symbol_count][3]u8 = undefined;
    for (&result, 0..) |*bytes, index| {
        _ = std.unicode.utf8Encode(Symbol.first + index, bytes) catch unreachable;
    }
    break :blk result;
};

/// One drawable run of a caption line: literal text or a single symbol.
pub const Run = union(enum) {
    text: []const u8,
    symbol: Symbol,
};

/// Splits a caption line into text and symbol runs. Invalid UTF-8 is returned
/// as text so that nothing is silently dropped.
pub const RunIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *RunIterator) ?Run {
        if (self.index >= self.bytes.len) return null;
        const start = self.index;
        while (self.index < self.bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(self.bytes[self.index]) catch {
                self.index += 1;
                continue;
            };
            const end = @min(self.bytes.len, self.index + length);
            const value = std.unicode.utf8Decode(self.bytes[self.index..end]) catch {
                self.index = end;
                continue;
            };
            if (Symbol.fromCodepoint(value)) |symbol| {
                if (self.index == start) {
                    self.index = end;
                    return .{ .symbol = symbol };
                }
                return .{ .text = self.bytes[start..self.index] };
            }
            self.index = end;
        }
        return .{ .text = self.bytes[start..self.index] };
    }
};

pub fn runs(line: []const u8) RunIterator {
    return .{ .bytes = line };
}

/// Replaces every symbol with its Unicode glyph, for logs, clipboards and menus.
pub fn plain(caption: []const u8, buffer: []u8) []const u8 {
    return replace(caption, buffer, Symbol.glyph);
}

/// Replaces every symbol with its spelled-out name.
pub fn spelled(caption: []const u8, buffer: []u8) []const u8 {
    return replace(caption, buffer, Symbol.name);
}

fn replace(caption: []const u8, buffer: []u8, comptime render: fn (Symbol) []const u8) []const u8 {
    var used: usize = 0;
    var iterator = runs(caption);
    while (iterator.next()) |run| {
        const part = switch (run) {
            .text => |value| value,
            .symbol => |symbol| render(symbol),
        };
        if (used + part.len > buffer.len) break;
        @memcpy(buffer[used..][0..part.len], part);
        used += part.len;
    }
    return buffer[0..used];
}

/// Whether the caption still contains a keyboard glyph that should have been a
/// symbol. Fonts render these inconsistently or not at all across hosts.
pub fn containsBareGlyph(caption: []const u8) bool {
    const view = std.unicode.Utf8View.init(caption) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |value| {
        if (isKeyboardGlyph(value)) return true;
    }
    return false;
}

fn isKeyboardGlyph(value: u21) bool {
    return (value >= 0x2190 and value <= 0x21FF) or // Arrows
        (value >= 0x2300 and value <= 0x23FF) or // Miscellaneous Technical
        (value >= 0x2400 and value <= 0x243F) or // Control Pictures
        (value >= 0x1F500 and value <= 0x1F5FF); // Speakers and other pictographs
}

test "symbols round trip through their private use code points" {
    inline for (@typeInfo(Symbol).@"enum".field_values) |value| {
        const symbol: Symbol = @fromBackingInt(@intCast(value));
        try std.testing.expectEqual(symbol, Symbol.fromCodepoint(symbol.codepoint()).?);
        const decoded = try std.unicode.utf8Decode(symbol.text());
        try std.testing.expectEqual(symbol.codepoint(), decoded);
        try std.testing.expect(symbol.name().len != 0);
        try std.testing.expect(symbol.glyph().len != 0);
    }
    try std.testing.expectEqual(@as(?Symbol, null), Symbol.fromCodepoint('A'));
    try std.testing.expectEqual(@as(?Symbol, null), Symbol.fromCodepoint(Symbol.first + symbol_count));
}

test "runs split text and symbols and keep invalid bytes as text" {
    const caption = "A" ++ Symbol.literal(.shift) ++ Symbol.literal(.command) ++ "Z";
    var iterator = runs(caption);
    try std.testing.expectEqualStrings("A", iterator.next().?.text);
    try std.testing.expectEqual(Symbol.shift, iterator.next().?.symbol);
    try std.testing.expectEqual(Symbol.command, iterator.next().?.symbol);
    try std.testing.expectEqualStrings("Z", iterator.next().?.text);
    try std.testing.expectEqual(@as(?Run, null), iterator.next());

    var invalid = runs("a\xffb");
    try std.testing.expectEqualStrings("a\xffb", invalid.next().?.text);
    try std.testing.expectEqual(@as(?Run, null), invalid.next());
}

test "plain and spelled captions restore readable text" {
    var buffer: [64]u8 = undefined;
    const caption = Symbol.literal(.shift) ++ "1";
    try std.testing.expectEqualStrings("⇧1", plain(caption, &buffer));
    try std.testing.expectEqualStrings("Shift1", spelled(caption, &buffer));
    var small: [2]u8 = undefined;
    try std.testing.expectEqualStrings("", plain(caption, &small));
}

test "bare keyboard glyphs are detected" {
    try std.testing.expect(containsBareGlyph("⌫"));
    try std.testing.expect(containsBareGlyph("x↩"));
    try std.testing.expect(containsBareGlyph("🔊"));
    try std.testing.expect(!containsBareGlyph("Ä ß ( ) {"));
    try std.testing.expect(!containsBareGlyph(Symbol.backspace.text()));
}
