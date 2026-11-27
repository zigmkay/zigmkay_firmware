//! Linux setup sheets: device access for the live keyboard and the tray hint.
//! Drawing only; `src/platform/linux_setup.zig` performs the installation.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const setup = @import("linux-setup");

pub const Notice = enum { device_access, tray_host };

pub const Action = enum { none, close, grant, dismiss_forever, learn_more };

pub const Input = struct {
    notice: Notice,
    light: bool,
    grant: setup.Grant.State = .idle,
    desktop: setup.Desktop = .other,
};

const width: f32 = 960;
const access_width: f32 = 800;
const line: f32 = 24;
const left: f32 = 28;

fn text(theme: ui.Theme, value: []const u8, y: f32) void {
    ui.label(theme, value, .{ .x = left, .y = y, .w = width - 2 * left, .h = line }, 15);
}

fn muted(theme: ui.Theme, value: []const u8, y: f32) void {
    mutedIn(theme, value, y, width - 2 * left, 14);
}

fn mutedIn(theme: ui.Theme, value: []const u8, y: f32, w: f32, size: f32) void {
    var m = theme;
    m.text = theme.muted;
    ui.label(m, value, .{ .x = left, .y = y, .w = w, .h = line }, size);
}

/// Accent link with a trailing external-link icon.
fn learnMoreLink(theme: ui.Theme, y: f32) bool {
    const label_text = "Learn more";
    const tag = "linux.setup.access.learn_more";
    const id = std.hash.Wyhash.hash(0, tag);
    const rect: dvui.Rect = .{ .x = left, .y = y, .w = 132, .h = 26 };
    var opts = ui.options(theme, rect, 15);
    opts.tag = tag;
    opts.id_extra = id;
    opts.background = false;
    opts.border = .{};
    opts.padding = .{};
    opts.color_text = .{ .color = theme.accent };
    const clicked = dvui.button(@src(), "", .{}, opts);

    var accent_theme = theme;
    accent_theme.text = theme.accent;
    ui.label(accent_theme, label_text, .{ .x = rect.x, .y = rect.y + 3, .w = 96, .h = 20 }, 15);
    dvui.icon(@src(), tag, ui.control_icons.external, .{}, .{
        .id_extra = id +% 1,
        .color_text = .{ .color = theme.accent },
        .rect = .{ .x = rect.x + 92, .y = rect.y + 5, .w = 15, .h = 15 },
        .padding = .{},
        .margin = .{},
    });
    return clicked;
}

/// Subtle ghost button used for secondary dismissal actions in the footer.
fn ghostButton(theme: ui.Theme, label_text: []const u8, tag: []const u8, rect: dvui.Rect) bool {
    const id = std.hash.Wyhash.hash(0, tag);
    var opts = ui.options(theme, rect, 15);
    opts.tag = tag;
    opts.id_extra = id;
    opts.background = false;
    opts.border = .{};
    opts.corners = .all(8);
    opts.padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 };
    opts.color_text = .{ .color = theme.muted };
    return dvui.button(@src(), label_text, .{}, opts);
}

fn statusBanner(theme: ui.Theme, grant: setup.Grant.State, y: f32) void {
    const message: []const u8 = switch (grant) {
        .idle => return,
        .running => "Waiting for your system password dialog...",
        .installed => "Access granted. Unplug your keyboard and plug it back in to finish.",
        .cancelled => "Cancelled. Nothing was changed.",
        .unavailable, .failed => "Automatic setup didn't succeed. Open \"Learn more\" for manual setup steps.",
    };
    const border_color = switch (grant) {
        .installed => theme.success,
        .unavailable, .failed => theme.danger,
        else => theme.border,
    };
    const box_rect: dvui.Rect = .{ .x = left, .y = y, .w = access_width - 2 * left, .h = 42 };
    const box = dvui.box(@src(), .{}, .{
        .id_extra = 0x57a7,
        .rect = box_rect,
        .background = true,
        .border = .all(1),
        .corners = .all(8),
        .color_fill = .{ .color = theme.control },
        .color_border = .{ .color = border_color },
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
    ui.label(theme, message, .{ .x = box_rect.x + 14, .y = box_rect.y + 10, .w = box_rect.w - 28, .h = 22 }, 14);
}

pub fn draw(input: Input) Action {
    const theme = ui.Theme.get(input.light);
    return switch (input.notice) {
        .device_access => deviceAccess(theme, input.grant),
        .tray_host => trayHost(theme, input.desktop),
    };
}

fn deviceAccess(theme: ui.Theme, grant: setup.Grant.State) Action {
    const height: f32 = 308;
    const frame = ui.sheet(@src(), theme, access_width, height, "linux.setup.access");
    defer frame.deinit();

    ui.label(theme, "Allow access to your keyboard", .{ .x = left, .y = 26, .w = access_width - 100, .h = 30 }, 22);
    if (ui.iconButton(theme, ui.control_icons.remove, "", "linux.setup.access.close", .{ .x = access_width - 58, .y = 22, .w = 30, .h = 30 }, false))
        return .close;

    const body_w = access_width - 2 * left;
    mutedIn(theme, "To get the most out of your keyboard on Linux—like live labels, the overlay,", 74, body_w, 15);
    mutedIn(theme, "and typing tutor feedback—you need to grant additional permissions.", 98, body_w, 15);

    if (learnMoreLink(theme, 132))
        return .learn_more;

    if (grant != .idle) statusBanner(theme, grant, 172);

    const footer_divider_y = height - 76;
    ui.divider(theme, .{ .x = 0, .y = footer_divider_y, .w = access_width, .h = 1 }, 0x5eee);

    const buttons_y = height - 56;
    if (grant == .installed) {
        if (ui.iconButton(theme, null, "Done", "linux.setup.access.later", .{ .x = access_width - 168, .y = buttons_y, .w = 140, .h = 38 }, true))
            return .close;
        return .none;
    }
    const busy = grant == .running;
    if (!busy) {
        if (ghostButton(theme, "Don't ask again", "linux.setup.access.never", .{ .x = left - 8, .y = buttons_y, .w = 152, .h = 38 }))
            return .dismiss_forever;
    }
    if (ui.button(theme, "Not now", "linux.setup.access.later", .{ .x = access_width - 356, .y = buttons_y, .w = 140, .h = 38 }))
        return .close;
    if (ui.iconButtonEnabled(theme, null, "Allow access", "linux.setup.access.grant", .{ .x = access_width - 204, .y = buttons_y, .w = 176, .h = 38 }, true, !busy))
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
