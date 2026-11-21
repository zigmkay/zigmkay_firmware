const p = @import("project");
const std = @import("std");
const Modifiers = @import("layout-model").Modifiers;
const KeyCodeFire = @import("layout-model").KeyCodeFire;
pub const keycap_symbols = @import("keycap_symbols.zig");
const Symbol = keycap_symbols.Symbol;
pub const Host = enum { macos, windows, linux };

pub const running_host: Host = switch (@import("builtin").os.tag) {
    .macos => .macos,
    .windows => .windows,
    else => .linux,
};

pub fn runningHost() Host {
    return running_host;
}

/// The symbol a compact keycap draws for a HID usage, if it has one.
pub fn usageSymbol(code: u8) ?Symbol {
    return switch (code) {
        40, 88 => .enter,
        41 => .escape,
        42 => .backspace,
        43 => .tab,
        44 => .space,
        57 => .caps_lock,
        70 => .print_screen,
        71 => .scroll_lock,
        72 => .pause,
        73 => .insert,
        74 => .home,
        75 => .page_up,
        76 => .delete_forward,
        77 => .end,
        78 => .page_down,
        79 => .right,
        80 => .left,
        81 => .down,
        82 => .up,
        101 => .menu,
        102 => .power,
        127 => .mute,
        128 => .volume_up,
        129 => .volume_down,
        254 => .companion,
        255 => .shutdown,
        else => null,
    };
}

// Keycaps draw symbols and omit modifier handedness; inspectors spell out both.
pub fn keycapUsage(host: Host, code: u8, buffer: []u8) []const u8 {
    if (code >= 224 and code <= 231) return keycapModifiers(host, @as(u8, 1) << @intCast(code - 224), buffer);
    if (usageSymbol(code)) |symbol| return symbol.text();
    return switch (code) {
        83 => "Num",
        252 => "Boot",
        253 => "Stats",
        else => usage(code, buffer),
    };
}

/// Compact modifier symbols in the host's conventional order. macOS follows
/// the menu order ⌃⌥⇧⌘; other hosts print Ctrl and Alt as on their keycaps.
pub fn keycapModifiers(host: Host, bits: u8, buffer: []u8) []const u8 {
    const either = bits | (bits >> 4);
    const Part = struct { bit: u3, text: []const u8 };
    const parts: [4]Part = switch (host) {
        .macos => .{
            .{ .bit = 0, .text = Symbol.control.text() },
            .{ .bit = 2, .text = Symbol.option.text() },
            .{ .bit = 1, .text = Symbol.shift.text() },
            .{ .bit = 3, .text = Symbol.command.text() },
        },
        .windows, .linux => .{
            .{ .bit = 0, .text = "Ctrl" },
            .{ .bit = 1, .text = Symbol.shift.text() },
            .{ .bit = 2, .text = "Alt" },
            .{ .bit = 3, .text = Symbol.windows.text() },
        },
    };
    var used: usize = 0;
    for (parts) |part| {
        if (either & (@as(u8, 1) << part.bit) == 0) continue;
        const written = std.fmt.bufPrint(buffer[used..], "{s}{s}", .{
            if (used == 0 or host == .macos) "" else "+",
            part.text,
        }) catch return "Modifiers";
        used += written.len;
    }
    return buffer[0..used];
}

pub fn hostUsage(host: Host, code: u8, buffer: []u8) []const u8 {
    if (code >= 224 and code <= 231) {
        return hostModifierNames(
            host,
            @as(u8, 1) << @intCast(code - 224),
            buffer,
        );
    }
    // Inspectors spell keys out and keep the keycap symbol in front.
    const symbol = usageSymbol(code) orelse return usage(code, buffer);
    var name_buffer: [64]u8 = undefined;
    const name = usage(code, &name_buffer);
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ symbol.text(), name }) catch name;
}

pub fn hostModifierNames(host: Host, bits: u8, buffer: []u8) []const u8 {
    const control = Symbol.literal(.control);
    const shift = Symbol.literal(.shift);
    const option = Symbol.literal(.option);
    const command = Symbol.literal(.command);
    const names: [8][]const u8 = switch (host) {
        .macos => .{
            "L " ++ control ++ " Control",
            "L " ++ shift ++ " Shift",
            "L " ++ option ++ " Option",
            "L " ++ command ++ " Command",
            "R " ++ control ++ " Control",
            "R " ++ shift ++ " Shift",
            "R " ++ option ++ " Option",
            "R " ++ command ++ " Command",
        },
        .windows => .{ "L Ctrl", "L Shift", "L Alt", "L Win", "R Ctrl", "R Shift", "R Alt", "R Win" },
        .linux => .{ "L Ctrl", "L Shift", "L Alt", "L Super", "R Ctrl", "R Shift", "R Alt", "R Super" },
    };
    var used: usize = 0;
    for (names, 0..) |name, bit| {
        if (bits & (@as(u8, 1) << @intCast(bit)) == 0) continue;
        const part = std.fmt.bufPrint(
            buffer[used..],
            "{s}{s}",
            .{ if (used == 0) "" else "+", name },
        ) catch return "Modifiers";
        used += part.len;
    }
    return buffer[0..used];
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn matchesUsage(host: Host, code: u8, query: []const u8) bool {
    if (std.fmt.parseInt(u8, query, 0)) |numeric| {
        if (numeric == code) return true;
    } else |_| {}
    var buffer: [128]u8 = undefined;
    if (containsIgnoreCase(hostUsage(host, code, &buffer), query) or
        containsIgnoreCase(usage(code, &buffer), query)) return true;
    const aliases = switch (code) {
        224, 228 => "Ctrl Control ⌃",
        225, 229 => "Shift ⇧",
        226, 230 => "Alt Option ⌥",
        227, 231 => "GUI Cmd Command Win Super ⌘",
        40 => "Return Enter ↩ ⏎",
        41 => "Escape Esc ⎋",
        42 => "Backspace ⌫",
        43 => "Tab ⇥",
        44 => "Space Spacebar ␣",
        76 => "Delete Forward Del ⌦",
        else => "",
    };
    return aliases.len > 0 and containsIgnoreCase(aliases, query);
}

pub fn usage(code: u8, buffer: []u8) []const u8 {
    if (code >= 4 and code <= 29) {
        if (buffer.len == 0) return "?";
        buffer[0] = 'A' + code - 4;
        return buffer[0..1];
    }
    if (code >= 30 and code <= 38) {
        if (buffer.len == 0) return "?";
        buffer[0] = '1' + code - 30;
        return buffer[0..1];
    }
    return switch (code) {
        0 => "—",
        39 => "0",
        40 => "Return",
        41 => "Escape",
        42 => "Backspace",
        43 => "Tab",
        44 => "Space",
        45 => "-",
        46 => "=",
        47 => "[",
        48 => "]",
        49 => "\\",
        51 => ";",
        52 => "'",
        53 => "`",
        54 => ",",
        55 => ".",
        56 => "/",
        57 => "Caps Lock",
        70 => "Print Screen",
        71 => "Scroll Lock",
        72 => "Pause",
        73 => "Insert",
        74 => "Home",
        75 => "Page Up",
        76 => "Delete",
        77 => "End",
        78 => "Page Down",
        79 => "Right",
        80 => "Left",
        81 => "Down",
        82 => "Up",
        224 => "L Ctrl",
        225 => "L Shift",
        226 => "L Alt",
        227 => "L GUI",
        228 => "R Ctrl",
        229 => "R Shift",
        230 => "R Alt",
        231 => "R GUI",
        252 => "BOOT",
        253 => "Print statistics",
        254 => "Show / hide companion",
        255 => "Quit companion",
        else => knownUsage(code, buffer),
    };
}

fn knownUsage(code: u8, buffer: []u8) []const u8 {
    const info = @typeInfo(@import("zkeycodes").layouts.keycodes.kc.basic).@"enum";
    inline for (info.field_names, info.field_values) |enum_name, enum_value| {
        const field = .{ .name = enum_name, .value = enum_value };
        if (field.value == code) {
            const name = field.name[3..];
            const len = @min(name.len, buffer.len);
            for (name[0..len], 0..) |char, i| buffer[i] = if (char == '_') ' ' else char;
            return buffer[0..len];
        }
    }
    return std.fmt.bufPrint(buffer, "HID {d}", .{code}) catch "?";
}

/// A symbol as inspectors spell keys out: the symbol, then its name.
pub fn spelled(symbol: Symbol, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ symbol.text(), symbol.name() }) catch symbol.name();
}

/// An enum tag in words for the inspector: "VolumeUp" becomes "Volume up".
pub fn words(tag: []const u8, buffer: []u8) []const u8 {
    var used: usize = 0;
    for (tag, 0..) |char, index| {
        const upper = std.ascii.isUpper(char);
        if (upper and index != 0 and used < buffer.len) {
            buffer[used] = ' ';
            used += 1;
        }
        if (used == buffer.len) break;
        buffer[used] = if (upper and index != 0) std.ascii.toLower(char) else char;
        used += 1;
    }
    return buffer[0..used];
}

pub fn tap(value: p.Tap, buffer: []u8) []const u8 {
    return tapLabel(value, buffer, false);
}

fn tapLabel(value: p.Tap, buffer: []u8, compact: bool) []const u8 {
    return tapLabelWithLayout(null, value, .{}, buffer, compact);
}

fn tapLabelWithLayout(
    km: anytype,
    value: p.Tap,
    physical: Modifiers,
    buffer: []u8,
    compact: bool,
) []const u8 {
    if (compact) return compactTap(km, value, physical, buffer);
    var used: usize = 0;
    var scratch: [256]u8 = undefined;
    if (value.key_press) |key| {
        var key_buffer: [64]u8 = undefined;
        appendSummary(buffer, &used, keyPressLabel(km, key, physical, false, &key_buffer, &scratch));
        if (key.dead) appendSummary(buffer, &used, "Dead key");
    }
    var name: [64]u8 = undefined;
    if (value.media_key) |media| appendSummary(buffer, &used, words(@tagName(media), &name));
    if (value.mouse_action) |mouse| appendSummary(buffer, &used, words(@tagName(mouse), &name));
    if (value.custom) |custom| appendSummary(buffer, &used, signal(custom, &scratch));
    if (value.one_shot) |one| {
        appendSummary(buffer, &used, "One-shot");
        if (one.layer_id) |id| {
            appendSummary(buffer, &used, std.fmt.bufPrint(&scratch, "L{d}", .{id}) catch "Layer");
        }
        if (one.hold_modifiers.toByte() != 0) {
            appendSummary(buffer, &used, modifierLabel(false, one.hold_modifiers.toByte(), &scratch));
        }
        if (one.custom) |id| {
            appendSummary(buffer, &used, std.fmt.bufPrint(&scratch, "Callback {d}", .{id}) catch "Callback");
        }
    }
    return if (used != 0) buffer[0..used] else "No tap";
}

/// The symbol a compact keycap draws for a media key.
pub fn mediaSymbol(media: @import("layout-model").MediaCode) Symbol {
    return switch (media) {
        .VolumeUp => .volume_up,
        .VolumeDown => .volume_down,
        .VolumeMute => .mute,
        .NextTrack => .next_track,
        .PreviousTrack => .previous_track,
    };
}

/// The symbol a compact keycap draws for a mouse action.
pub fn mouseSymbol(mouse: @import("layout-model").MouseAction) Symbol {
    return switch (mouse) {
        .LeftButton => .mouse_left,
        .RightButton => .mouse_right,
        .MiddleButton => .mouse_middle,
        .Button4 => .mouse_back,
        .Button5 => .mouse_forward,
        .WheelUp => .wheel_up,
        .WheelDown => .wheel_down,
        .WheelLeft => .wheel_left,
        .WheelRight => .wheel_right,
    };
}

/// The symbol of a reserved companion signal id, or null for callbacks.
pub fn signalSymbol(id: u8) ?Symbol {
    return switch (id) {
        253 => .log_toggle,
        254 => .shutdown,
        255 => .companion,
        else => null,
    };
}

/// A tap as drawn on a keycap: symbols where possible and no separators.
fn compactTap(km: anytype, value: p.Tap, physical: Modifiers, buffer: []u8) []const u8 {
    var writer: Compact = .{ .buffer = buffer };
    var scratch: [256]u8 = undefined;
    if (value.key_press) |key| {
        var key_buffer: [64]u8 = undefined;
        writer.append(keyPressLabel(km, key, physical, true, &key_buffer, &scratch));
        if (key.dead) writer.append(Symbol.dead_key.text());
    }
    if (value.media_key) |media| writer.append(mediaSymbol(media).text());
    if (value.mouse_action) |mouse| writer.append(mouseSymbol(mouse).text());
    if (value.custom) |custom| writer.custom(custom);
    if (value.one_shot) |one| {
        writer.append(Symbol.one_shot.text());
        if (one.layer_id) |id| writer.layer(id);
        if (one.hold_modifiers.toByte() != 0) writer.append(keycapModifiers(running_host, one.hold_modifiers.toByte(), &scratch));
        if (one.custom) |id| writer.custom(id);
    }
    return writer.slice();
}

/// Appends compact keycap parts without separators; symbols delimit themselves.
const Compact = struct {
    buffer: []u8,
    used: usize = 0,

    fn append(self: *Compact, text: []const u8) void {
        if (self.used + text.len > self.buffer.len) return;
        @memcpy(self.buffer[self.used..][0..text.len], text);
        self.used += text.len;
    }

    fn layer(self: *Compact, id: p.LayerId) void {
        var scratch: [16]u8 = undefined;
        self.append(Symbol.layer.text());
        self.append(std.fmt.bufPrint(&scratch, "{d}", .{id}) catch "?");
    }

    fn custom(self: *Compact, id: u8) void {
        if (signalSymbol(id)) |symbol| return self.append(symbol.text());
        var scratch: [8]u8 = undefined;
        self.append(Symbol.callback.text());
        self.append(std.fmt.bufPrint(&scratch, "{d}", .{id}) catch "?");
    }

    fn slice(self: *const Compact) []const u8 {
        return self.buffer[0..self.used];
    }
};

fn usageLabel(compact: bool, code: u8, buffer: []u8) []const u8 {
    return if (compact) keycapUsage(running_host, code, buffer) else hostUsage(running_host, code, buffer);
}

fn modifierLabel(compact: bool, bits: u8, buffer: []u8) []const u8 {
    return if (compact) keycapModifiers(running_host, bits, buffer) else hostModifierNames(running_host, bits, buffer);
}

/// Labels a key press, translated through the host layout `km` unless it is null.
/// The result may point into `key_buffer` or `scratch`.
fn keyPressLabel(
    km: anytype,
    key: KeyCodeFire,
    physical: Modifiers,
    compact: bool,
    key_buffer: *[64]u8,
    scratch: *[256]u8,
) []const u8 {
    var key_name = usageLabel(compact, key.tap_keycode, key_buffer);
    const layout_dependent = @import("zkeymap").isLayoutDependent(key.tap_keycode) and key.tap_keycode != 44;
    var mods = if (layout_dependent) key.tap_modifiers.add(physical) else key.tap_modifiers;
    if (comptime @TypeOf(km) != @TypeOf(null)) {
        // Shortcuts retain their modifiers, but their base key follows the
        // layout. Text-producing modifiers are consumed only on success.
        const shortcut = mods.left_ctrl or mods.right_ctrl or mods.left_gui or mods.right_gui;
        const translated = km.keyToText(.{
            .tap_keycode = key.tap_keycode,
            .tap_modifiers = if (shortcut) .{} else mods,
            .dead = key.dead,
        });
        const text = translated.slice();
        if (!translated.isLabel() and text.len > 0 and key.tap_keycode != 44 and isPrintable(text)) {
            @memcpy(key_buffer[0..text.len], text);
            // Keep conventional uppercase keycaps for plain letters.
            if (compact and (shortcut or mods.toByte() == 0) and text.len == 1)
                key_buffer[0] = std.ascii.toUpper(key_buffer[0]);
            key_name = key_buffer[0..text.len];
            if (!shortcut) mods = .{};
        }
    }
    if (mods.toByte() == 0) return key_name;
    var mod_buffer: [192]u8 = undefined;
    return std.fmt.bufPrint(scratch, "{s}{s}{s}", .{
        modifierLabel(compact, mods.toByte(), &mod_buffer),
        if (compact and running_host == .macos) "" else "+",
        key_name,
    }) catch "Chord";
}

fn isPrintable(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 32 or byte == 127) return false;
    }
    return true;
}

fn appendSummary(buffer: []u8, used: *usize, text: []const u8) void {
    const part = std.fmt.bufPrint(
        buffer[used.*..],
        "{s}{s}",
        .{ if (used.* == 0) "" else " · ", text },
    ) catch return;
    used.* += part.len;
}

/// What a key does in plain words, as the editor explains it below the
/// keyboard: "Tap: K. Hold: L ⇧ Shift after 180 ms." Mode names never appear.
pub fn behaviour(value: ?p.Action, doc: p.Document, buffer: []u8) []const u8 {
    const a = value orelse return "Falls through to the layer below.";
    var tap_buffer: [256]u8 = undefined;
    var hold_buffer: [256]u8 = undefined;
    return switch (a) {
        .none => "Does nothing.",
        .tap_only => |t| std.fmt.bufPrint(buffer, "Tap: {s}.", .{tap(t, &tap_buffer)}) catch "Tap.",
        .hold_only => |h| std.fmt.bufPrint(buffer, "Hold: {s}.", .{hold(h, doc, &hold_buffer)}) catch "Hold.",
        .tap_hold => |th| std.fmt.bufPrint(buffer, "Tap: {s}. Hold: {s} after {d} ms{s}.", .{
            tap(th.tap, &tap_buffer),
            hold(th.hold, doc, &hold_buffer),
            th.tapping_term.ms,
            if (th.retro_tapping) ", or the tap when released alone" else "",
        }) catch "Tap and hold.",
        .tap_with_autofire => |af| std.fmt.bufPrint(buffer, "Tap: {s}. Hold: repeats every {d} ms after {d} ms.", .{
            tap(af.tap, &tap_buffer),
            af.repeat_interval.ms,
            af.initial_delay.ms,
        }) catch "Tap, repeating while held.",
    };
}

pub fn signal(id: u8, buffer: []u8) []const u8 {
    return switch (id) {
        253 => "Toggle companion logging",
        254 => "Quit companion",
        255 => "Show / hide companion",
        else => std.fmt.bufPrint(buffer, "Custom {d}", .{id}) catch "Custom",
    };
}

pub fn keycap(value: ?p.Action, doc: p.Document, buffer: []u8) []const u8 {
    return keycapWithLayout(null, value, doc, .{}, buffer);
}

test "companion keycaps draw signals as symbols" {
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "fixture",
        .name = "Fixture",
        .key_ids = &.{},
        .layers = &.{},
    };
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(Symbol.companion.text(), keycap(.{ .tap_only = .{ .custom = 255 } }, doc, &buffer));
    try std.testing.expectEqualStrings(Symbol.companion.text(), keycap(.{ .tap_only = .{
        .key_press = .{ .tap_keycode = 254 },
    } }, doc, &buffer));
    try std.testing.expectEqualStrings(Symbol.shutdown.text(), keycap(.{ .tap_only = .{
        .key_press = .{ .tap_keycode = 255 },
    } }, doc, &buffer));
    try std.testing.expectEqualStrings(Symbol.log_toggle.text(), keycap(.{ .hold_only = .{ .custom = 253 } }, doc, &buffer));
    try std.testing.expect(
        !containsIgnoreCase(keycap(.{ .hold_only = .{ .custom = 255 } }, doc, &buffer), "Show"),
    );
}

/// The compact keycap caption. The first line is the tap and the optional
/// second line the hold; hold-only keys draw their hold as the main line.
pub fn keycapWithLayout(
    km: anytype,
    value: ?p.Action,
    doc: p.Document,
    physical: Modifiers,
    buffer: []u8,
) []const u8 {
    const a = value orelse return "Inherited";
    var tap_buffer: [128]u8 = undefined;
    var hold_buffer: [128]u8 = undefined;
    return switch (a) {
        .tap_only => |t| tapLabelWithLayout(km, t, physical, buffer, true),
        .tap_with_autofire => |t| tapLabelWithLayout(km, t.tap, physical, buffer, true),
        .tap_hold => |th| std.fmt.bufPrint(buffer, "{s}\n{s}", .{
            tapLabelWithLayout(km, th.tap, physical, &tap_buffer, true),
            holdLabel(th.hold, doc, &hold_buffer, true),
        }) catch "Tap / hold",
        .hold_only => |h| holdLabel(h, doc, buffer, true),
        else => action(value, buffer),
    };
}

pub fn hold(value: p.Hold, doc: p.Document, buffer: []u8) []const u8 {
    return holdLabel(value, doc, buffer, false);
}

fn holdLabel(value: p.Hold, doc: p.Document, buffer: []u8, compact: bool) []const u8 {
    if (compact) {
        var writer: Compact = .{ .buffer = buffer };
        var scratch: [256]u8 = undefined;
        if (value.layer_id) |id| writer.layer(layerNumber(doc, id));
        if (value.hold_modifiers.toByte() != 0) writer.append(keycapModifiers(running_host, value.hold_modifiers.toByte(), &scratch));
        if (value.custom) |id| writer.custom(id);
        return writer.slice();
    }
    var used: usize = 0;
    var scratch: [256]u8 = undefined;
    if (value.layer_id) |id| {
        const label = std.fmt.bufPrint(&scratch, "L{d} {s}", .{ layerNumber(doc, id), layerName(doc, id) });
        appendSummary(buffer, &used, label catch "Layer");
    }
    if (value.hold_modifiers.toByte() != 0) {
        appendSummary(buffer, &used, modifierLabel(false, value.hold_modifiers.toByte(), &scratch));
    }
    if (value.custom) |id| {
        const label = if (id < 253) std.fmt.bufPrint(&scratch, "Callback {d}", .{id}) catch "Callback" else signal(id, &scratch);
        appendSummary(buffer, &used, label);
    }
    return if (used != 0) buffer[0..used] else "No hold fields";
}

fn layerName(doc: p.Document, id: p.LayerId) []const u8 {
    for (doc.layers) |layer| {
        if (layer.id == id) return layer.name;
    }
    return "Missing layer";
}

/// The position shown in the layer list, or the stable id of a missing layer.
fn layerNumber(doc: p.Document, id: p.LayerId) p.LayerId {
    for (doc.layers, 0..) |layer, index| {
        if (layer.id == id) return @intCast(index);
    }
    return id;
}

pub fn action(value: ?p.Action, buffer: []u8) []const u8 {
    const a = value orelse return "Inherited";
    return switch (a) {
        .none => "None",
        .tap_only => |t| tap(t, buffer),
        .tap_hold => |t| tap(t.tap, buffer),
        .tap_with_autofire => |t| tap(t.tap, buffer),
        .hold_only => |h| if (h.layer_id) |id|
            std.fmt.bufPrint(buffer, "Layer {d}", .{id}) catch "?"
        else if (h.custom) |id|
            std.fmt.bufPrint(buffer, "Custom {d}", .{id}) catch "?"
        else
            "Modifiers",
    };
}

pub const HostKey = struct { code: u8, name: []const u8 = "", units: f32 = 1 };

/// Compares a compact caption by its readable glyphs and checks that every
/// keyboard glyph in it is a drawable symbol rather than font text.
fn expectCaption(expected: []const u8, caption: []const u8) !void {
    var buffer: [256]u8 = undefined;
    try std.testing.expect(!keycap_symbols.containsBareGlyph(caption));
    try std.testing.expectEqualStrings(expected, keycap_symbols.plain(caption, &buffer));
}

test "layout captions consume text modifiers and preserve shortcuts holds and fallbacks" {
    var source: @import("label_fixture.zig").Fixture = .{};
    var buffer: [256]u8 = undefined;
    const left: p.Tap = .{ .key_press = .{ .tap_keycode = 38, .tap_modifiers = .{ .left_shift = true } } };
    try std.testing.expectEqualStrings("(", tapLabelWithLayout(&source, left, .{}, &buffer, true));
    try std.testing.expectEqualStrings("(", tapLabelWithLayout(&source, left, .{}, &buffer, false));
    const right: p.Tap = .{ .key_press = .{ .tap_keycode = 39, .tap_modifiers = .{ .right_shift = true } } };
    try std.testing.expectEqualStrings(")", tapLabelWithLayout(&source, right, .{}, &buffer, true));
    try std.testing.expectEqualStrings(
        "{",
        tapLabelWithLayout(
            &source,
            .{ .key_press = .{ .tap_keycode = 47 } },
            .{ .right_shift = true },
            &buffer,
            true,
        ),
    );
    const shortcut: p.Tap = .{ .key_press = .{
        .tap_keycode = 29,
        .tap_modifiers = .{ .left_gui = true, .left_shift = true },
    } };
    try expectCaption(
        if (running_host == .macos) "⇧⌘Z" else "⇧+Win+Z",
        tapLabelWithLayout(&source, shortcut, .{}, &buffer, true),
    );
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "",
        .name = "",
        .key_ids = &.{},
        .layers = &.{},
    };
    const action_value: p.Action = .{ .tap_hold = .{
        .tap = left,
        .hold = .{ .hold_modifiers = .{ .left_ctrl = true } },
        .tapping_term = .{ .ms = 200 },
    } };
    try expectCaption(
        if (running_host == .macos) "(\n⌃" else "(\nCtrl",
        keycapWithLayout(&source, action_value, doc, .{}, &buffer),
    );
    try std.testing.expectEqualStrings("(", keycapWithLayout(&source, .{ .tap_with_autofire = .{
        .tap = left,
        .initial_delay = .{ .ms = 200 },
        .repeat_interval = .{ .ms = 50 },
    } }, doc, .{}, &buffer));
    try expectCaption(
        if (running_host == .macos) "⇧↩" else "⇧+↩",
        tapLabelWithLayout(&source, .{ .key_press = .{
            .tap_keycode = 40,
            .tap_modifiers = .{ .left_shift = true },
        } }, .{}, &buffer, true),
    );
    const Translation = struct {
        output: @import("zkeymap").TextResult,

        pub fn keyToText(self: *@This(), _: @import("zkeymap").KeyCodeFire) @import("zkeymap").TextResult {
            return self.output;
        }
    };
    var alternate = Translation{ .output = .{ .data = .{ 0xc3, 0xa4, 0, 0 }, .len = 2 } };
    try std.testing.expectEqualStrings(
        "ä",
        tapLabelWithLayout(&alternate, .{ .key_press = .{
            .tap_keycode = 52,
            .tap_modifiers = .{ .right_alt = true },
        } }, .{}, &buffer, true),
    );
    try expectCaption(
        "ä◌",
        tapLabelWithLayout(
            &alternate,
            .{ .key_press = .{ .tap_keycode = 52, .dead = true } },
            .{},
            &buffer,
            true,
        ),
    );
    alternate.output = .{};
    try expectCaption(
        if (running_host == .macos) "⇧9" else "⇧+9",
        tapLabelWithLayout(&alternate, left, .{}, &buffer, true),
    );
    alternate.output = .{ .data = .{ 1, 0, 0, 0 }, .len = 1 };
    try expectCaption(
        if (running_host == .macos) "⇧9" else "⇧+9",
        tapLabelWithLayout(&alternate, left, .{}, &buffer, true),
    );
}

test "compact keycaps draw keyboard symbols and keep descriptive search labels" {
    var buffer: [256]u8 = undefined;
    for ([_]Host{ .macos, .windows, .linux }) |host| {
        for ([_]struct { code: u8, symbol: Symbol }{
            .{ .code = 40, .symbol = .enter },
            .{ .code = 41, .symbol = .escape },
            .{ .code = 42, .symbol = .backspace },
            .{ .code = 43, .symbol = .tab },
            .{ .code = 44, .symbol = .space },
            .{ .code = 57, .symbol = .caps_lock },
            .{ .code = 70, .symbol = .print_screen },
            .{ .code = 73, .symbol = .insert },
            .{ .code = 74, .symbol = .home },
            .{ .code = 75, .symbol = .page_up },
            .{ .code = 76, .symbol = .delete_forward },
            .{ .code = 77, .symbol = .end },
            .{ .code = 78, .symbol = .page_down },
            .{ .code = 79, .symbol = .right },
            .{ .code = 80, .symbol = .left },
            .{ .code = 81, .symbol = .down },
            .{ .code = 82, .symbol = .up },
            .{ .code = 88, .symbol = .enter },
            .{ .code = 101, .symbol = .menu },
            .{ .code = 254, .symbol = .companion },
            .{ .code = 255, .symbol = .shutdown },
        }) |entry| try std.testing.expectEqualStrings(entry.symbol.text(), keycapUsage(host, entry.code, &buffer));
        try std.testing.expect(matchesUsage(host, 42, "Backspace"));
        try std.testing.expect(matchesUsage(host, 76, "Delete"));
        try std.testing.expect(matchesUsage(host, 41, "Escape"));
    }
    try expectCaption("⌘", keycapModifiers(.macos, 0x88, &buffer));
    try expectCaption("⌃⌥⇧⌘", keycapModifiers(.macos, 0xff, &buffer));
    try expectCaption("Ctrl+⇧+Alt+Win", keycapModifiers(.windows, 0xff, &buffer));
    try expectCaption("🔊", tapLabel(.{ .media_key = .VolumeUp }, &buffer, true));
    try std.testing.expectEqualStrings("Volume up", tap(.{ .media_key = .VolumeUp }, &buffer));
    try std.testing.expectEqualStrings("Wheel down", tap(.{ .mouse_action = .WheelDown }, &buffer));
    const chord: p.Tap = .{ .key_press = .{ .tap_keycode = 29, .tap_modifiers = .{ .left_gui = true } } };
    try expectCaption(if (running_host == .macos) "⌘Z" else "Win+Z", tapLabel(chord, &buffer, true));
    try std.testing.expect(
        containsIgnoreCase(
            tap(chord, &buffer),
            if (running_host == .macos) "Command" else if (running_host == .windows) "Win" else "Super",
        ),
    );
}

test "every keycap caption draws keyboard glyphs as symbols" {
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "",
        .name = "",
        .key_ids = &.{},
        .layers = &.{ .{ .id = 7, .name = "Base", .actions = &.{} }, .{ .id = 9, .name = "Nav", .actions = &.{} } },
    };
    var buffer: [256]u8 = undefined;
    for ([_]Host{ .macos, .windows, .linux }) |host| {
        for (0..256) |code| {
            const caption = keycapUsage(host, @intCast(code), &buffer);
            try std.testing.expect(caption.len != 0);
            try std.testing.expect(!keycap_symbols.containsBareGlyph(caption));
        }
        for (0..256) |bits| {
            try std.testing.expect(!keycap_symbols.containsBareGlyph(keycapModifiers(host, @intCast(bits), &buffer)));
        }
    }
    inline for (@typeInfo(@import("layout-model").MediaCode).@"enum".field_values) |value| {
        const tap_value: p.Tap = .{ .media_key = @fromBackingInt(value) };
        try std.testing.expect(!keycap_symbols.containsBareGlyph(keycap(.{ .tap_only = tap_value }, doc, &buffer)));
    }
    inline for (@typeInfo(@import("layout-model").MouseAction).@"enum".field_values) |value| {
        const tap_value: p.Tap = .{ .mouse_action = @fromBackingInt(value) };
        const caption = keycap(.{ .tap_only = tap_value }, doc, &buffer);
        try std.testing.expect(caption.len != 0 and !keycap_symbols.containsBareGlyph(caption));
    }
    for (0..256) |id| {
        const caption = keycap(.{ .hold_only = .{ .custom = @intCast(id) } }, doc, &buffer);
        try std.testing.expect(caption.len != 0 and !keycap_symbols.containsBareGlyph(caption));
    }
    // Layer holds show the position from the layer list, not the stable id.
    try expectCaption("L1", keycap(.{ .hold_only = .{ .layer_id = 9 } }, doc, &buffer));
    try expectCaption("A\nL1⇧", keycap(.{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = 4 } },
        .hold = .{ .layer_id = 9, .hold_modifiers = .{ .left_shift = true } },
        .tapping_term = .{ .ms = 200 },
    } }, doc, &buffer));
    try expectCaption("ƒ7", keycap(.{ .tap_only = .{ .custom = 7 } }, doc, &buffer));
    try expectCaption("¹L1", keycap(.{ .tap_only = .{ .one_shot = .{ .layer_id = 1 } } }, doc, &buffer));
}

test "all basic keycodes have names and companion namespaces remain distinct" {
    var buffer: [256]u8 = undefined;
    inline for (@typeInfo(@import("zkeycodes").layouts.keycodes.kc.basic).@"enum".field_values) |value| {
        try std.testing.expect(!std.mem.startsWith(u8, usage(@intCast(value), &buffer), "HID "));
    }
    try std.testing.expectEqualStrings("Home", usage(74, &buffer));
    try std.testing.expectEqualStrings("Backspace", usage(42, &buffer));
    try std.testing.expectEqualStrings("Delete", usage(76, &buffer));
    try std.testing.expectEqualStrings("Print statistics", usage(253, &buffer));
    try std.testing.expectEqualStrings("Toggle companion logging", tap(.{ .custom = 253 }, &buffer));
    try std.testing.expectEqualStrings("Quit companion", tap(.{ .custom = 254 }, &buffer));
    try std.testing.expectEqualStrings("Show / hide companion", tap(.{ .custom = 255 }, &buffer));
    try std.testing.expect(containsIgnoreCase(tap(.{ .key_press = .{
        .tap_keycode = 30,
        .tap_modifiers = .{ .left_shift = true },
    } }, &buffer), "Shift"));
}

pub const rows = [_][]const HostKey{
    &.{
        .{ .code = 41 },
        .{ .code = 58 },
        .{ .code = 59 },
        .{ .code = 60 },
        .{ .code = 61 },
        .{ .code = 62 },
        .{ .code = 63 },
        .{ .code = 64 },
        .{ .code = 65 },
        .{ .code = 66 },
        .{ .code = 67 },
        .{ .code = 68 },
        .{ .code = 69 },
        .{ .code = 76, .name = "Del" },
    },
    &.{
        .{ .code = 53 },
        .{ .code = 30 },
        .{ .code = 31 },
        .{ .code = 32 },
        .{ .code = 33 },
        .{ .code = 34 },
        .{ .code = 35 },
        .{ .code = 36 },
        .{ .code = 37 },
        .{ .code = 38 },
        .{ .code = 39 },
        .{ .code = 45 },
        .{ .code = 46 },
        .{ .code = 42, .units = 2 },
    },
    &.{
        .{ .code = 43, .units = 1.5 },
        .{ .code = 20 },
        .{ .code = 26 },
        .{ .code = 8 },
        .{ .code = 21 },
        .{ .code = 23 },
        .{ .code = 28 },
        .{ .code = 24 },
        .{ .code = 12 },
        .{ .code = 18 },
        .{ .code = 19 },
        .{ .code = 47 },
        .{ .code = 48 },
        .{ .code = 49, .units = 1.5 },
    },
    &.{
        .{ .code = 57, .units = 1.75 },
        .{ .code = 4 },
        .{ .code = 22 },
        .{ .code = 7 },
        .{ .code = 9 },
        .{ .code = 10 },
        .{ .code = 11 },
        .{ .code = 13 },
        .{ .code = 14 },
        .{ .code = 15 },
        .{ .code = 51 },
        .{ .code = 52 },
        .{ .code = 40, .units = 2.25 },
    },
    &.{
        .{ .code = 225, .name = "Shift", .units = 2.25 },
        .{ .code = 29 },
        .{ .code = 27 },
        .{ .code = 6 },
        .{ .code = 25 },
        .{ .code = 5 },
        .{ .code = 17 },
        .{ .code = 16 },
        .{ .code = 54 },
        .{ .code = 55 },
        .{ .code = 56 },
        .{ .code = 229, .name = "Shift", .units = 1.75 },
        .{ .code = 82 },
    },
    &.{
        .{ .code = 224, .name = "Control", .units = 1.25 },
        .{ .code = 226, .name = "Option", .units = 1.25 },
        .{ .code = 227, .name = "Command", .units = 1.5 },
        .{ .code = 44, .units = 5.5 },
        .{ .code = 231, .name = "Command", .units = 1.5 },
        .{ .code = 230, .name = "Option" },
        .{ .code = 80 },
        .{ .code = 81 },
        .{ .code = 79 },
    },
};

test "host glyphs aliases and fallback preserve HID values" {
    var buffer: [256]u8 = undefined;
    try expectCaption("L ⌘ Command", hostUsage(.macos, 227, &buffer));
    try std.testing.expectEqualStrings("L Win", hostUsage(.windows, 227, &buffer));
    try std.testing.expectEqualStrings("R Super", hostUsage(.linux, 231, &buffer));
    for ([_][]const u8{
        "⌘",
        "Command",
        "Cmd",
        "GUI",
        "227",
        "0xe3",
    }) |query| try std.testing.expect(matchesUsage(.macos, 227, query));
    try std.testing.expect(!matchesUsage(.macos, 4, "Cmd"));
}

test "compound tap and one shot summaries show every populated schema field" {
    var buffer: [1024]u8 = undefined;
    const summary = tap(.{
        .key_press = .{ .tap_keycode = 4, .dead = true },
        .media_key = .VolumeUp,
        .mouse_action = .WheelDown,
        .custom = 253,
        .one_shot = .{ .layer_id = 42, .hold_modifiers = .{ .left_gui = true }, .custom = 7 },
    }, &buffer);
    for ([_][]const u8{
        "A",
        "Dead key",
        "Volume up",
        "Wheel down",
        "Toggle companion logging",
        "One-shot",
        "L42",
        "Callback 7",
    }) |part| try std.testing.expect(containsIgnoreCase(summary, part));
}

test "target aware catalog excludes unsupported hold fields and bounds output" {
    const catalog = @import("action_catalog.zig");
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "fixture",
        .name = "Fixture",
        .key_ids = &.{},
        .layers = &.{.{ .id = 42, .name = "Navigation", .actions = &.{} }},
    };
    var entries: [256]catalog.Entry = undefined;
    const count = catalog.search(doc, .hold, .all, "", &entries);
    try std.testing.expectEqual(@as(usize, 12), count);
    for (entries[0..count]) |entry| switch (entry) {
        .modifier, .layer, .callback, .signal => {},
        else => return error.UnsupportedHoldEntry,
    };
    try std.testing.expectEqual(@as(usize, 0), catalog.search(doc, .hold, .media, "", &entries));
    try std.testing.expectEqual(@as(usize, 2), catalog.search(doc, .tap, .modifier, "Cmd", &entries));
    try std.testing.expectEqual(@as(usize, 1), catalog.search(doc, .tap, .key, "252", &entries));
    try std.testing.expectEqual(@as(usize, 1), catalog.search(doc, .tap, .all, "", entries[0..1]));
}

test "empty and small caller buffers keep bounded label fallbacks" {
    const t = std.testing;
    var empty: [0]u8 = .{};
    try t.expectEqualStrings("?", usage(4, &empty));
    try t.expectEqualStrings("?", usage(30, &empty));
    try t.expectEqualStrings("Modifiers", hostModifierNames(.macos, 255, &empty));
    var small: [1]u8 = undefined;
    _ = tap(.{
        .key_press = .{ .tap_keycode = 4, .tap_modifiers = .{ .left_gui = true } },
        .media_key = .VolumeUp,
        .custom = 7,
    }, &small);
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "",
        .name = "",
        .key_ids = &.{},
        .layers = &.{.{ .id = 77, .name = "Named stable layer", .actions = &.{} }},
    };
    var buffer: [128]u8 = undefined;
    try t.expect(containsIgnoreCase(hold(.{ .layer_id = 77 }, doc, &buffer), "Named stable layer"));
    try t.expectEqualStrings("Inherited", keycap(null, doc, &buffer));
    try t.expectEqualStrings("None", keycap(.none, doc, &buffer));
}

test "behaviour sentences spell out every key type without mode names" {
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "fixture",
        .name = "Fixture",
        .key_ids = &.{},
        .layers = &.{ .{ .id = 0, .name = "Base", .actions = &.{} }, .{ .id = 7, .name = "Numbers", .actions = &.{} } },
    };
    const t = std.testing;
    var buffer: [512]u8 = undefined;
    var plain: [512]u8 = undefined;
    const a: p.Tap = .{ .key_press = .{ .tap_keycode = 4 } };
    try t.expectEqualStrings("Tap: A.", keycap_symbols.plain(behaviour(.{ .tap_only = a }, doc, &buffer), &plain));
    try t.expectEqualStrings("Hold: L1 Numbers.", behaviour(.{ .hold_only = .{ .layer_id = 7 } }, doc, &buffer));
    const both = behaviour(.{ .tap_hold = .{
        .tap = a,
        .hold = .{ .hold_modifiers = .{ .left_shift = true } },
        .tapping_term = .{ .ms = 200 },
        .retro_tapping = true,
    } }, doc, &buffer);
    try t.expect(containsIgnoreCase(both, "after 200 ms, or the tap when released alone."));
    try t.expect(containsIgnoreCase(both, "Shift"));
    const repeat = behaviour(.{ .tap_with_autofire = .{
        .tap = a,
        .initial_delay = .{ .ms = 300 },
        .repeat_interval = .{ .ms = 50 },
    } }, doc, &buffer);
    try t.expect(containsIgnoreCase(repeat, "Hold: repeats every 50 ms after 300 ms."));
    try t.expectEqualStrings("Does nothing.", behaviour(.none, doc, &buffer));
    try t.expectEqualStrings("Falls through to the layer below.", behaviour(null, doc, &buffer));
    for ([_][]const u8{ "Tap / Hold", "Autofire", "tap_hold", "Mode" }) |mode| {
        try t.expect(!containsIgnoreCase(both, mode) and !containsIgnoreCase(repeat, mode));
    }
}
