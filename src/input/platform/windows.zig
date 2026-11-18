const root = @import("../root.zig");
const hid = @import("../hid_to_platform.zig");

/// Opaque handle allocated by the C implementation in platform/windows.c.
/// Wraps the active HKL (keyboard layout handle) and dead-key state.
pub const WindowsKeyMap = opaque {
    extern fn windowsKeyMapInit() ?*WindowsKeyMap;

    pub fn init() ?*WindowsKeyMap {
        return windowsKeyMapInit();
    }

    extern fn windowsKeyMapDeinit(*WindowsKeyMap) void;

    pub fn deinit(km: *WindowsKeyMap) void {
        windowsKeyMapDeinit(km);
    }

    extern fn windowsKeyMapRefresh(*WindowsKeyMap) void;

    pub fn refresh(km: *WindowsKeyMap) void {
        windowsKeyMapRefresh(km);
    }

    /// mods bit layout identical to MacOsKeyMap (see macos.zig).
    extern fn windowsKeyMapTranslate(
        *WindowsKeyMap,
        vk: u8,
        mods: u8,
        is_dead: bool,
        buf: [*]u8,
        buf_len: usize,
    ) usize;

    pub fn keyToText(km: *WindowsKeyMap, input: root.KeyCodeFire) root.TextResult {
        const vk = hid.hidToWinVk(input.tap_keycode) orelse return .{};
        var result = root.TextResult{};
        result.len = @intCast(windowsKeyMapTranslate(
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
