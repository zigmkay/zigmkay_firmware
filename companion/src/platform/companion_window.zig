//! Passive transparent overlay: borderless, always on top, never focused and
//! click-through. macOS uses Cocoa, Windows extended window styles and Linux
//! an empty X11 input shape (X11 or XWayland; Wayland has no such window).
//! Callers fall back to a normal window where a mode is unsupported.
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

/// Lets pointer input pass through to the windows below, or restores it.
fn clickThrough(window: *sdl.SDL_Window, enabled: bool) !void {
    switch (builtin.os.tag) {
        // Unchanged macOS behaviour: Cocoa state is applied for the overlay only.
        .macos => if (enabled) try cocoaOverlay(window),
        .windows => try win32.clickThrough(window, enabled),
        .linux => try x11.clickThrough(window, enabled),
        else => if (enabled) return error.CompanionClickThroughUnavailable,
    }
}

const win32 = struct {
    const gwl_exstyle: c_int = -20;
    const ws_ex_transparent: isize = 0x00000020;
    const ws_ex_toolwindow: isize = 0x00000080;
    const ws_ex_layered: isize = 0x00080000;
    const ws_ex_noactivate: isize = 0x08000000;
    /// Layered plus transparent makes Windows route pointer input past the
    /// window; tool and no-activate keep it out of Alt+Tab and the taskbar.
    const overlay_styles = ws_ex_transparent | ws_ex_toolwindow | ws_ex_layered | ws_ex_noactivate;
    const lwa_alpha: u32 = 2;

    extern "user32" fn GetWindowLongPtrW(hwnd: *anyopaque, index: c_int) callconv(.winapi) isize;
    extern "user32" fn SetWindowLongPtrW(hwnd: *anyopaque, index: c_int, value: isize) callconv(.winapi) isize;
    extern "user32" fn SetLayeredWindowAttributes(hwnd: *anyopaque, key: u32, alpha: u8, flags: u32) callconv(.winapi) c_int;

    fn clickThrough(window: *sdl.SDL_Window, enabled: bool) !void {
        const hwnd = sdl.SDL_GetPointerProperty(
            sdl.SDL_GetWindowProperties(window),
            sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER,
            null,
        ) orelse return error.CompanionClickThroughUnavailable;
        const before = GetWindowLongPtrW(hwnd, gwl_exstyle);
        const wanted = if (enabled) before | overlay_styles else before & ~overlay_styles;
        if (wanted != before) _ = SetWindowLongPtrW(hwnd, gwl_exstyle, wanted);
        // A layered window stays invisible until its attributes are set; full
        // alpha keeps the renderer's per-pixel transparency as SDL draws it.
        if (enabled and SetLayeredWindowAttributes(hwnd, 0, 255, lwa_alpha) == 0)
            return error.CompanionClickThroughUnavailable;
        const applied = GetWindowLongPtrW(hwnd, gwl_exstyle) & overlay_styles;
        if (applied != (if (enabled) overlay_styles else 0)) return error.CompanionClickThroughUnavailable;
    }
};

const x11 = struct {
    const shape_input: c_int = 2;
    const shape_set: c_int = 0;
    const unsorted: c_int = 0;
    const Combine = *const fn (?*anyopaque, c_ulong, c_int, c_int, c_int, ?*anyopaque, c_int, c_int, c_int) callconv(.c) void;
    const CombineMask = *const fn (?*anyopaque, c_ulong, c_int, c_int, c_int, c_ulong, c_int) callconv(.c) void;
    const Flush = *const fn (?*anyopaque) callconv(.c) c_int;

    /// libXext and libX11 as SDL loads them: from the bundle or the system.
    var library: ?struct { ext: std.DynLib, x: std.DynLib } = null;

    fn load() !@TypeOf(library.?) {
        if (library) |loaded| return loaded;
        var ext = std.DynLib.open("libXext.so.6") catch return error.CompanionClickThroughUnavailable;
        errdefer ext.close();
        const x = std.DynLib.open("libX11.so.6") catch return error.CompanionClickThroughUnavailable;
        library = .{ .ext = ext, .x = x };
        return library.?;
    }

    /// An empty input shape sends every pointer event to the window below;
    /// resetting the shape to None restores normal input.
    fn clickThrough(window: *sdl.SDL_Window, enabled: bool) !void {
        const props = sdl.SDL_GetWindowProperties(window);
        const display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null) orelse
            return if (enabled) error.CompanionClickThroughUnavailable else {};
        const xwindow: c_ulong = @intCast(sdl.SDL_GetNumberProperty(props, sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0));
        if (xwindow == 0) return error.CompanionClickThroughUnavailable;
        var loaded = try load();
        const flush = loaded.x.lookup(Flush, "XFlush") orelse return error.CompanionClickThroughUnavailable;
        if (enabled) {
            const combine = loaded.ext.lookup(Combine, "XShapeCombineRectangles") orelse return error.CompanionClickThroughUnavailable;
            combine(display, xwindow, shape_input, 0, 0, null, 0, shape_set, unsorted);
        } else {
            const combine = loaded.ext.lookup(CombineMask, "XShapeCombineMask") orelse return error.CompanionClickThroughUnavailable;
            combine(display, xwindow, shape_input, 0, 0, 0, shape_set);
        }
        _ = flush(display);
    }
};

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
    const pass = clickThrough(window, overlay);
    if (!bordered or !top or !focus) return error.CompanionWindowModeUnavailable;
    // X11 applies window manager state asynchronously.
    _ = sdl.SDL_SyncWindow(window);
    // SDL can return success without changing flags when a driver lacks the
    // requested operation. Confirm the actual mode before reporting support.
    const mask = sdl.SDL_WINDOW_BORDERLESS | sdl.SDL_WINDOW_ALWAYS_ON_TOP | sdl.SDL_WINDOW_NOT_FOCUSABLE;
    if ((sdl.SDL_GetWindowFlags(window) & mask) != (if (overlay) mask else 0))
        return error.CompanionWindowModeUnavailable;
    try pass;
    if (!overlay) return;
    if (sdl.SDL_GetWindowFlags(window) & sdl.SDL_WINDOW_TRANSPARENT == 0) return error.CompanionTransparencyUnavailable;
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
