//! Linux setup sheets: device access for the live keyboard and the tray hint.
//! Drawing only; `src/platform/linux_setup.zig` performs the installation.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const setup = @import("linux-setup");

pub const Notice = enum { device_access, tray_host };

pub const Action = enum { none, close, grant, dismiss_forever };

pub const Input = struct {
    notice: Notice,
    light: bool,
    grant: setup.Grant.State = .idle,
    desktop: setup.Desktop = .other,
};

const width: f32 = 960;
const line: f32 = 24;
const left: f32 = 28;

fn text(theme: ui.Theme, value: []const u8, y: f32) void {
    ui.label(theme, value, .{ .x = left, .y = y, .w = width - 2 * left, .h = line }, 15);
}

fn muted(theme: ui.Theme, value: []const u8, y: f32) void {
    var m = theme;
    m.text = theme.muted;
    ui.label(m, value, .{ .x = left, .y = y, .w = width - 2 * left, .h = line }, 14);
}

/// Monospaced lines of `block`, each on its own row, from `y`. Returns the y
/// after the last row.
fn code(theme: ui.Theme, block: []const u8, y: f32) f32 {
    var next = y;
    var lines = std.mem.tokenizeScalar(u8, block, '\n');
    while (lines.next()) |row| : (next += 20) {
        var opts = ui.options(theme, .{ .x = left, .y = next, .w = width - 2 * left, .h = 20 }, 12);
        opts.font = dvui.Font.theme(.mono).withSize(13 * 0.76);
        opts.padding = .{};
        opts.id_extra = @intFromFloat(next);
        dvui.labelNoFmt(@src(), row, .{}, opts);
    }
    return next;
}

pub fn draw(input: Input) Action {
    const theme = ui.Theme.get(input.light);
    return switch (input.notice) {
        .device_access => deviceAccess(theme, input.grant),
        .tray_host => trayHost(theme, input.desktop),
    };
}

fn deviceAccess(theme: ui.Theme, grant: setup.Grant.State) Action {
    const height: f32 = 470;
    const frame = ui.sheet(@src(), theme, width, height, "linux.setup.access");
    defer frame.deinit();
    if (ui.sheetHeader(theme, width, "Allow access to your keyboard", "Linux opens a keyboard's companion interface only for devices a system rule names.", "linux.setup.access.close"))
        return .close;
    text(theme, "Editing and flashing work without it. Live labels, the companion overlay, the tutor's", 120);
    text(theme, "key feedback and the editor's bootloader shortcut need it. The button installs this rule", 144);
    text(theme, "as " ++ setup.rule_path ++ ":", 168);
    var y = code(theme, setup.effective_rule, 200) + 12;
    muted(theme, "It applies to Zigmkay devices and to whoever is logged in at this computer, nothing else.", y);
    y += line;
    muted(theme, "Your system asks for the administrator password; Zigmkay never sees it.", y);
    y += line + 12;
    switch (grant) {
        .idle => {},
        .running => text(theme, "Waiting for the password dialog...", y),
        .installed => text(theme, "Installed. Unplug the keyboard and plug it in again.", y),
        .cancelled => text(theme, "Cancelled. Nothing was changed.", y),
        .unavailable, .failed => {
            text(theme, if (grant == .unavailable) "pkexec is not installed. Run this in a terminal instead:" else "The installation failed. Run this in a terminal instead:", y);
            _ = code(theme, setup.manual_command, y + line + 4);
        },
    }
    const buttons_y = height - 62;
    if (ui.button(theme, if (grant == .installed) "Done" else "Not now", "linux.setup.access.later", .{ .x = width - 360, .y = buttons_y, .w = 140, .h = 38 }))
        return .close;
    const busy = grant == .running or grant == .installed;
    if (ui.iconButtonEnabled(theme, null, "Allow access", "linux.setup.access.grant", .{ .x = width - 208, .y = buttons_y, .w = 180, .h = 38 }, true, !busy))
        return .grant;
    return .none;
}

fn trayHost(theme: ui.Theme, desktop: setup.Desktop) Action {
    const height: f32 = 330;
    const frame = ui.sheet(@src(), theme, width, height, "linux.setup.tray");
    defer frame.deinit();
    switch (desktop) {
        .gnome => {
            if (ui.sheetHeader(theme, width, "Show Zigmkay in the top bar", "GNOME shows no tray icons without an extension.", "linux.setup.tray.close"))
                return .close;
            text(theme, "Install \"AppIndicator and KStatusNotifierItem Support\" from extensions.gnome.org,", 120);
            text(theme, "which needs no administrator rights, or with your package manager", 144);
            text(theme, "(gnome-shell-extension-appindicator). Enable it, then log out and back in.", 168);
        },
        .other => {
            if (ui.sheetHeader(theme, width, "Your desktop shows no tray icons", "Zigmkay's tray icon is a StatusNotifierItem.", "linux.setup.tray.close"))
                return .close;
            text(theme, "KDE Plasma, Cinnamon and Budgie show it. On Sway or Hyprland, enable the tray of", 120);
            text(theme, "your bar, for example the \"tray\" module of waybar. Other desktops need a tray", 144);
            text(theme, "or StatusNotifier panel plugin.", 168);
        },
    }
    muted(theme, "Until then, closing the editor window quits Zigmkay.", 210);
    const buttons_y = height - 62;
    if (ui.button(theme, "Don't show again", "linux.setup.tray.never", .{ .x = width - 400, .y = buttons_y, .w = 220, .h = 38 }))
        return .dismiss_forever;
    if (ui.iconButton(theme, null, "OK", "linux.setup.tray.ok", .{ .x = width - 168, .y = buttons_y, .w = 140, .h = 38 }, true))
        return .close;
    return .none;
}
