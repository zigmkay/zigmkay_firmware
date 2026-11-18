const root = @import("../root.zig");
const hid = @import("../hid_to_platform.zig");

/// Opaque handle allocated by the C implementation in platform/macos.c.
/// Wraps TISInputSourceRef + UCKeyboardLayout* + dead-key state.
pub const MacOsKeyMap = opaque {
    extern fn macOsKeyMapInit() ?*MacOsKeyMap;

    pub fn init() ?*MacOsKeyMap {
        return macOsKeyMapInit();
    }

    extern fn macOsKeyMapDeinit(*MacOsKeyMap) void;

    pub fn deinit(km: *MacOsKeyMap) void {
        macOsKeyMapDeinit(km);
    }

    /// Re-fetch the current keyboard input source.
    /// Call this when the user switches layouts at the OS level.
    extern fn macOsKeyMapRefresh(*MacOsKeyMap) void;

    pub fn refresh(km: *MacOsKeyMap) void {
        macOsKeyMapRefresh(km);
    }

    /// Translates a HID scan code + modifiers to UTF-8.
    /// Returns the number of bytes written into buf (0–4).
    /// mods is @bitCast(Modifiers): bit0=shift bit1=ctrl bit2=alt bit3=gui
    ///                               bit4=caps_lock bit5=num_lock
    extern fn macOsKeyMapTranslate(
        *MacOsKeyMap,
        vk: u16,
        mods: u8,
        is_dead: bool,
        buf: [*]u8,
        buf_len: usize,
    ) usize;

    pub fn keyToText(km: *MacOsKeyMap, input: root.KeyCodeFire) root.TextResult {
        const vk = hid.hidToMacVk(input.tap_keycode) orelse return .{};
        var result = root.TextResult{};
        result.len = @intCast(macOsKeyMapTranslate(
            km,
            vk,
            hid.toPlatformMods(input.tap_modifiers),
            input.dead,
            &result.data,
            result.data.len,
        ));
        return result;
    }
};
