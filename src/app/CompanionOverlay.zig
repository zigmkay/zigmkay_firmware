//! The companion window: a passive layout reference beside other
//! applications, optionally as a borderless always-on-top overlay.
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const boards = @import("catalog-project");
const companion_ui = @import("companion-ui");
const companion_window = @import("companion-window");
const editor_fonts = @import("editor-fonts");
const App = @import("App.zig");
const Tutor = @import("Tutor.zig");
const window_icon = @import("window_icon.zig");

/// SDL window id of the native companion window.
window: ?u32 = null,
view: companion_ui.View = .{},

/// The companion stays hidden while a run hides all assistance.
pub fn suppressed(app: *const App) bool {
    return !app.life.companion_visible or (app.practicing and app.tutor.controller.config.assistance == .hidden);
}

pub fn hideIfSuppressed(app: *App) void {
    if (!suppressed(app)) return;
    const id = app.companion.window orelse return;
    if (Backend.c.SDL_GetWindowFromID(id)) |child| _ = Backend.c.SDL_HideWindow(child);
}

/// Shows the companion window and draws it when it is visible.
pub fn update(app: *App, board: *const boards.OwnedBoard, practice: Tutor.Frame) !void {
    if (app.live_enabled and !app.live.verified()) app.life.companion_visible = false;
    hideIfSuppressed(app);
    if (suppressed(app)) return;
    // Child creation inherits this flag from the backend's saved options.
    // The editor's existing native window remains opaque.
    const parent_transparent = app.native.init_opts_save.?.transparent;
    app.native.init_opts_save.?.transparent = true;
    const child = dvui.osWindow(@src(), .{
        .title = "Zigmkay Companion",
        .size = .{ .w = 880, .h = 300 },
        .min_size = .{ .w = 400, .h = 180 },
        .hidden = true,
    }, .{ .open_flag = &app.life.companion_visible });
    app.native.init_opts_save.?.transparent = parent_transparent;
    defer child.deinit();
    const self = &app.companion;
    const previous_window = self.window;
    self.window = switch (child.inner) {
        .os => |active| Backend.c.SDL_GetWindowID(active.backend.window),
        .floating => null,
    };
    if (app.frame_limit == null and self.view.applied_window != self.window) try editor_fonts.install(app.gpa, app.io);
    try draw(app, board, practice);
    if (app.mode.is(.companion) and (dvui.tagGet("companion.open_editor") != null or dvui.tagGet("companion.overlay") != null))
        return error.InteractiveCompanionControl;
    switch (child.inner) {
        .os => |active| {
            if (previous_window != self.window) window_icon.apply(active.backend.window);
            applyMode(app, active.backend.window);
        },
        .floating => {
            self.view.unavailable = self.view.overlay;
            if (app.frame_limit != null) self.view.overlay = false else app.life.companion_visible = false;
        },
    }
}

/// Shows the live keyboard when monitoring, otherwise the editor project with
/// the draft runner's state.
fn draw(app: *App, board: *const boards.OwnedBoard, practice: Tutor.Frame) !void {
    const arena = dvui.currentWindow().arena();
    const live = app.live_enabled;
    const draft = &app.draft_runtime;
    const model = if (live) &app.live.model else &app.model;
    const held = try arena.alloc(bool, app.model.document().key_ids.len);
    @memset(held, false);
    if (draft.owner) |active| if (active.pressed.len == held.len) @memcpy(held, active.pressed);
    const labels = if (live) &app.live.captions.labels else &app.captions.labels;
    const layer = if (live) app.live.frame.layer else if (draft.owner != null) draft.highest_layer else app.model.layer;
    const Modifiers = @TypeOf(app.live.frame.modifiers);
    const modifiers: Modifiers = if (live) app.live.frame.modifiers else if (draft.owner != null) @bitCast(draft.modifiers) else .{};
    const targets = try arena.alloc(bool, labels.key_count);
    const holds = try arena.alloc(bool, labels.key_count);
    @memset(targets, false);
    @memset(holds, false);
    const tutor = &app.tutor.controller;
    if (app.practicing and tutor.config.assistance == .guided and tutor.active and tutor.session.state != .complete and
        (!live or practice.live) and labels == practice.labels)
    {
        const session = &tutor.session;
        const next = desktop.practice_view.focus(session);
        const active_layers = if (live)
            app.live.frame.active
        else if (draft.owner != null) draft.active_layers else desktop.practice.layerMask(layer);
        const hint = if (next < session.reference_len)
            try desktop.practice.hint(labels.practiceLabels(), layer, modifiers.toByte(), session.reference[next], active_layers)
        else
            null;
        try desktop.practice.guidance(labels.practiceLabels(), practice.metadata, layer, modifiers.toByte(), hint, .{
            .tap = targets,
            .hold = holds,
        });
    }
    companion_ui.draw(model, .{
        .snapshot = try model.id(),
        .geometry = if (live) app.live.board.entry.geometry else board.entry.geometry,
        .labels = labels,
        .board_name = if (live) app.live.board.entry.selector else board.entry.selector,
        .layer = layer,
        .modifiers = modifiers,
        .pressed = if (live) app.live.frame.pressed else held,
        .live = live,
        .active_layers = if (live) app.live.frame.active else null,
        .practicing = app.practicing,
        .assistance = tutor.config.assistance,
        .targets = targets,
        .holds = holds,
    }, app.view.toolbar.light) catch |err| app.view.report(err);
}

fn applyMode(app: *App, window: *Backend.c.SDL_Window) void {
    const self = &app.companion;
    const id = Backend.c.SDL_GetWindowID(window);
    if (self.view.applied_window != id) {
        const requested = self.view.overlay;
        companion_window.mode(window, requested) catch |err| {
            self.view.unavailable = requested;
            if (app.frame_limit != null) {
                self.view.overlay = false;
                companion_window.mode(window, false) catch {};
            } else {
                app.view.report(err);
                app.life.companion_visible = false;
                _ = Backend.c.SDL_HideWindow(window);
            }
        };
        self.view.applied_window = id;
    }
    // Native child windows can survive skipped draw frames. Sync visibility on
    // every visible frame, not only on the initial mode setup.
    if (app.mode.is(.companion) or (app.frame_limit == null and !self.view.unavailable)) _ = Backend.c.SDL_ShowWindow(window);
}
