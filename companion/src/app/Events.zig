//! SDL event hooks of the editor window, called by `native-events.pump`.
//!
//! Window close, quit and focus loss are latched for the frame loop. Draft
//! practice input is routed to the native runner before DVUI sees it, and the
//! arrival time of every forwarded key or text event is kept for the tutor.
const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const editor = @import("editor-frame-ui");
const native_events = @import("native-events");
const draft_input = @import("native-draft-input");

const Events = @This();

io: std.Io,
/// SDL window id of the editor window.
root: u32,
close: bool = false,
quit: bool = false,
lost_focus: bool = false,
draft: ?*desktop.runner_runtime.Runtime = null,
practice: ?*desktop.practice_controller.Controller = null,
model: ?*desktop.model.Model = null,
view: ?*editor.View = null,
now_us: u64 = 0,
times: [512]desktop.practice.EventTime = undefined,
time_count: usize = 0,

/// Converts the SDL event timestamp to the awake clock in microseconds.
fn timestamp(self: *Events, event: Backend.c.SDL_Event) u64 {
    const now: u64 = @intCast(@max(0, std.Io.Clock.awake.now(self.io).toNanoseconds()) / 1000);
    const age = Backend.c.SDL_GetTicksNS() -| event.common.timestamp;
    return now -| (age / 1000);
}

pub fn forwarded(self: *Events, event: Backend.c.SDL_Event, added: []const dvui.Event) void {
    if (native_events.windowId(event) != self.root or event.common.timestamp == 0) return;
    const at = self.timestamp(event);
    for (added) |item| {
        if (item.evt != .text and item.evt != .key) continue;
        if (self.time_count == self.times.len) break;
        self.times[self.time_count] = .{ .number = item.num, .now_us = at };
        self.time_count += 1;
    }
}

/// Returns true when the event is consumed and must not reach DVUI.
pub fn raw(self: *Events, event: Backend.c.SDL_Event) !bool {
    if (event.type == Backend.c.SDL_EVENT_QUIT) {
        self.quit = true;
        return true;
    }
    if (event.type == Backend.c.SDL_EVENT_WINDOW_CLOSE_REQUESTED and event.window.windowID == self.root) {
        self.close = true;
        return true;
    }
    if (event.type == Backend.c.SDL_EVENT_WINDOW_FOCUS_LOST and event.window.windowID == self.root) self.lost_focus = true;
    return self.routeDraft(event);
}

fn routeDraft(self: *Events, event: Backend.c.SDL_Event) bool {
    const runtime = self.draft orelse return false;
    const practice = self.practice orelse return false;
    const model = self.model orelse return false;
    const converted = draft_input.convert(&event) orelse return false;
    const at = if (event.common.timestamp != 0) self.timestamp(event) else self.now_us;
    return runtime.route(practice, model, converted, at) catch |err| {
        runtime.fail(practice, err, self.now_us);
        if (self.view) |view| view.report(err);
        return false;
    };
}
