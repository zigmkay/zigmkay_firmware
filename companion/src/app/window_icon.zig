//! Window icons for SDL backends that accept them. AppKit uses the app bundle.
const builtin = @import("builtin");
const sdl = @import("dvui_backend").c;
const icons = @import("application-icons");

fn load(png: []const u8) ?*sdl.SDL_Surface {
    const stream = sdl.SDL_IOFromConstMem(png.ptr, png.len) orelse return null;
    return sdl.SDL_LoadPNG_IO(stream, true);
}

pub fn apply(window: *sdl.SDL_Window) void {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return;
    const image = load(icons.window_png) orelse return;
    defer sdl.SDL_DestroySurface(image);
    if (load(icons.window_2x_png)) |high_dpi| {
        _ = sdl.SDL_AddSurfaceAlternateImage(image, high_dpi);
        sdl.SDL_DestroySurface(high_dpi);
    }
    _ = sdl.SDL_SetWindowIcon(window, image);
}
