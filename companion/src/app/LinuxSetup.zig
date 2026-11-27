//! When to show the Linux setup sheets, and what their buttons do. Only
//! interactive Linux sessions show them; fixtures and other systems never do.
const std = @import("std");
const builtin = @import("builtin");
const setup = @import("linux-setup");
const setup_ui = @import("linux-setup-ui");
const tray_backend = @import("native-tray");
const App = @import("App.zig");
const cli = @import("cli.zig");

const LinuxSetup = @This();

/// Marks the tray hint as dismissed for good, in the configuration directory.
const tray_hint_marker = "linux-tray-hint-dismissed";

grant: setup.Grant = .{},
/// The access sheet stays closed after "Not now" until this run ends.
access_closed: bool = false,
tray_closed: bool = false,
tray_marker_checked: bool = false,

pub fn deinit(self: *LinuxSetup) void {
    self.grant.join();
}

/// Draws at most one sheet over the frame. Device access comes first: the
/// tray is a convenience, the live keyboard is a feature.
pub fn draw(self: *LinuxSetup, app: *App) void {
    if (app.mode.is(.linux_setup)) return drawScene(app);
    if (builtin.os.tag != .linux or app.frame_limit != null or !app.life.editor_visible) return;
    const notice = self.pending(app) orelse return;
    const action = setup_ui.draw(.{
        .notice = notice,
        .light = app.view.toolbar.light,
        .grant = self.grant.current(),
        .desktop = setup.desktopOf(if (std.c.getenv("XDG_CURRENT_DESKTOP")) |value| std.mem.span(value) else null),
    });
    switch (action) {
        .none => {},
        .grant => self.grant.start(app.io),
        .close => switch (notice) {
            .device_access => self.access_closed = true,
            .tray_host => self.tray_closed = true,
        },
        .dismiss_forever => {
            self.tray_closed = true;
            self.rememberTrayDismissal(app);
        },
    }
}

/// The scene of `--offline-linux-setup-frames` drawn in this frame.
pub fn scene(app: *const App) usize {
    return ((app.count -| 1) / cli.LinuxSetupScenes.frames_per_scene) % cli.LinuxSetupScenes.count;
}

/// Whether this frame shows its scene settled, after the fade-in.
pub fn sceneSettled(app: *const App) bool {
    return (app.count -| 1) % cli.LinuxSetupScenes.frames_per_scene == cli.LinuxSetupScenes.frames_per_scene - 1;
}

fn drawScene(app: *App) void {
    const inputs = [cli.LinuxSetupScenes.count]setup_ui.Input{
        .{ .notice = .device_access, .light = false },
        .{ .notice = .device_access, .light = false, .grant = .failed },
        .{ .notice = .tray_host, .light = false, .desktop = .gnome },
        .{ .notice = .tray_host, .light = false, .desktop = .other },
    };
    _ = setup_ui.draw(inputs[scene(app)]);
}

fn pending(self: *LinuxSetup, app: *App) ?setup_ui.Notice {
    if (!self.access_closed and (self.grant.current() != .idle or permissionDenied(app))) return .device_access;
    if (self.tray_closed or !app.tray.installed) return null;
    if (tray_backend.hostAvailable() orelse return null) return null;
    if (!self.tray_marker_checked) {
        self.tray_marker_checked = true;
        if (self.trayDismissed(app)) self.tray_closed = true;
    }
    return if (self.tray_closed) null else .tray_host;
}

/// The keyboard is enumerated but its hidraw node cannot be opened.
fn permissionDenied(app: *const App) bool {
    const driver = if (app.live.driver) |*value| value else return false;
    return driver.status == .transport_error and driver.transport_error != null and
        driver.transport_error.? == error.HidPermissionDenied;
}

fn markerPath(app: *const App, buffer: []u8) ?[]const u8 {
    const owned = app.user_paths orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ owned.paths.config, tray_hint_marker }) catch null;
}

fn trayDismissed(_: *LinuxSetup, app: *const App) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = markerPath(app, &buffer) orelse return false;
    std.Io.Dir.accessAbsolute(app.io, path, .{}) catch return false;
    return true;
}

fn rememberTrayDismissal(_: *LinuxSetup, app: *App) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = markerPath(app, &buffer) orelse return;
    if (std.fs.path.dirname(path)) |directory| std.Io.Dir.cwd().createDirPath(app.io, directory) catch return;
    const file = std.Io.Dir.createFileAbsolute(app.io, path, .{}) catch return;
    file.close(app.io);
}
