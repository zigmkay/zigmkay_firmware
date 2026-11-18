//! Retained tray backend. Explicit init/poll only; no device discovery.
const std = @import("std");
const builtin = @import("builtin");
const ztray = @import("ztray");
const icons = @import("application-icons");
const macos = @import("tray_macos.zig");
const lifecycle = @import("tray-lifecycle");
const Action = lifecycle.Action;
const MenuState = lifecycle.MenuState;

pub const Native = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn install(self: Native) !void {
        switch (builtin.os.tag) {
            .macos => try macos.install(icons.tray_template_png),
            .windows => try @import("tray_windows.zig").install(self.allocator, self.io, icons.tray_ico),
            else => try ztray.installTrayIcon(self.allocator, .{
                .tooltip = "Zigmkay is running",
                .icon_png = icons.tray_png,
            }),
        }
    }

    pub fn menu(self: Native, state: MenuState) !void {
        const items = [_]ztray.Item{
            .{ .action = .{
                .title = if (state.live_mode) "Companion: live monitoring" else "Companion: offline",
                .action_id = 10,
                .enabled = false,
            } },
            .{ .action = .{ .title = switch (state.status) {
                .offline => "Device: offline",
                .connecting => "Device: connecting",
                .live => "Device: live",
                .stale => "Device: stale",
                .disconnected => "Device: disconnected",
                .incompatible => "Device: incompatible",
            }, .action_id = 11, .enabled = false } },
            .{ .action = .{ .title = "Open Editor", .action_id = @backingInt(Action.open_editor) } },
            .{ .action = .{
                .title = if (state.companion_visible) "Hide Companion" else "Show Companion",
                .action_id = @backingInt(Action.toggle_companion),
            } },
            .{ .action = .{
                .title = "Use Saved Editor Project for Live Companion",
                .action_id = @backingInt(Action.bind_saved_project),
                .enabled = state.live_mode,
            } },
            .separator,
            .{ .action = .{ .title = "Zoom Out Editor", .action_id = @backingInt(Action.zoom_out) } },
            .{ .action = .{ .title = "Zoom In Editor", .action_id = @backingInt(Action.zoom_in) } },
            .{ .action = .{ .title = "Reset Editor Zoom", .action_id = @backingInt(Action.zoom_reset) } },
            .separator,
            .{ .action = .{ .title = "Quit Zigmkay", .action_id = @backingInt(Action.quit) } },
        };
        if (builtin.os.tag == .macos)
            try macos.setMenu(self.allocator, &items)
        else
            try ztray.setTrayMenu(self.allocator, .{ .title = "Zigmkay", .items = &items });
    }

    pub fn poll(_: Native) ?Action {
        if (builtin.os.tag == .macos) return std.enums.fromInt(Action, macos.poll() orelse return null);
        // SDL already pumps Win32. A second pump can consume SDL events.
        if (builtin.os.tag == .linux) ztray.pumpEvents();
        return ztray.pollTrayAction(Action);
    }

    pub fn shutdown(_: Native) void {
        if (builtin.os.tag == .macos) macos.shutdown() else ztray.shutdownTray();
    }
};

pub const NativeTray = lifecycle.Tray(Native);
