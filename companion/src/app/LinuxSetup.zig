//! When to show the Linux setup sheets, and what their buttons do. Only
//! interactive Linux sessions show them; fixtures and other systems never do.
const std = @import("std");
const builtin = @import("builtin");
const Backend = @import("dvui_backend");
const setup = @import("linux-setup");
const setup_ui = @import("linux-setup-ui");
const tray_backend = @import("native-tray");
const App = @import("App.zig");
const cli = @import("cli.zig");

const LinuxSetup = @This();

/// Marks the keyboard access prompt as dismissed for good, in the configuration directory.
const access_dismissed_marker = "linux-access-prompt-dismissed";
/// Marks the tray hint as dismissed for good, in the configuration directory.
const tray_hint_marker = "linux-tray-hint-dismissed";

grant: setup.Grant = .{},
/// The access sheet stays closed after "Not now" until this run ends, or permanently after "Don't ask again".
access_closed: bool = false,
access_marker_checked: bool = false,
tray_closed: bool = false,
tray_probe: setup.TrayProbe = .{},
tray_marker_checked: bool = false,

pub fn deinit(self: *LinuxSetup) void {
    self.grant.join();
    self.tray_probe.join();
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
        .learn_more => if (app.frame_limit == null) {
            _ = Backend.c.SDL_OpenURL(setup.learn_more_url.ptr);
        },
        .close => switch (notice) {
            .device_access => self.access_closed = true,
            .tray_host => self.tray_closed = true,
        },
        .dismiss_forever => switch (notice) {
            .device_access => {
                self.access_closed = true;
                self.rememberDismissal(app, access_dismissed_marker);
            },
            .tray_host => {
                self.tray_closed = true;
                self.rememberDismissal(app, tray_hint_marker);
            },
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
    if (!self.access_closed) {
        if (self.grant.current() != .idle) return .device_access;
        if (permissionDenied(app)) {
            if (!self.access_marker_checked) {
                self.access_marker_checked = true;
                if (self.markerExists(app, access_dismissed_marker)) self.access_closed = true;
            }
            if (!self.access_closed) return .device_access;
        }
    }
    if (self.tray_closed) return null;
    // A ztray with trayHostAvailable answers directly; older pins, whose
    // release builds have no tray at all, are answered by the bus probe.
    const host = tray_backend.hostAvailable() orelse probed: {
        self.tray_probe.start(app.io);
        break :probed self.tray_probe.result() orelse return null;
    };
    if (host) return null;
    if (!self.tray_marker_checked) {
        self.tray_marker_checked = true;
        if (self.markerExists(app, tray_hint_marker)) self.tray_closed = true;
    }
    return if (self.tray_closed) null else .tray_host;
}

/// The keyboard is enumerated but its hidraw node cannot be opened.
fn permissionDenied(app: *const App) bool {
    const driver = if (app.live.driver) |*value| value else return false;
    return driver.status == .transport_error and driver.transport_error != null and
        driver.transport_error.? == error.HidPermissionDenied;
}

fn markerPath(app: *const App, name: []const u8, buffer: []u8) ?[]const u8 {
    const owned = app.user_paths orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ owned.paths.config, name }) catch null;
}

fn markerExists(_: *LinuxSetup, app: *const App, name: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = markerPath(app, name, &buffer) orelse return false;
    std.Io.Dir.accessAbsolute(app.io, path, .{}) catch return false;
    return true;
}

fn rememberDismissal(_: *LinuxSetup, app: *App, name: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = markerPath(app, name, &buffer) orelse return;
    if (std.fs.path.dirname(path)) |directory| std.Io.Dir.cwd().createDirPath(app.io, directory) catch return;
    const file = std.Io.Dir.createFileAbsolute(app.io, path, .{}) catch return;
    file.close(app.io);
}
