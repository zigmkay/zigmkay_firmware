//! macOS label translation uses a local dead-key state and no-dead-keys option.
//! No C bridge changes; these are existing system framework APIs called from Zig.
const std = @import("std");
const builtin = @import("builtin");
const zkeymap = @import("zkeymap");
pub const native_available = zkeymap.native_available;
/// The retained Linux bridge builds a default XKB map; it does not discover the
/// active X11/Wayland input source. Persistent composition is macOS-only.
pub const active_source_identity_available = builtin.os.tag == .macos and native_available;
pub const persistent_translation_available = builtin.os.tag == .macos and native_available;

/// Provenance of layout-dependent translation, not merely bridge availability.
/// Linux's XKB map is compiled from process defaults (or a US fallback), not
/// obtained from the active X11/Wayland session. No active-layout injection is
/// supported by the retained C bridge.
pub const Provenance = enum { unavailable, active_macos, default_xkb, native_fallback };

pub fn platformProvenance() Provenance {
    if (!native_available) return .unavailable;
    return switch (builtin.os.tag) {
        .macos => .active_macos,
        .linux => .default_xkb,
        else => .native_fallback,
    };
}

extern "c" fn TISCopyCurrentKeyboardInputSource() ?*anyopaque;
extern "c" fn TISCopyCurrentKeyboardLayoutInputSource() ?*anyopaque;
extern "c" fn TISGetInputSourceProperty(*anyopaque, *anyopaque) ?*anyopaque;
extern "c" var kTISPropertyInputSourceID: *anyopaque;
extern "c" var kTISPropertyUnicodeKeyLayoutData: *anyopaque;
extern "c" fn CFRelease(*anyopaque) void;
extern "c" fn CFEqual(*anyopaque, *anyopaque) u8;
extern "c" fn CFStringGetCString(*anyopaque, [*]u8, isize, u32) u8;
extern "c" fn CFDataGetBytePtr(*anyopaque) ?[*]const u8;
extern "c" fn LMGetKbdType() u8;
extern "c" fn UCKeyTranslate([*]const u8, u16, u16, u32, u32, u32, *u32, u32, *u32, [*]u16) i32;

pub const Source = struct {
    native: ?*anyopaque = null,
    layout_source: ?*anyopaque = null,
    layout: ?[*]const u8 = null,
    id_buffer: [256]u8 = @splat(0),
    id_len: usize = 0,
    layout_id_buffer: [256]u8 = @splat(0),
    layout_id_len: usize = 0,
    fallback: ?zkeymap.KeyMap = null,

    pub fn provenance(_: *const Source) Provenance {
        return platformProvenance();
    }

    pub fn hasActiveLayout(self: *const Source) bool {
        return self.provenance() == .active_macos and self.layout != null;
    }

    pub fn id(self: *const Source) []const u8 {
        return self.id_buffer[0..self.id_len];
    }

    pub fn layoutId(self: *const Source) []const u8 {
        return self.layout_id_buffer[0..self.layout_id_len];
    }

    pub fn init() Source {
        var source = Source{};
        if (builtin.os.tag != .macos and native_available) {
            var km: zkeymap.KeyMap = undefined;
            zkeymap.KeyMap.init(&km);
            source.fallback = km;
        }
        _ = source.refresh();
        return source;
    }

    pub fn deinit(self: *Source) void {
        if (builtin.os.tag == .macos) {
            if (self.native) |native| CFRelease(native);
            if (self.layout_source) |native| CFRelease(native);
        }
        if (self.fallback) |*km| zkeymap.KeyMap.deinit(km);
        self.* = .{};
    }

    /// Poll actual ID; IME sources use the active keyboard layout as a fallback.
    pub fn refresh(self: *Source) bool {
        if (builtin.os.tag != .macos) {
            const changed = self.id_len == 0;
            const name = if (!native_available) "native translation unavailable" else if (builtin.os.tag == .linux) "default XKB keymap" else "native fallback";
            @memcpy(self.id_buffer[0..name.len], name);
            self.id_len = name.len;
            return changed;
        }
        const current = TISCopyCurrentKeyboardInputSource() orelse return false;
        const layout_source = TISCopyCurrentKeyboardLayoutInputSource();
        var buffer: [256]u8 = @splat(0);
        if (TISGetInputSourceProperty(current, kTISPropertyInputSourceID)) |property| {
            _ = CFStringGetCString(property, &buffer, buffer.len, 0x08000100);
        }
        const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse buffer.len;
        const same_layout = if (self.layout_source) |old| (if (layout_source) |new| CFEqual(old, new) != 0 else false) else layout_source == null;
        if (self.native != null and std.mem.eql(u8, self.id(), buffer[0..len]) and same_layout) {
            CFRelease(current);
            if (layout_source) |native| CFRelease(native);
            return false;
        }
        self.deinit();
        self.native = current;
        self.id_buffer = buffer;
        self.id_len = len;
        self.layout_source = layout_source;
        if (self.layout_source) |native| {
            if (TISGetInputSourceProperty(native, kTISPropertyInputSourceID)) |property| {
                _ = CFStringGetCString(
                    property,
                    &self.layout_id_buffer,
                    self.layout_id_buffer.len,
                    0x08000100,
                );
            }
            self.layout_id_len = std.mem.indexOfScalar(
                u8,
                &self.layout_id_buffer,
                0,
            ) orelse self.layout_id_buffer.len;
            if (TISGetInputSourceProperty(native, kTISPropertyUnicodeKeyLayoutData)) |data|
                self.layout = CFDataGetBytePtr(data);
        }
        return true;
    }

    pub fn keyToText(self: *Source, input: zkeymap.KeyCodeFire) zkeymap.TextResult {
        if (!zkeymap.isLayoutDependent(input.tap_keycode)) {
            var result = zkeymap.TextResult{};
            result.data[0..2].* = @bitCast(@as(u16, input.tap_keycode));
            return result;
        }
        if (builtin.os.tag != .macos) {
            if (self.fallback) |*km| {
                // Isolate each label from the existing backend's dead-key state.
                km.refresh();
                return km.keyToText(input);
            }
            return .{};
        }
        const layout = self.layout orelse return .{};
        const vk = zkeymap.hid_to_platform.hidToMacVk(input.tap_keycode) orelse return .{};
        const mods = input.tap_modifiers;
        var carbon: u32 = 0;
        if (mods.left_shift or mods.right_shift) carbon |= 2;
        if (mods.left_alt or mods.right_alt) carbon |= 8;
        if (mods.left_ctrl or mods.right_ctrl) carbon |= 16;
        if (mods.left_gui or mods.right_gui) carbon |= 1;
        var state: u32 = 0;
        var count: u32 = 0;
        var chars: [8]u16 = undefined;
        if (UCKeyTranslate(layout, vk, 0, carbon, LMGetKbdType(), 1, &state, chars.len, &count, &chars) != 0 or
            count == 0 or
            count > chars.len) return .{};
        var result = zkeymap.TextResult{};
        const n = std.unicode.utf16LeToUtf8(&result.data, chars[0..count]) catch return .{};
        result.len = @intCast(n);
        return result;
    }
};

/// Persistent composition for processor output, separate from stateless labels.
/// UTF-16 output may contain several scalars; no system events are generated.
pub const Session = struct {
    source: Source,
    dead_state: u32 = 0,

    pub fn init() Session {
        return .{ .source = Source.init() };
    }

    pub fn deinit(self: *Session) void {
        self.source.deinit();
    }

    pub fn reset(self: *Session) void {
        self.dead_state = 0;
    }

    pub fn refresh(self: *Session) bool {
        if (self.source.refresh()) {
            self.reset();
            return true;
        }
        return false;
    }

    pub fn eurkey(self: *const Session) bool {
        var lower: [256]u8 = undefined;
        const id = self.source.id();
        for (id, lower[0..id.len]) |c, *out| out.* = std.ascii.toLower(c);
        return std.mem.indexOf(u8, lower[0..id.len], "eurkey") != null;
    }

    pub fn translate(self: *Session, key: zkeymap.KeyCodeFire, output: *[128]u8) ![]const u8 {
        if (builtin.os.tag != .macos) return error.NativeTranslationUnavailable;
        if (!self.eurkey()) return error.SelectEurKeyInputSource;
        const native_layout = self.source.layout orelse return error.NativeTranslationUnavailable;
        const vk = zkeymap.hid_to_platform.hidToMacVk(key.tap_keycode) orelse return error.UnsupportedUsage;
        const mods = key.tap_modifiers;
        var carbon: u32 = 0;
        if (mods.left_shift or mods.right_shift) carbon |= 2;
        if (mods.left_alt or mods.right_alt) carbon |= 8;
        if (mods.left_ctrl or mods.right_ctrl) carbon |= 16;
        if (mods.left_gui or mods.right_gui) carbon |= 1;
        var count: u32 = 0;
        var chars: [32]u16 = undefined;
        if (UCKeyTranslate(native_layout, vk, 0, carbon, LMGetKbdType(), 0, &self.dead_state, chars.len, &count, &chars) != 0 or
            count > chars.len) return error.NativeTranslationFailed;
        const n = try std.unicode.utf16LeToUtf8(output, chars[0..count]);
        return output[0..n];
    }
};
