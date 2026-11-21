//! SDL event conversion only; no window creation, device access or text queries.
const sdl = @import("dvui_backend").c;
const desktop = @import("desktop-core");

pub fn route(
    router: *desktop.draft_input.Router,
    tutor: *const desktop.practice_controller.Controller,
    event: *const sdl.SDL_Event,
) desktop.draft_input.Route {
    return router.route(tutor, convert(event) orelse return .pass);
}

pub fn convert(event: *const sdl.SDL_Event) ?desktop.draft_input.Event {
    return switch (event.type) {
        sdl.SDL_EVENT_WINDOW_FOCUS_LOST => .{ .focus_lost = event.window.windowID },
        sdl.SDL_EVENT_WINDOW_FOCUS_GAINED => .{ .focus_gained = event.window.windowID },
        sdl.SDL_EVENT_TEXT_INPUT => .{ .text = event.text.windowID },
        sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => .{ .key = .{
            .window = event.key.windowID,
            .scancode = @intCast(event.key.scancode),
            .down = event.type == sdl.SDL_EVENT_KEY_DOWN,
            .repeat = event.key.repeat,
        } },
        else => null,
    };
}
