//! Compile/link-only dependency contract. Never run the GUI probe.
//! Exporting the probe forces analysis of the actual GUI/tray entry points;
//! merely naming their types would leave lazy Zig function bodies unchecked.
const std = @import("std");
const dvui = @import("dvui");
const backend = @import("dvui_backend");
const ztray = @import("ztray");
const placement = @import("window-placement");
const fonts = @import("editor-fonts");
const folder_dialog = @import("folder-dialog");
const editor_ui = @import("editor-ui");
const flash_ui = @import("flash-ui");
const flash_presenter = @import("flash-presenter");
const native_tray = @import("native-tray");

pub fn main() void {}

const RawEventProbe = struct {
    pub fn raw(_: *@This(), _: backend.c.SDL_Event) !bool {
        return false;
    }
};

export fn desktopEventPumpCompileProbe(native: *backend, window: *dvui.Window) void {
    var context: RawEventProbe = .{};
    @import("native-events").pump(native, window, &context) catch {};
}

export fn desktopWindowPlacementCompileProbe(window: *backend.c.SDL_Window) void {
    placement.place(window, true) catch {};
    placement.reveal(window) catch {};
    folder_dialog.start(window) catch {};
    _ = folder_dialog.poll();
    _ = folder_dialog.active();
    folder_dialog.startCorrelated(window, 1) catch {};
    _ = folder_dialog.pollCorrelated();
}

export fn desktopDependencyCompileProbe(allocator_ptr: *const std.mem.Allocator, io_ptr: *const std.Io) void {
    probe(allocator_ptr.*, io_ptr.*) catch {};
}

fn probe(gpa: std.mem.Allocator, io: std.Io) !void {
    var native = try backend.initWindow(.{
        .io = io,
        .size = .{ .w = 720, .h = 480 },
        .vsync = false,
        .title = "Zigmkay dependency compile probe",
        .hidden = true,
        .persist_window_geometry = false,
    });
    defer native.deinit();
    var window = try dvui.Window.init(@src(), gpa, native.backend(), .{});
    defer window.deinit();
    try window.begin(native.nanoTime());
    try fonts.install(gpa, io);
    _ = fonts.font("Unicode sample æλ", 16);
    const theme = editor_ui.Theme.get(false);
    editor_ui.label(theme, "Editor", .{ .x = 20, .y = 20, .w = 150, .h = 30 }, 20);
    _ = editor_ui.button(theme, "Build", "firmware.build", .{ .x = 20, .y = 60, .w = 150, .h = 30 });
    _ = editor_ui.buttonEnabled(
        theme,
        "Flash",
        "firmware.flash",
        .{ .x = 20, .y = 100, .w = 150, .h = 30 },
        false,
    );
    const panel = editor_ui.panel(theme, .physical);
    panel.deinit();
    const drawer = editor_ui.editDrawer(@src(), theme, 480);
    drawer.deinit();
    dvui.label(@src(), "Dependency compile contract", .{}, .{});
    if (@import("desktop-audit-options").vectors) {
        dvui.icon(
            @src(),
            "command",
            @import("desktop-icons").tvg.lucide.command,
            .{},
            .{ .min_size_content = .{ .w = 24, .h = 24 } },
        );
    }
    var flash = flash_presenter.controller.Controller.init(gpa, .{
        .snapshot = @splat(1),
        .build_key = @splat(2),
    });
    defer flash.deinit();
    _ = try flash_ui.draw(&flash, .{});
    _ = dvui.button(@src(), "Build", .{}, .{});
    _ = try window.end(.{});

    try ztray.installTrayIcon(gpa, .{
        .tooltip = "Zigmkay dependency compile probe",
        .icon_png = ztray.zig_favicon_png,
    });
    defer ztray.shutdownTray();
    const menu: ztray.TrayMenu = .{ .title = "Zigmkay", .items = &.{
        .{ .action = .{ .title = "Open", .action_id = 1 } },
        .separator,
        .{ .action = .{ .title = "Quit", .action_id = 2 } },
    } };
    try ztray.setTrayMenu(gpa, menu);
    ztray.pumpEvents();
    _ = ztray.pollTrayActionId();
    var retained_tray = native_tray.NativeTray.init(.{ .allocator = gpa, .io = io }, true);
    defer retained_tray.deinit();
    retained_tray.update(.{});
    _ = retained_tray.poll();
}
