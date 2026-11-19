const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const sdl = Backend.c;

/// Route app-owned raw events, preserving child-window delivery. The hook can
/// consume mapped scancodes and observes focus loss (DVUI does not expose it).
pub fn pump(backend: *Backend, window: *dvui.Window, context: anytype) !void {
    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event)) {
        if (try context.raw(event)) continue;
        const id = windowId(event);
        const before = window.events.items.len;
        _ = try dispatch(backend, window, event, id);
        if (@hasDecl(@TypeOf(context.*), "forwarded")) {
            context.forwarded(
                event,
                window.events.items[before..],
            );
        }
    }
}

pub fn windowId(event: sdl.SDL_Event) u32 {
    return switch (event.type) {
        sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => event.key.windowID,
        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => event.button.windowID,
        sdl.SDL_EVENT_MOUSE_MOTION => event.motion.windowID,
        sdl.SDL_EVENT_MOUSE_WHEEL => event.wheel.windowID,
        sdl.SDL_EVENT_TEXT_INPUT => event.text.windowID,
        sdl.SDL_EVENT_TEXT_EDITING => event.edit.windowID,
        sdl.SDL_EVENT_TEXT_EDITING_CANDIDATES => event.edit_candidates.windowID,
        sdl.SDL_EVENT_DROP_FILE, sdl.SDL_EVENT_DROP_TEXT, sdl.SDL_EVENT_DROP_BEGIN, sdl.SDL_EVENT_DROP_COMPLETE, sdl.SDL_EVENT_DROP_POSITION => event.drop.windowID,
        else => if (event.type >= sdl.SDL_EVENT_WINDOW_FIRST and event.type <= sdl.SDL_EVENT_WINDOW_LAST) event.window.windowID else 0,
    };
}

test "child window IME and drop events retain their destination" {
    const t = @import("std").testing;
    var event: sdl.SDL_Event = @import("std").mem.zeroes(sdl.SDL_Event);
    event.edit.type = sdl.SDL_EVENT_TEXT_EDITING;
    event.edit.windowID = 17;
    try t.expectEqual(@as(u32, 17), windowId(event));
    event.edit_candidates.type = sdl.SDL_EVENT_TEXT_EDITING_CANDIDATES;
    event.edit_candidates.windowID = 18;
    try t.expectEqual(@as(u32, 18), windowId(event));
    event.drop.type = sdl.SDL_EVENT_DROP_FILE;
    event.drop.windowID = 19;
    try t.expectEqual(@as(u32, 19), windowId(event));
    event.type = sdl.SDL_EVENT_QUIT;
    try t.expectEqual(@as(u32, 0), windowId(event));
}

fn dispatch(backend: *Backend, window: *dvui.Window, event: sdl.SDL_Event, id: u32) !bool {
    if (id == 0 or sdl.SDL_GetWindowID(backend.window) == id) {
        _ = try backend.addEvent(window, event);
        return true;
    }
    var iterator = window.child_os_wins.iterator();
    while (iterator.next_peek()) |child| {
        if (try dispatch(child.value.backend, child.value.dvui_win, event, id)) return true;
    }
    return false;
}
