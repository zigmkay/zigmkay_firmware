//! Passive transparent macOS overlay. Production callers hide unsupported modes.
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("dvui_backend").c;
extern "c" fn sel_registerName([*:0]const u8) *anyopaque;
extern "c" fn objc_getClass([*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend() void;

fn selector(name: [*:0]const u8) *anyopaque {
    return sel_registerName(name);
}

fn cocoaOverlay(window: *sdl.SDL_Window) !void {
    if (builtin.os.tag != .macos) return error.CompanionClickThroughUnavailable;
    const props = sdl.SDL_GetWindowProperties(window);
    const ns_window = sdl.SDL_GetPointerProperty(
        props,
        sdl.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
        null,
    ) orelse return error.CompanionClickThroughUnavailable;
    const set_bool: *const fn (*anyopaque, *anyopaque, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    const get_bool: *const fn (*anyopaque, *anyopaque) callconv(.c) bool = @ptrCast(&objc_msgSend);
    const get_object: *const fn (*anyopaque, *anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc_msgSend);
    const set_object: *const fn (
        *anyopaque,
        *anyopaque,
        *anyopaque,
    ) callconv(.c) void = @ptrCast(&objc_msgSend);
    const set_integer: *const fn (*anyopaque, *anyopaque, isize) callconv(.c) void = @ptrCast(&objc_msgSend);
    const get_integer: *const fn (*anyopaque, *anyopaque) callconv(.c) isize = @ptrCast(&objc_msgSend);
    const color_class = objc_getClass("NSColor") orelse return error.CompanionTransparencyUnavailable;
    const clear = get_object(
        color_class,
        selector("clearColor"),
    ) orelse return error.CompanionTransparencyUnavailable;
    set_bool(ns_window, selector("setOpaque:"), false);
    set_object(ns_window, selector("setBackgroundColor:"), clear);
    set_bool(ns_window, selector("setHasShadow:"), false);
    set_bool(ns_window, selector("setIgnoresMouseEvents:"), true);
    set_integer(ns_window, selector("setLevel:"), 25);
    // All Spaces, stationary, excluded from window cycling, fullscreen auxiliary.
    set_integer(ns_window, selector("setCollectionBehavior:"), 1 | 16 | 64 | 256);
    if (get_bool(ns_window, selector("isOpaque")) or
        get_bool(ns_window, selector("hasShadow")) or
        !get_bool(ns_window, selector("ignoresMouseEvents"))) return error.CompanionClickThroughUnavailable;
    if (get_integer(ns_window, selector("level")) < 25 or
        get_integer(
            ns_window,
            selector("collectionBehavior"),
        ) & (1 | 256) != (1 | 256)) return error.CompanionWindowModeUnavailable;
}

pub fn overlayRect(usable: sdl.SDL_Rect, width: c_int, height: c_int) sdl.SDL_Rect {
    const w = @max(1, @min(width, usable.w));
    const h = @max(1, @min(height, usable.h));
    return .{
        .x = usable.x + @divTrunc(usable.w - w, 2),
        .y = usable.y + @max(0, usable.h - h - 20),
        .w = w,
        .h = h,
    };
}

pub fn mode(window: *sdl.SDL_Window, overlay: bool) !void {
    // Restore every attribute even if an earlier request is unsupported.
    const bordered = sdl.SDL_SetWindowBordered(window, !overlay);
    const top = sdl.SDL_SetWindowAlwaysOnTop(window, overlay);
    const focus = sdl.SDL_SetWindowFocusable(window, !overlay);
    if (!bordered or !top or !focus) return error.CompanionWindowModeUnavailable;
    // SDL can return success without changing flags when a driver lacks the
    // requested operation. Confirm the actual mode before reporting support.
    const mask = sdl.SDL_WINDOW_BORDERLESS | sdl.SDL_WINDOW_ALWAYS_ON_TOP | sdl.SDL_WINDOW_NOT_FOCUSABLE;
    if ((sdl.SDL_GetWindowFlags(window) & mask) != (if (overlay) mask else 0))
        return error.CompanionWindowModeUnavailable;
    if (!overlay) return;
    if (sdl.SDL_GetWindowFlags(window) & sdl.SDL_WINDOW_TRANSPARENT == 0) return error.CompanionTransparencyUnavailable;
    try cocoaOverlay(window);
    var usable: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetDisplayUsableBounds(sdl.SDL_GetDisplayForWindow(window), &usable))
        return error.CompanionDisplayBoundsUnavailable;
    if (usable.w <= 0 or usable.h <= 0) return error.CompanionDisplayBoundsUnavailable;
    var width: c_int = 0;
    var height: c_int = 0;
    if (!sdl.SDL_GetWindowSize(window, &width, &height)) return error.CompanionWindowGeometryUnavailable;
    const target = overlayRect(usable, width, height);
    if (!sdl.SDL_SetWindowSize(window, target.w, target.h) or
        !sdl.SDL_SetWindowPosition(window, target.x, target.y)) return error.CompanionWindowPlacementUnavailable;
}

test "overlay placement fits negative-origin and small displays" {
    const t = std.testing;
    try t.expectEqualDeep(
        sdl.SDL_Rect{ .x = -1020, .y = 550, .w = 880, .h = 350 },
        overlayRect(.{ .x = -1280, .y = 20, .w = 1400, .h = 900 }, 880, 350),
    );
    try t.expectEqualDeep(
        sdl.SDL_Rect{ .x = 0, .y = 0, .w = 500, .h = 250 },
        overlayRect(.{ .x = 0, .y = 0, .w = 500, .h = 250 }, 880, 350),
    );
}
