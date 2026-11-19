//! Keep editor windows inside the display's usable area before revealing them.
const std = @import("std");
const sdl = @import("sdl3-c");
pub const Borders = struct { top: c_int = 0, left: c_int = 0, bottom: c_int = 0, right: c_int = 0 };

pub fn fit(client: sdl.SDL_Rect, usable: sdl.SDL_Rect, borders: Borders, center: bool) sdl.SDL_Rect {
    const width = @max(1, @min(client.w, usable.w - borders.left - borders.right));
    const height = @max(1, @min(client.h, usable.h - borders.top - borders.bottom));
    const min_x = usable.x + borders.left;
    const min_y = usable.y + borders.top;
    const max_x = @max(min_x, usable.x + usable.w - borders.right - width);
    const max_y = @max(min_y, usable.y + usable.h - borders.bottom - height);
    return .{
        .x = if (center) min_x + @divTrunc(max_x - min_x, 2) else std.math.clamp(client.x, min_x, max_x),
        .y = if (center) min_y + @divTrunc(max_y - min_y, 2) else std.math.clamp(client.y, min_y, max_y),
        .w = width,
        .h = height,
    };
}

pub fn place(window: *sdl.SDL_Window, center: bool) !void {
    if (sdl.SDL_GetWindowFlags(window) & (sdl.SDL_WINDOW_MAXIMIZED | sdl.SDL_WINDOW_FULLSCREEN) != 0) return;
    var display = if (center) @as(sdl.SDL_DisplayID, 0) else sdl.SDL_GetDisplayForWindow(window);
    if (display == 0) {
        var x: f32 = 0;
        var y: f32 = 0;
        _ = sdl.SDL_GetGlobalMouseState(&x, &y);
        const point = sdl.SDL_Point{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
        display = sdl.SDL_GetDisplayForPoint(&point);
        if (display == 0) display = sdl.SDL_GetPrimaryDisplay();
    }
    var usable: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetDisplayUsableBounds(display, &usable)) return error.EditorDisplayBoundsUnavailable;
    var client: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetWindowPosition(window, &client.x, &client.y) or
        !sdl.SDL_GetWindowSize(window, &client.w, &client.h)) return error.EditorWindowGeometryUnavailable;
    var borders: Borders = .{};
    _ = sdl.SDL_GetWindowBordersSize(window, &borders.top, &borders.left, &borders.bottom, &borders.right);
    const target = fit(client, usable, borders, center);
    if (target.w != client.w or target.h != client.h) {
        var min_w: c_int = 0;
        var min_h: c_int = 0;
        if (!sdl.SDL_GetWindowMinimumSize(window, &min_w, &min_h)) return error.EditorWindowGeometryUnavailable;
        if (!sdl.SDL_SetWindowMinimumSize(window, @min(min_w, target.w), @min(min_h, target.h)) or
            !sdl.SDL_SetWindowSize(window, target.w, target.h)) return error.EditorWindowPlacementFailed;
    }
    if (!sdl.SDL_SetWindowPosition(window, target.x, target.y)) return error.EditorWindowPlacementFailed;
}

pub fn reveal(window: *sdl.SDL_Window) !void {
    if (sdl.SDL_GetWindowFlags(window) & sdl.SDL_WINDOW_MINIMIZED != 0) {
        if (!sdl.SDL_RestoreWindow(window)) return error.EditorWindowActivationFailed;
    }
    try place(window, false);
    // SDL's Cocoa implementation activates the application as well as the window.
    if (!sdl.SDL_SetHint(sdl.SDL_HINT_WINDOW_ACTIVATE_WHEN_RAISED, "1") or
        !sdl.SDL_ShowWindow(window) or
        !sdl.SDL_RaiseWindow(window)) return error.EditorWindowActivationFailed;
}

test "editor frame fits usable bounds including title bar and negative display origin" {
    const area: sdl.SDL_Rect = .{ .x = -1440, .y = 25, .w = 1440, .h = 835 };
    const border: Borders = .{ .top = 28 };
    const centered = fit(.{ .x = 900, .y = 200, .w = 1152, .h = 768 }, area, border, true);
    try std.testing.expectEqual(@as(c_int, -1296), centered.x);
    try std.testing.expectEqual(@as(c_int, 72), centered.y);
    const clamped = fit(.{ .x = 900, .y = 2000, .w = 1152, .h = 768 }, area, border, false);
    try std.testing.expectEqual(@as(c_int, -1152), clamped.x);
    try std.testing.expectEqual(@as(c_int, 92), clamped.y);
    const small = fit(
        .{ .x = 900, .y = -500, .w = 1152, .h = 768 },
        .{ .x = 0, .y = 25, .w = 1000, .h = 700 },
        border,
        true,
    );
    try std.testing.expectEqualDeep(sdl.SDL_Rect{ .x = 0, .y = 53, .w = 1000, .h = 672 }, small);
    try std.testing.expectEqualDeep(centered, fit(centered, area, border, false));
}
