//! The tray menu and the resident lifecycle: the application keeps running
//! with hidden windows while the tray is installed.
const std = @import("std");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const project = @import("project");
const App = @import("App.zig");
const LiveKeyboard = @import("LiveKeyboard.zig");

pub fn handle(app: *App) void {
    const action = app.tray.poll() orelse return;
    switch (action) {
        .open_editor => {
            app.life.action(action);
            _ = Backend.c.SDL_ShowWindow(app.native.window);
            _ = Backend.c.SDL_RaiseWindow(app.native.window);
        },
        .toggle_companion => {
            app.life.action(action);
            if (app.live.visibility.mode != .hold and app.live.verified()) app.live.visibility.latched = app.life.companion_visible;
        },
        .quit => app.events.quit = true,
        .bind_saved_project => bindSavedProject(app),
        .zoom_out, .zoom_in, .zoom_reset => app.life.action(action),
    }
}

/// Binds the live session to the project saved at the editor's project path.
/// Unsaved editor changes are never sent to the keyboard's labels.
fn bindSavedProject(app: *App) void {
    if (!app.live_enabled) return;
    if (app.jobs.busy() or app.flash.pending != null or app.flash.session != null)
        return app.view.report(error.ProjectJobInProgress);
    const path = std.mem.sliceTo(&app.view.paths.project, 0);
    var replacement = LiveKeyboard.loadSaved(app.gpa, app.io, path) catch |err| return app.view.report(err);
    defer replacement.deinit();
    var binding = app.prepareBinding(&replacement) catch |err| return app.view.report(err);
    defer binding.deinit();
    const identity = project.snapshot.identity(app.gpa, replacement.current.snapshot, replacement.board) catch |err|
        return app.view.report(err);
    var seed: u32 = 0;
    std.Io.randomSecure(app.io, std.mem.asBytes(&seed)) catch |err| return app.view.report(err);
    const driver = LiveKeyboard.Driver.init(.{ .io = app.io }, identity, seed, null) catch |err| return app.view.report(err);
    app.flash.cancelConfirmation();
    app.live.rebind(&replacement, &binding, identity, driver, &app.life);
    app.view.diagnostic = @splat(0);
}

/// Without a tray the editor window reappears once every window is hidden.
pub fn updateResidency(app: *App) void {
    const life = &app.life;
    life.resident = app.tray.installed or app.mode.is(.companion);
    if (!life.resident and !life.editor_visible and !life.companion_visible) {
        life.editor_visible = true;
        _ = Backend.c.SDL_ShowWindow(app.native.window);
    }
    if (life.quit_requested and app.owner.close_requested == null and app.owner.pending == null and !app.owner.closed) life.cancelQuit();
}

/// An idle resident does not construct editor frames or redraw hidden
/// windows. SDL waits for native events between bounded tray polls.
pub fn waitWhileIdle(app: *App) !App.Flow {
    if (app.frame_limit != null or app.life.editor_visible or app.life.companion_visible) return .proceed;
    if (app.jobs.busy() or !app.flash.idle() or app.draft_runtime.owner != null) return .proceed;
    app.tray.update(.{ .live_mode = app.live_enabled, .status = app.live.status(), .companion_visible = false });
    var event: Backend.c.SDL_Event = undefined;
    while (Backend.c.SDL_PollEvent(&event)) _ = try app.events.raw(event);
    if (app.events.quit or app.events.close) return .proceed;
    app.interrupted = try app.native.waitEventTimeout(desktop.live_keyboard.waitBudget(app.live_enabled, false, true));
    return .next_frame;
}
